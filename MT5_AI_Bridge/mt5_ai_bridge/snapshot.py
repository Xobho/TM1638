"""Writes a JSON snapshot of recent market data + detected ICT structure to a
file inside this git repo, and pushes it on a fixed interval. This lets the
live feed be inspected (e.g. by pulling the repo) without needing any inbound
network access to the machine running the bridge -- the trusted machine only
ever pushes non-sensitive market data outward, it never accepts connections."""

from __future__ import annotations

import json
import logging
import subprocess
import threading
from pathlib import Path

log = logging.getLogger("mt5_ai_bridge.snapshot")


class SnapshotPusher:
    def __init__(self, repo_dir: str, snapshot_dir: str, branch: str,
                 push_interval_seconds: int = 300):
        self.repo_dir = Path(repo_dir).resolve()
        self.snapshot_dir = self.repo_dir / snapshot_dir
        self.snapshot_dir.mkdir(parents=True, exist_ok=True)
        self.branch = branch
        self.push_interval_seconds = push_interval_seconds
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def write(self, symbol: str, payload: dict) -> None:
        """Overwrites this symbol's snapshot file with the latest payload.
        Writes to a temp file first so a concurrent push never sees a half-written file."""
        path = self.snapshot_dir / f"{symbol}.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, indent=2, default=str))
        tmp.replace(path)

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, daemon=True, name="snapshot-pusher")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=10)

    def _loop(self) -> None:
        while not self._stop.wait(self.push_interval_seconds):
            try:
                self.push_now()
            except Exception:
                log.exception("Snapshot push failed -- will retry next interval")

    def push_now(self) -> None:
        rel = str(self.snapshot_dir.relative_to(self.repo_dir))
        if not self._run(["git", "status", "--porcelain", rel]).strip():
            return  # nothing changed since the last push
        self._run(["git", "add", rel])
        self._run(["git", "commit", "-m", "Update live market snapshot [automated]"])
        self._run(["git", "push", "origin", self.branch])
        log.info("Pushed updated live snapshot to %s", self.branch)

    def _run(self, args: list[str]) -> str:
        result = subprocess.run(args, cwd=self.repo_dir, capture_output=True,
                                 text=True, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(f"{' '.join(args)} failed: {result.stderr.strip()}")
        return result.stdout
