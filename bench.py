#!/usr/bin/env python3
"""Time FM-index construction across progressively larger slices of a corpus.

Only the cpp_indexing stage is timed. The suffix-array stage that precedes it
(rust_indexing) is already multi-threaded and identical for every backend, so
including it would dilute the comparison -- see the end-to-end note in the
README.

Each size is prepared once, then the timed binary runs on a fresh copy of that
prepared directory, because cpp_indexing consumes its cached SA/BWT input.

  pixi run bench --data-dir /abs/corpus --sizes 64,256,1024 --repeat 2

With no --data-dir a synthetic corpus is generated instead, which is useful for
a quick check but not representative: wt_huff is Huffman-shaped, so the real
byte distribution matters.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"

sys.path.insert(0, str(SRC))
import indexing  # noqa: E402  -- reuse the real prepare/SA stages


def synthetic_corpus(path: Path, target_mb: int) -> None:
    words = [f"w{i:05d}" for i in range(20000)]
    rng = random.Random(0)
    written = 0
    with path.open("w") as f:
        while written < target_mb * 1024 * 1024:
            body = " ".join(rng.choice(words) for _ in range(120))
            line = json.dumps({"text": body + "\n", "src": "synthetic"}) + "\n"
            f.write(line)
            written += len(line)


def slice_corpus(source: Path, dest: Path, target_mb: int) -> int:
    """Copy whole JSON lines from source until target_mb is reached."""
    budget = target_mb * 1024 * 1024
    written = 0
    with dest.open("w") as out:
        for src_file in sorted(source.glob("**/*.json*")):
            with src_file.open() as f:
                for line in f:
                    out.write(line)
                    written += len(line)
                    if written >= budget:
                        return written
    return written


def prepare(data_dir: Path, save_dir: Path, cpus: int, mem: int) -> None:
    args = argparse.Namespace(
        data_dir=str(data_dir), temp_dir=str(save_dir), save_dir=str(save_dir),
        doc_sep=b"\xff", batch_size=65536, cpus=cpus, mem=mem, ulimit=4096,
    )
    save_dir.mkdir(parents=True, exist_ok=True)
    # The prep stages are chatty and are not what is being measured.
    with contextlib.redirect_stdout(io.StringIO()):
        indexing.prepare(args)
        indexing.build_sa_bwt(args, mode="data")
        indexing.build_sa_bwt(args, mode="meta")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data-dir", type=Path, help="corpus of .jsonl files; synthetic if omitted")
    p.add_argument("--sizes", default="64,256", help="comma-separated sizes in MB")
    p.add_argument("--repeat", type=int, default=2)
    p.add_argument("--cpus", type=int, default=16)
    p.add_argument("--mem", type=int, default=32)
    p.add_argument("--work-dir", type=Path, default=HERE / "build" / "bench")
    p.add_argument("--indexer", type=Path, default=SRC / "cpp_indexing",
                   help="binary to time; build it first with `pixi run build <backend>`")
    a = p.parse_args()

    if not a.indexer.is_file():
        print(f"ERROR: {a.indexer} not found -- run `pixi run build` first.", file=sys.stderr)
        return 1

    work = a.work_dir
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    print(f"indexer: {a.indexer}")
    print(f"{'size':>8}  {'runs (ms)':<28} {'mean':>9}  {'MB/s':>7}")

    for size_mb in [int(s) for s in a.sizes.split(",")]:
        data = work / f"data_{size_mb}"
        data.mkdir()
        if a.data_dir:
            actual = slice_corpus(a.data_dir, data / "corpus.jsonl", size_mb)
        else:
            synthetic_corpus(data / "corpus.jsonl", size_mb)
            actual = (data / "corpus.jsonl").stat().st_size

        base = work / f"prep_{size_mb}"
        prepare(data, base, a.cpus, a.mem)

        times = []
        for _ in range(a.repeat):
            run = work / f"run_{size_mb}"
            shutil.rmtree(run, ignore_errors=True)
            shutil.copytree(base, run)
            t0 = time.perf_counter()
            subprocess.run([str(a.indexer), str(run)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            times.append((time.perf_counter() - t0) * 1000)
            digest = run / "data.fm9"
            if not digest.is_file():
                print(f"  {size_mb} MB: FAILED -- no data.fm9 produced", file=sys.stderr)
                return 1
            shutil.rmtree(run, ignore_errors=True)
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree(data, ignore_errors=True)

        mean = sum(times) / len(times)
        runs = " ".join(f"{t:.0f}" for t in times)
        print(f"{size_mb:>6} MB  {runs:<28} {mean:>8.0f}ms  {actual/1e6/(mean/1000):>7.1f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
