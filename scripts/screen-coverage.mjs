// FIT-458: which screens in appstore/review/screens.json the review demo showed.
//   node scripts/screen-coverage.mjs build/review/screens-shown.txt
// The marks file has one `role screen-id` line per screen shown, written by ReviewDemoUITests (DemoScreens.shown).
// Exits 1 when a required screen was never shown, or a mark names a screen the inventory doesn't have.
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { coverage, parseExcludes, parseMarks, report } from "./screens-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const marksPath = process.argv[2];
if (!marksPath) {
  console.error("Usage: node scripts/screen-coverage.mjs <screens-shown.txt>");
  process.exit(2);
}
const inv = JSON.parse(readFileSync(resolve(root, "appstore/review/screens.json"), "utf8"));
const excludes = parseExcludes(readFileSync(resolve(root, "appstore/review/coverage-exclude.txt"), "utf8"));
const marks = existsSync(marksPath) ? parseMarks(readFileSync(marksPath, "utf8")) : [];
const result = coverage(inv, marks, excludes);
console.log(report(result));
process.exit(result.ok ? 0 : 1);
