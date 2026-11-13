// FIT-458: write appstore/review/screens.json, every screen the app can show, from App/ and Features/.
//   node scripts/screen-inventory.mjs           → writes the file
//   node scripts/screen-inventory.mjs --check   → exits 1 if the committed file is out of date
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, relative, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { inventory } from "./screens-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const out = resolve(root, "appstore/review/screens.json");

function swift(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return swift(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

const files = ["App", "Features"]
  .flatMap((dir) => swift(resolve(root, dir)))
  .sort()
  .map((path) => ({ path: relative(root, path), source: readFileSync(path, "utf8") }));
const text = JSON.stringify(inventory(files), null, 2) + "\n";

if (process.argv.includes("--check")) {
  const committed = existsSync(out) ? readFileSync(out, "utf8") : "";
  if (committed !== text) {
    console.error("appstore/review/screens.json is out of date. Run: node scripts/screen-inventory.mjs");
    process.exit(1);
  }
  console.log("appstore/review/screens.json is up to date.");
} else {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, text);
  const { screens } = JSON.parse(text);
  const visible = screens.filter((s) => s.roles.length);
  console.log(`${screens.length} screens (${visible.length} reachable in the pilot) → ${relative(root, out)}`);
}
