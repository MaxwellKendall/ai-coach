#!/bin/sh
# TKL-793: ship the start and end photos of every exercise with a demo clip in the app (Resources/DemoPhotos), so the
# how-to shows them offline before the clip or any photo was ever loaded. Reads the lists in Resources/Seed and the
# photos from the site; writes photo-<slug>-<n>.jpg at most 480 px wide. Rerun after the demo list changes.
set -eu
cd "$(dirname "$0")/.."
site="${SITE:-https://barbrabell.com}"
out=Resources/DemoPhotos
rm -rf "$out"; mkdir -p "$out"
python3 -I -c '
import json
demos = json.load(open("Resources/Seed/exercise-demos.json"))
photos = json.load(open("Resources/Seed/exercise-photos.json"))
for slug in demos:
    for n, path in enumerate(photos.get(slug, [])):
        print(slug, n, path)
' | while read -r slug n path; do
  file="$out/photo-$slug-$n.jpg"
  curl -fsS "$site/exercises/$path" -o "$file"
  sips -Z 480 -s format jpeg -s formatOptions 70 "$file" --out "$file" >/dev/null
done
ls "$out" | wc -l | xargs echo "photos:"
du -sh "$out"
