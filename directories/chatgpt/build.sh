#!/bin/sh
# FIT-237: the ZIP ChatGPT's plugin portal takes (platform.openai.com/plugins): plugin.json and mcp.json from here, the
# logo, and the Claude plugin's coach skills (plugin/skills), which use the same SKILL.md format.
#   directories/chatgpt/build.sh   → directories/chatgpt/dist/barbrabell-chatgpt.zip
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
if grep -q '"demo_recording_url": ""' "$here/plugin.json"; then
  echo "Set review.demo_recording_url in plugin.json first: ChatGPT's review requires a demo video link." >&2
  exit 1
fi
out="$here/dist"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$here/plugin.json" "$here/mcp.json" "$stage/"
cp -R "$here/assets" "$stage/assets"
cp -R "$root/plugin/skills" "$stage/skills"
mkdir -p "$out"
rm -f "$out/barbrabell-chatgpt.zip"
(cd "$stage" && zip -qr -X "$out/barbrabell-chatgpt.zip" plugin.json mcp.json assets skills)
echo "$out/barbrabell-chatgpt.zip"
