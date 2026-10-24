#!/bin/sh
# FIT-237: the ZIP ChatGPT's plugin portal takes (platform.openai.com/plugins): plugin.json and mcp.json from here, the
# logo, and the Claude plugin's coach skills (plugin/skills), which use the same SKILL.md format.
#   directories/chatgpt/build.sh   → directories/chatgpt/dist/barbrabell-chatgpt.zip
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$here/dist"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$here/plugin.json" "$here/mcp.json" "$stage/"
# Review needs a demo video link. Without one in plugin.json the field is left out, to be given in the portal's
# Review details instead, since an empty one would be rejected.
if grep -q '"demo_recording_url": ""' "$here/plugin.json"; then
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); del p["extensions"]["com.openai"]["review"]["demo_recording_url"]; json.dump(p, open(sys.argv[1], "w"), indent=2)' "$stage/plugin.json"
  echo "No demo video link in plugin.json: add it in the portal's Review details before submitting." >&2
fi
cp -R "$here/assets" "$stage/assets"
cp -R "$root/plugin/skills" "$stage/skills"
mkdir -p "$out"
rm -f "$out/barbrabell-chatgpt.zip"
(cd "$stage" && zip -qr -X "$out/barbrabell-chatgpt.zip" plugin.json mcp.json assets skills)
echo "$out/barbrabell-chatgpt.zip"
