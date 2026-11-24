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
