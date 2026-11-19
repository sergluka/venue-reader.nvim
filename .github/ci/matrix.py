"""Resolve the CI matrix and the current stable Neovim release once per run."""

import json
import os
import re
import subprocess
from pathlib import Path

tools = json.loads(Path("tests/dependencies.json").read_text())["tools"]
server = json.loads(Path("lua/venue-reader/release.json").read_text())
latest = json.loads(subprocess.check_output(
    ["gh", "api", "repos/neovim/neovim/releases/latest"], text=True
))
stable = latest["tag_name"].removeprefix("v")
if not re.fullmatch(r"\d+\.\d+\.\d+", stable):
    raise ValueError(f"Unexpected stable Neovim version: {stable}")
asset = next(asset for asset in latest["assets"] if asset["name"] == "nvim-linux-x86_64.tar.gz")
digest = asset["digest"].removeprefix("sha256:")
if not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise ValueError("Missing stable Neovim release digest")

cells = []


def cell(runner, target, version, mode):
    cells.append({
        "runner": runner, "target": target, "version": version, "mode": mode,
        "id": f"{target}-{version}-{mode}",
    })


for version in dict.fromkeys([tools["minimum_nvim"], tools["nvim"], stable]):
    for mode in ("release", "source"):
        cell("ubuntu-24.04", "x86_64-unknown-linux-gnu", version, mode)
for runner, target in [
    ("macos-15-intel", "x86_64-apple-darwin"),
    ("macos-15", "aarch64-apple-darwin"),
    ("windows-2025", "x86_64-pc-windows-msvc"),
]:
    cell(runner, target, tools["nvim"], "release")

with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as outputs:
    for key, value in {
        "matrix": json.dumps({"include": cells}),
        "python": tools["python"],
        "stable-digest": digest,
        "server-commit": server["commit"],
        "server-version": server["version"],
    }.items():
        print(f"{key}={value}", file=outputs)
print(json.dumps(cells, indent=2))
