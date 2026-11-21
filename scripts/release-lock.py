"""Serialize App Store release writes for this bundle ID on this Mac."""

import fcntl
import json
import os
from pathlib import Path
import sys


def acquire_lock(root):
    bundle_id = json.loads((root / "appstore/review.json").read_text())["bundleId"]
    locks = Path.home() / "dev/factory/state/locks"
    locks.mkdir(parents=True, exist_ok=True)
    # Keep these inodes in place. The startup lock serializes metadata changes
    # so a contender always reads the holder that acquired the release lock.
    with (locks / f"{bundle_id}.startup.lock").open("a") as startup:
        fcntl.flock(startup, fcntl.LOCK_EX)
        with (locks / f"{bundle_id}.release.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lock.seek(0)
                print(f"Release already running for {bundle_id}: {lock.read().strip()}", file=sys.stderr)
                sys.exit(1)

            run_id = os.environ.get("FACTORY_RUN_ID") or "manual"
            lock.truncate(0)
            lock.write(f"{run_id} (PID {os.getpid()})\n")
            lock.flush()

            # Keep one descriptor open in Node. The kernel drops the lock even
            # if Node is killed, so the next invocation replaces stale metadata.
            return os.dup(lock.fileno())


def main():
    root = Path(__file__).resolve().parent.parent
    args = sys.argv[1:]
    if not {"--dry-run", "--help", "-h"}.intersection(args):
        lock_fd = acquire_lock(root)
        os.set_inheritable(lock_fd, True)
    os.execvp("node", ["node", str(root / "scripts/release.mjs"), *args])


if __name__ == "__main__":
    main()
