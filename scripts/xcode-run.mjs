// TKL-1092: route every xcodebuild in ai-coach-app through the machine-wide Xcode build lock
// (~/dev/factory/bin/xcode-lock.js), so scripts and hand runs (`npm run xcode -- ...`) serialize
// cleanly with dispatched builds, ship, and device-install.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export function resolveXcodeLockBin(env = process.env) {
  return env.FACTORY_XCODE_LOCK_BIN || join(homedir(), "dev", "factory", "bin", "xcode-lock.js");
}

export function xcodeCommand(args = [], { env = process.env, exists = existsSync } = {}) {
  const bypass = /^(1|true|yes)$/i.test(String(env.XCODE_LOCK_BYPASS ?? "").trim());
  const lockBin = resolveXcodeLockBin(env);
  if (!bypass && lockBin && exists(lockBin)) {
    return { command: process.execPath, args: [lockBin, ...args], locked: true };
  }
  return { command: "xcodebuild", args: [...args], locked: false };
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const { command, args } = xcodeCommand(process.argv.slice(2));
  const child = spawn(command, args, { stdio: "inherit", env: process.env });
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => {
      try { child.kill(sig); } catch {}
    });
  }
  child.on("error", (err) => {
    console.error(`xcode-run: failed to start ${command}: ${err.message}`);
    process.exit(127);
  });
  child.on("close", (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    process.exit(code ?? 1);
  });
}
