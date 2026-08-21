
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

CONFIG_PATH = os.environ.get("HERMES_BOOTSTRAP_CONFIG", "/etc/hermes-bootstrap/config.yaml")
PLUGINS_ROOT = Path(os.environ.get("HERMES_PLUGINS_ROOT", "/opt/data/plugins"))
CLONE_CACHE = Path(os.environ.get("HERMES_CLONE_CACHE", "/opt/data/.bootstrap-cache"))


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


def main() -> int:
    cfg = yaml.safe_load(Path(CONFIG_PATH).read_text()) or {}

    PLUGINS_ROOT.mkdir(parents=True, exist_ok=True)
    for plugin in cfg.get("plugins") or []:
        install_plugin(
            name=plugin["name"],
            repo=plugin["repo"],
            ref=plugin.get("ref", "main"),
            sub_path=plugin.get("path", "plugin"),
        )

    print("\n✓ hermes-bootstrap complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
