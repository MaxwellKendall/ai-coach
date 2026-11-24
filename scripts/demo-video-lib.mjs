import { spawn } from "node:child_process";

// TKL-908: run `restore` however the process ends. "exit" alone misses a signal: the factory stops a run at its
// timeout with SIGTERM, and before this the demo logins stayed compiled into Tests/UITests/Secrets.swift.
const exitCodes = { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 };

export function restoreOnStop(restore) {
  let done = false;
  const once = () => {
    if (done) return;
    done = true;
    restore();
  };
  process.on("exit", once);
  for (const [signal, code] of Object.entries(exitCodes)) {
    process.on(signal, () => {
      once();
      process.exit(code);
    });
  }
  return once;
}

export function startRecorder(command, args) {
  const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  let started;
  const ready = new Promise((resolve) => { started = resolve; });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    if (stderr.includes("Recording started")) started();
  });
  const closed = new Promise((resolve) => {
    child.once("error", (error) => resolve({ error }));
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  const failure = ({ error, code, signal }) =>
    new Error(`Simulator recorder exited (${error?.message ?? signal ?? code}). ${stderr.trim()}`);

  return {
    async waitForStart() {
      let timeout;
      try {
        await Promise.race([
          ready,
          closed.then((result) => { throw failure(result); }),
          new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error("Simulator recorder did not start within 15 seconds.")), 15_000);
          }),
        ]);
      } finally {
        clearTimeout(timeout);
      }
    },
    interrupt() {
      child.kill("SIGINT");
    },
    async stop() {
      const interrupted = child.kill("SIGINT");
      const result = await closed;
      if (!interrupted || result.code !== 0) throw failure(result);
    },
  };
}
