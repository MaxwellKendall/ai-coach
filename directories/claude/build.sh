#!/bin/sh
# FIT-207: the Claude plugin (plugin/) as a ZIP for Claude's Customize › Plugins › Add › Upload plugin, which takes an
# archive holding one .claude-plugin/plugin.json. The marketplace file stays out: it's for adding the GitHub repo.
#   directories/claude/build.sh   → directories/claude/dist/barbrabell-claude.zip
set -eu
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../../plugin" && pwd)
out="$here/dist"
mkdir -p "$out"
rm -f "$out/barbrabell-claude.zip"
(cd "$plugin" && zip -qr -X "$out/barbrabell-claude.zip" .claude-plugin/plugin.json .mcp.json README.md LICENSE skills)
echo "$out/barbrabell-claude.zip"
