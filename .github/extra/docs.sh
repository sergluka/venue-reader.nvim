#!/usr/bin/env bash
set -euo pipefail

directory=$(mktemp -d)
ln -s "$PWD" "$directory/venue-reader.nvim"
mode=${1:?expected pinned or live}
for repository in venue-reader venue-reader.wiki venue-reader.nvim.wiki; do
  case "$mode" in
    pinned) revision=$(jq -er --arg repo "$repository" '.docs[$repo]' tests/dependencies.json) ;;
    live) revision=HEAD ;;
    *) exit 2 ;;
  esac
  checkout="$directory/$repository"
  git init --quiet "$checkout"
  git -C "$checkout" fetch --depth=1 "https://github.com/sergluka/$repository.git" "$revision"
  git -C "$checkout" checkout --quiet --detach FETCH_HEAD
  printf '%s %s\n' "$repository" "$(git -C "$checkout" rev-parse HEAD)"
done
printf 'venue-reader.nvim %s\n' "$(git rev-parse HEAD)"
nvim --headless -u NONE -i NONE -l "$directory/venue-reader.nvim.wiki/tools/check_docs.lua"
