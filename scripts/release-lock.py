"""Serialize App Store release writes for this bundle ID on this Mac."""

import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock_holders(path):
    """Processes other than this one with the lock file open, as "PID command" lines."""
    try:
        found = subprocess.run(["lsof", "-t", str(path)], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    pids = sorted({int(p) for p in found.split()} - {os.getpid()})
    holders = []
    for pid in pids:
        try:
            command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                                     capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            command = ""
        holders.append(f"{pid} {command or '?'}")
    return holders


def held_message(bundle_id, path, recorded):
    lines = [f"Release already running for {bundle_id}: {recorded}"]
    holders = lock_holders(path)
    if holders is None:
        lines.append(f"Could not list the lock's holders (lsof failed); try: lsof {path}")
    elif holders:
        lines.append("Processes holding the lock:")
        lines += [f"  {h}" for h in holders]
    match = re.search(r"\(PID (\d+)\)", recorded)
    if match and not pid_alive(int(match.group(1))):
        lines.append(f"Recorded PID {match.group(1)} is no longer running; a leftover child still holds the lock. "
                     "Stop the processes above to release it.")
    return "\n".join(lines)


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
                print(held_message(bundle_id, lock.name, lock.read().strip()), file=sys.stderr)
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
