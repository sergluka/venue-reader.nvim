#!/usr/bin/env bash
set -euo pipefail

manifest=tests/dependencies.json
bin="$RUNNER_TEMP/vr-lint-bin"
downloads=$(mktemp -d)
mkdir -p "$bin"

download() {
  local name=$1 url=$2
  curl --fail --location --silent --show-error --retry 2 --max-time 120 "$url" -o "$downloads/$name"
  local digest
  digest=$(jq -er --arg name "$name" '.lint_sha256[$name]' "$manifest")
  printf '%s  %s\n' "$digest" "$downloads/$name" | sha256sum --check
}

version=$(jq -er .tools.stylua "$manifest")
download stylua "https://github.com/JohnnyMorganz/StyLua/releases/download/v$version/stylua-linux-x86_64.zip"
unzip -p "$downloads/stylua" stylua > "$bin/stylua"

version=$(jq -er .tools.luacheck "$manifest")
download luacheck "https://github.com/lunarmodules/luacheck/releases/download/v$version/luacheck"
cp "$downloads/luacheck" "$bin/luacheck"

version=$(jq -er .tools.ruff "$manifest")
download ruff "https://github.com/astral-sh/ruff/releases/download/$version/ruff-x86_64-unknown-linux-gnu.tar.gz"
tar -xOf "$downloads/ruff" ruff-x86_64-unknown-linux-gnu/ruff > "$bin/ruff"

version=$(jq -er .tools.actionlint "$manifest")
download actionlint "https://github.com/rhysd/actionlint/releases/download/v$version/actionlint_${version}_linux_amd64.tar.gz"
tar -xOf "$downloads/actionlint" actionlint > "$bin/actionlint"

version=$(jq -er .tools.shellcheck "$manifest")
download shellcheck "https://github.com/koalaman/shellcheck/releases/download/v$version/shellcheck-v$version.linux.x86_64.tar.xz"
tar -xOf "$downloads/shellcheck" "shellcheck-v$version/shellcheck" > "$bin/shellcheck"

chmod +x "$bin/"*
echo "$bin" >> "$GITHUB_PATH"
