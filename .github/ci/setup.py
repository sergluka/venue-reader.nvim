"""Install the selected Neovim and Tree-sitter releases into the runner temp directory."""

import gzip
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

manifest = json.loads(Path("tests/dependencies.json").read_text())
tools = manifest["tools"]
digests = manifest["tool_assets"]
target = (platform.system(), platform.machine().lower())
nvim_asset, parser_asset = {
    ("Linux", "x86_64"): ("nvim-linux-x86_64.tar.gz", "tree-sitter-linux-x64.gz"),
    ("Darwin", "x86_64"): ("nvim-macos-x86_64.tar.gz", "tree-sitter-macos-x64.gz"),
    ("Darwin", "arm64"): ("nvim-macos-arm64.tar.gz", "tree-sitter-macos-arm64.gz"),
    ("Windows", "amd64"): ("nvim-win64.zip", "tree-sitter-windows-x64.gz"),
}[target]
directory = Path(tempfile.mkdtemp(dir=os.environ["RUNNER_TEMP"]))
version = os.environ.get("NVIM_VERSION") or tools["nvim"]
suffix = ".exe" if os.name == "nt" else ""


def download(repository, version, asset, expected):
    archive = directory / asset
    url = f"https://github.com/{repository}/releases/download/v{version}/{asset}"
    subprocess.run(["curl", "-fLsS", "--retry", "3", "-o", archive, url], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise ValueError(f"SHA-256 mismatch for {asset}")
    return archive


# Latest stable uses the GitHub release digest frozen by the matrix job.
expected = digests["nvim"].get(version, {}).get(nvim_asset) or os.environ["NVIM_SHA256"]
archive = download("neovim/neovim", version, nvim_asset, expected)
if nvim_asset.endswith(".zip"):
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(directory)
else:
    subprocess.run(["tar", "-xzf", archive, "-C", directory], check=True)
nvim = next(directory.glob("*/bin/nvim" + suffix))
parser_archive = download(
    "tree-sitter/tree-sitter", tools["tree_sitter"], parser_asset,
    digests["tree_sitter"][parser_asset],
)
parser = directory / ("tree-sitter" + suffix)
with gzip.open(parser_archive, "rb") as source, parser.open("wb") as output:
    shutil.copyfileobj(source, output)
parser.chmod(0o755)

for binary, required in [(nvim, "NVIM v" + version), (parser, "tree-sitter " + tools["tree_sitter"])]:
    reported = subprocess.check_output([binary, "--version"], text=True).splitlines()[0]
    print(reported)
    if reported.split()[:2] != required.split():
        raise ValueError(f"Unexpected version for {binary}: {reported}")
with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as paths:
    print(nvim.parent, directory, sep="\n", file=paths)
