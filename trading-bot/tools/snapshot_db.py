#!/usr/bin/env python3
"""A compact, consistent copy of a running bot's database for Paper-Live.

  python3 tools/snapshot_db.py bot.sqlite bot.sqlite.gz

The live database keeps every judged token; the copy that travels between runs
(and must stay well under GitHub's 100 MB file limit) keeps:
  - accounts, positions, trades, events, ticks, the crypto desk (kv) – all of it,
  - every candidate of the last KEEP_FULL_H hours,
  - older candidates that were bought or watched, or that have a price path
    (the backtest's and the probes' data),
  - a fixed sample of the older "skip" candidates (every SAMPLE-th id), so the edge
    report still has its baseline,
and the outcomes of the candidates it keeps. The source is opened read-only and
never changed."""
from __future__ import annotations

import gzip
import os
import shutil
import sqlite3
import sys
import time

KEEP_FULL_H = 24
SAMPLE = 20


def compact(path: str, now: float, keep_full_h: float = KEEP_FULL_H, sample: int = SAMPLE) -> dict[str, int]:
    db = sqlite3.connect(path)
    cut = now - keep_full_h * 3600
    before = db.execute("SELECT count(*) FROM candidates").fetchone()[0]
    db.executescript("CREATE TEMP TABLE keep_path AS SELECT DISTINCT candidate_id AS id FROM paths;")
    db.execute(
        "DELETE FROM candidates WHERE seen_at < ? AND decision = 'skip' AND id % ? != 0"
        " AND id NOT IN (SELECT id FROM keep_path)", (cut, sample))
    db.execute("DELETE FROM outcomes WHERE candidate_id NOT IN (SELECT id FROM candidates)")
    db.commit()
    after = db.execute("SELECT count(*) FROM candidates").fetchone()[0]
    db.execute("VACUUM")
    db.close()
    return {"before": before, "after": after}


def snapshot(src: str, out_gz: str, now: float | None = None) -> dict[str, int]:
    tmp = out_gz + ".tmp.sqlite"
    source = sqlite3.connect(f"file:{src}?mode=ro", uri=True)      # never create an empty one
    copy = sqlite3.connect(tmp)
    source.backup(copy)
    copy.close()
    source.close()
    counts = compact(tmp, time.time() if now is None else now)
    part = out_gz + ".part"
    with open(tmp, "rb") as f, gzip.open(part, "wb") as g:
        shutil.copyfileobj(f, g)
    os.replace(part, out_gz)
    os.remove(tmp)
    counts["bytes"] = os.path.getsize(out_gz)
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    c = snapshot(argv[1], argv[2])
    print(f"Konto gesichert: {c['after']} von {c['before']} Kandidaten, {c['bytes'] / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
