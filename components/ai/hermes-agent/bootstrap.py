
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

import yaml

CONFIG_PATH = os.environ.get("HERMES_BOOTSTRAP_CONFIG", "/etc/hermes-bootstrap/config.yaml")
PLUGINS_ROOT = Path(os.environ.get("HERMES_PLUGINS_ROOT", "/opt/data/plugins"))
CLONE_CACHE = Path(os.environ.get("HERMES_CLONE_CACHE", "/opt/data/.bootstrap-cache"))


def _http(method: str, url: str, token: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = Request(
        url,
        data=data,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urlopen(req, timeout=15) as r:
            payload = r.read()
            return r.status, (json.loads(payload) if payload else {})
    except HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def wait_for_mac_api(url: str) -> None:
    for attempt in range(60):
        try:
            with urlopen(url.rstrip("/") + "/health", timeout=3) as r:
                if r.status == 200:
                    print(f"[ok] mac-api reachable at {url}")
                    return
        except (HTTPError, URLError, TimeoutError):
            pass
        print(f"[wait] mac-api /health not ready ({attempt+1}/60)...")
        time.sleep(2)
    print("FAIL: mac-api /health never became ready", file=sys.stderr)
    sys.exit(1)


def run_hermes_seed_config() -> None:
    print("[ok] running hermes-seed-config")
    subprocess.check_call(["hermes-seed-config"])


def _authed_clone_url(url: str) -> str:
    """Inject GITEA_TOKEN into gitea HTTPS URLs."""
    token = os.environ.get("GITEA_TOKEN", "")
    user = os.environ.get("GITEA_USER", "")
    if token and user and "gitea." in url and url.startswith("https://"):
        return url.replace("https://", f"https://{user}:{token}@")
    return url


def install_plugin(name: str, repo: str, ref: str, sub_path: str) -> None:
    target = PLUGINS_ROOT / name
    cache = CLONE_CACHE / name
    if cache.exists():
        shutil.rmtree(cache)
    cache.parent.mkdir(parents=True, exist_ok=True)
    print(f"[plugin {name}] git clone --depth=1 --branch={ref} {repo}")
    subprocess.check_call([
        "git", "clone", "--depth=1", "--branch", ref,
        _authed_clone_url(repo), str(cache),
    ])
    src = cache / sub_path
    if not src.is_dir():
        print(f"FAIL plugin {name}: {src} not a directory", file=sys.stderr)
        sys.exit(3)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(src, target)
    manifest = target / "plugin.yaml"
    init_py = target / "__init__.py"
    if not manifest.is_file() or not init_py.is_file():
        print(f"FAIL plugin {name}: missing plugin.yaml or __init__.py", file=sys.stderr)
        sys.exit(4)
    shutil.rmtree(cache, ignore_errors=True)
    print(f"[ok] plugin {name} installed -> {target}")


def register_mac_identities(identities: list, mac_url: str, mac_token: str) -> None:
    base = mac_url.rstrip("/")
    for ident in identities:
        print(f"--- identity {ident['instance_id']} ---")
        status, t = _http("POST", base + "/tenants", mac_token,
                          {"name": ident["tenant_name"], "tenant_id": ident["tenant_id"]})
        if status >= 400:
            print(f"FAIL tenant: HTTP {status} {t}", file=sys.stderr); sys.exit(5)
        print(f"[ok] tenant id={t.get('id')}")
        status, p = _http("POST", base + "/personas", mac_token, {
            "tenant_id": ident["tenant_id"], "name": ident["persona_name"],
            "persona_id": ident["persona_id"],
            "soul_ref": ident["soul_ref"], "memory_scope": ident["memory_scope"],
        })
        if status >= 400:
            print(f"FAIL persona: HTTP {status} {p}", file=sys.stderr); sys.exit(6)
        print(f"[ok] persona id={p.get('id')}")
        status, h = _http("POST", base + "/hermes-instances", mac_token, {
            "tenant_id": ident["tenant_id"], "name": ident["instance_name"],
            "instance_id": ident["instance_id"], "persona_id": ident["persona_id"],
            "home_ref": ident.get("home_ref", ""),
        })
        if status >= 400:
            print(f"FAIL instance: HTTP {status} {h}", file=sys.stderr); sys.exit(7)
        print(f"[ok] instance id={h.get('id')}")


def main() -> int:
    cfg = yaml.safe_load(Path(CONFIG_PATH).read_text()) or {}
    mac_url = os.environ.get("MAC_URL") or cfg.get("mac_url", "")
    mac_token = os.environ.get("MAC_WORKER_TOKEN", "")
    if not mac_url or not mac_token:
        print("FAIL: MAC_URL and MAC_WORKER_TOKEN are required", file=sys.stderr)
        return 2

    wait_for_mac_api(mac_url)
    run_hermes_seed_config()

    PLUGINS_ROOT.mkdir(parents=True, exist_ok=True)
    for plugin in cfg.get("plugins") or []:
        install_plugin(
            name=plugin["name"],
            repo=plugin["repo"],
            ref=plugin.get("ref", "main"),
            sub_path=plugin.get("path", "plugin"),
        )

    register_mac_identities(cfg.get("mac_identities") or [], mac_url, mac_token)
    print("\n✓ hermes-bootstrap complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
