import { spawnSync } from "node:child_process";
import { recoverUploadedBump } from "./release-lib.mjs";

const [number, sha] = process.argv.slice(2);
try {
  recoverUploadedBump(number, sha, (command, args) => {
    const result = spawnSync(command, args, { encoding: "utf8" });
    return { code: result.status, stdout: result.stdout, stderr: result.error?.message ?? result.stderr };
  });
  console.log(`origin/main records build ${number} or later. Resume processing for build ${number}.`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
