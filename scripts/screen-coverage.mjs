// FIT-458: which screens in appstore/review/screens.json the review demo showed.
//   node scripts/screen-coverage.mjs build/review/screens-shown.txt [--roles client,coach] [--also other-marks.txt]...
// TKL-460: --roles owes every screen those roles can reach, shared ones too (see coverage in screens-lib.mjs); --also
// adds another recording's marks (the solo chapter's), so a screen it showed counts. A missing --also file exits 2.
// The marks file has one `role screen-id` line per screen shown, written by ReviewDemoUITests (DemoScreens.shown).
// Exits 1 when a required screen was never shown, or a mark names a screen the inventory doesn't have.
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { coverage, parseExcludes, parseMarks, report } from "./screens-lib.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const args = process.argv.slice(2);
const at = args.indexOf("--roles");
const roles = at >= 0 ? args.splice(at, 2)[1]?.split(",").map((role) => role.trim()).filter(Boolean) : undefined;
const also = [];
for (let i = args.indexOf("--also"); i >= 0; i = args.indexOf("--also")) also.push(args.splice(i, 2)[1]);
const marksPath = args[0];
if (!marksPath || (at >= 0 && !roles?.length) || also.some((path) => !path)) {
  console.error("Usage: node scripts/screen-coverage.mjs <screens-shown.txt> [--roles client,coach] [--also other-marks.txt]");
  process.exit(2);
}
const absent = also.find((path) => !existsSync(path));
if (absent) {
  console.error(`No marks file at ${absent}`);
  process.exit(2);
}
const inv = JSON.parse(readFileSync(resolve(root, "appstore/review/screens.json"), "utf8"));
const excludes = parseExcludes(readFileSync(resolve(root, "appstore/review/coverage-exclude.txt"), "utf8"));
const marks = [marksPath, ...also].flatMap((path) => (existsSync(path) ? parseMarks(readFileSync(path, "utf8")) : []));
const result = coverage(inv, marks, excludes, { roles });
console.log(report(result));
process.exit(result.ok ? 0 : 1);
