import errno
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import runpy
import socket
import subprocess
import sys
import time
from unittest.mock import patch

TABLES = ("api_keys", "client_api_keys", "instances")
DATABASE = Path("/source/qui.db")
SIGNALS = Path("/signals")
DEADLINE = time.monotonic() + 90
BATCHES = 20
INVENTORY_SCRIPT = Path("/script/inventory.py")


def wait_marker(name):
    while not (SIGNALS / name).exists():
        if (SIGNALS / "reader-done").exists():
            raise RuntimeError("reader stopped")
        if time.monotonic() > DEADLINE:
            raise TimeoutError("marker deadline")
        time.sleep(0.01)


def snapshot_counts(connection):
    connection.execute("BEGIN")
    try:
        return [connection.execute("SELECT COUNT(*) FROM " + name).fetchone()[0] for name in TABLES]
    finally:
        connection.execute("ROLLBACK")


def fixture_identity():
    result = {}
    for suffix in ("", "-wal", "-shm"):
        path = Path(str(DATABASE) + suffix)
        stat = path.stat()
        result[suffix] = (stat.st_size, stat.st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def inventory_case(network, database):
    output = io.StringIO()
    with patch("socket.create_connection", side_effect=network), patch("sqlite3.connect", side_effect=database):
        with contextlib.redirect_stdout(output):
            try:
                runpy.run_path(str(INVENTORY_SCRIPT), run_name="__main__")
            except SystemExit as error:
                code = error.code
            else:
                raise AssertionError("inventory did not exit")
    assert "SYNTHETIC_PRIVATE_SENTINEL" not in output.getvalue()
    return code, json.loads(output.getvalue())


def verify_failure_branches():
    original_network = socket.create_connection
    original_database = sqlite3.connect

    def denied(*args, **kwargs):
        raise TimeoutError

    def unopened(*args, **kwargs):
        raise AssertionError("SQLite reached before network failure")

    def network_error(number):
        def fail(*args, **kwargs):
            raise OSError(number, "SYNTHETIC_PRIVATE_SENTINEL")
        return fail

    def database_at(path):
        def connect(*args, **kwargs):
            assert args == ("file:/source/qui.db?mode=ro",)
            return original_database("file:" + str(path) + "?mode=ro", **kwargs)
        return connect

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def reachable(*args, **kwargs):
            return original_network(listener.getsockname(), timeout=2)

        assert inventory_case(reachable, unopened) == (2, {"network_denial_failed": "valkey"})

    assert inventory_case(denied, database_at(DATABASE.with_name("schema-missing.db"))) == (
        3, {"schema_missing": "client_api_keys"}
    )
    missing = DATABASE.with_name("missing.db")
    code, output = inventory_case(denied, database_at(missing))
    assert code == 1 and output["inventory_failed"] == "OperationalError"
    assert output["stage"] == "sqlite_open" and output["sqlite_errorname"].startswith("SQLITE_CANTOPEN")
    assert not missing.exists()
    for number in (errno.ECONNREFUSED, errno.EHOSTUNREACH):
        code, output = inventory_case(network_error(number), unopened)
        assert code == 1 and output["stage"] == "network" and output["errno"] == number
        assert output["sqlite_errorname"] is None
    for number in (errno.EACCES, errno.EPERM):
        code, output = inventory_case(network_error(number), database_at(DATABASE))
        assert code == 0 and output["inventory"] == {name: 1 for name in TABLES}


def writer():
    schema_fixture = sqlite3.connect(DATABASE.with_name("schema-missing.db"), autocommit=True)
    try:
        schema_fixture.execute("CREATE TABLE api_keys (private_data TEXT)")
    finally:
        schema_fixture.close()
    connection = sqlite3.connect(DATABASE, autocommit=True)
    try:
        assert connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        connection.execute("PRAGMA wal_autocheckpoint=0")
        for name in TABLES:
            connection.execute("CREATE TABLE " + name + " (private_data TEXT)")

        def commit_batch():
            connection.execute("BEGIN")
            for name in TABLES:
                connection.execute("INSERT INTO " + name + " VALUES (?)", ("SYNTHETIC_PRIVATE_SENTINEL",))
            connection.execute("COMMIT")

        commit_batch()
        (SIGNALS / "ready").touch()
        wait_marker("run-batches")
        for _ in range(BATCHES):
            if time.monotonic() > DEADLINE:
                raise TimeoutError("writer deadline")
            commit_batch()
            time.sleep(0.02)
        (SIGNALS / "batches-done").touch()
        wait_marker("reader-done")
        if not (SIGNALS / "reader-success").exists():
            raise RuntimeError("reader validation failed")
    finally:
        connection.close()


def reader():
    connection = None
    try:
        wait_marker("ready")
        assert os.statvfs(DATABASE.parent).f_flag & os.ST_RDONLY
        assert Path(str(DATABASE) + "-wal").stat().st_size > 0
        assert Path(str(DATABASE) + "-shm").exists()
        try:
            with (DATABASE.parent / "forbidden-write").open("x"):
                pass
        except OSError as error:
            assert error.errno == errno.EROFS
        else:
            raise AssertionError("fixture mount is writable")

        before = fixture_identity()
        result = subprocess.run(
            ["python3", "-B", "/script/inventory.py"], capture_output=True, text=True, timeout=20
        )
        assert result.returncode == 0
        assert "SYNTHETIC_PRIVATE_SENTINEL" not in result.stdout + result.stderr
        evidence = json.loads(result.stdout)
        assert evidence == {
            "inventory": {name: 1 for name in TABLES},
            "schema_checked": 3,
            "network_denial_checks": 3,
        }
        assert fixture_identity() == before

        verify_failure_branches()

        connection = sqlite3.connect("file:/source/qui.db?mode=ro", uri=True, timeout=3, autocommit=True)
        connection.execute("PRAGMA query_only=ON")
        try:
            connection.execute("INSERT INTO api_keys VALUES ('forbidden')")
        except sqlite3.OperationalError as error:
            assert error.sqlite_errorname.startswith("SQLITE_READONLY")
        else:
            raise AssertionError("SQL write accepted")
        assert fixture_identity() == before

        missing = DATABASE.parent / "missing.db"
        try:
            sqlite3.connect("file:" + str(missing) + "?mode=ro", uri=True, autocommit=True)
        except sqlite3.OperationalError:
            assert not missing.exists()
        else:
            raise AssertionError("missing database accepted")

        (SIGNALS / "run-batches").touch()
        snapshots = 0
        while True:
            counts = snapshot_counts(connection)
            assert len(set(counts)) == 1 and 1 <= counts[0] <= BATCHES + 1
            snapshots += 1
            if (SIGNALS / "batches-done").exists():
                break
            if time.monotonic() > DEADLINE:
                raise TimeoutError("reader deadline")
            time.sleep(0.01)
        assert snapshot_counts(connection) == [BATCHES + 1] * len(TABLES)
        print(json.dumps({
            "synthetic_validation": "passed",
            "python": sys.version.split()[0],
            "sqlite": sqlite3.sqlite_version,
            "kernel_read_only": True,
            "wal_row_visible": True,
            "fixture_unchanged_during_idle_reader": True,
            "concurrent_snapshots": snapshots,
            "final_rows_per_table": BATCHES + 1,
            "failure_exit_codes_verified": [1, 2, 3],
            "network_error_contract_verified": True,
        }))
        (SIGNALS / "reader-success").touch()
    finally:
        if connection is not None:
            connection.close()
        (SIGNALS / "reader-done").touch()


if __name__ == "__main__":
    role = sys.argv[1] if len(sys.argv) == 2 and sys.argv[1] in ("writer", "reader") else "invalid"
    try:
        if role == "writer":
            writer()
        elif role == "reader":
            reader()
        else:
            raise ValueError("unknown role")
    except Exception as error:
        print(json.dumps({"synthetic_validation": "failed", "role": role, "error": type(error).__name__}))
        sys.exit(1)
