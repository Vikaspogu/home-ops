import errno
import json
import socket
import sqlite3
import sys
from pathlib import Path

stage = "startup"

def main():
    global stage
    stage = "network"
    targets = (("valkey", "10.96.64.206", 6379), ("postgresql", "10.96.20.181", 5432), ("external", "1.1.1.1", 443))
    for label, host, port in targets:
        try:
            with socket.create_connection((host, port), timeout=2):
                print(json.dumps({"network_denial_failed": label}))
                return 2
        except TimeoutError:
            pass
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EPERM):
                raise
    stage = "sqlite_open"
    connection = sqlite3.connect("file:/source/qui.db?mode=ro", uri=True, timeout=3, autocommit=True)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        counts = {}
        for label, query in (
            ("api_keys", "SELECT COUNT(*) FROM api_keys"),
            ("client_api_keys", "SELECT COUNT(*) FROM client_api_keys"),
            ("instances", "SELECT COUNT(*) FROM instances"),
        ):
            stage = "schema_" + label
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (label,)).fetchone() is None:
                print(json.dumps({"schema_missing": label}))
                return 3
            stage = "count_" + label
            counts[label] = connection.execute(query).fetchone()[0]
        connection.execute("ROLLBACK")
        print(json.dumps({"inventory": counts, "schema_checked": 3, "network_denial_checks": 3}))
        return 0
    finally:
        connection.close()

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({
            "inventory_failed": type(error).__name__,
            "stage": stage,
            "sqlite_errorname": getattr(error, "sqlite_errorname", None),
            "errno": getattr(error, "errno", None),
            "source_files_present": {name: Path("/source", name).exists() for name in ("qui.db", "qui.db-wal", "qui.db-shm")},
        }))
        sys.exit(1)
