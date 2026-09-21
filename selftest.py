#!/usr/bin/env python3
"""Self-contained regression test: build a small index and verify it.

Covers the three defects fixed in this fork, each of which failed silently
rather than raising:

  1. the lowest byte value in a corpus was unsearchable, which zeroed every
     multi-word query in corpora whose text had no newlines
  2. small corpora crashed in rust_indexing (merge, then separately concat)
  3. an incomplete index loaded happily and answered 0 to everything

Run with `pixi run test`. Needs a build first (`pixi run build`).
"""

from __future__ import annotations

import json
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
sys.path.insert(0, str(HERE / "engine"))

WORDS = ["alpha", "beta", "gamma", "delta", "supply", "chain", "vienna"]
PHRASE = "natural language processing"


def ocount(hay: bytes, needle: bytes) -> int:
    n, i = 0, hay.find(needle)
    while i != -1:
        n, i = n + 1, hay.find(needle, i + 1)
    return n


def make_corpus(path: Path, n_docs: int, newlines: bool) -> list[bytes]:
    rng = random.Random(0)
    texts = []
    with path.open("w") as f:
        for i in range(n_docs):
            body = " ".join(rng.choice(WORDS) for _ in range(60))
            if i % 200 == 0:
                body += f" {PHRASE} is here"
            text = f"doc {i}:\n{body}\n" if newlines else f"doc {i}: {body}"
            texts.append(text.encode())
            f.write(json.dumps({"text": text, "src": "selftest"}) + "\n")
    return texts


def build_index(data_dir: Path, save_dir: Path, cpus: int) -> bool:
    r = subprocess.run(
        [sys.executable, "indexing.py", "--data_dir", str(data_dir),
         "--save_dir", str(save_dir), "--mem", "4", "--cpus", str(cpus),
         "--ulimit", "4096"],
        cwd=SRC, capture_output=True, text=True,
    )
    ok = r.returncode == 0 and (save_dir / "data.fm9").is_file()
    if not ok:
        print(r.stdout[-800:], file=sys.stderr)
        print(r.stderr[-800:], file=sys.stderr)
    return ok


def check(name: str, got, want) -> bool:
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {name}: got {got}, want {want}")
    return ok


def main() -> int:
    from src.engine import InfiniGramMiniEngine  # noqa: E402

    failures = 0
    with tempfile.TemporaryDirectory(prefix="igm-selftest-") as tmp:
        tmp = Path(tmp)

        # --- 1. no newlines: the space is the lowest byte (the sentinel bug) ---
        print("1. corpus whose text contains no newlines (lowest byte = space)")
        data, idx = tmp / "d1", tmp / "i1"
        data.mkdir()
        texts = make_corpus(data / "c.jsonl", 4000, newlines=False)
        corpus = b"\xff".join(texts)
        if not build_index(data, idx, cpus=4):
            print("  FAIL  indexing failed"); return 1
        e = InfiniGramMiniEngine(index_dirs=[str(idx)], load_to_ram=False, get_metadata=True)
        failures += not check("space is searchable", e.count(" ")["count"], ocount(corpus, b" "))
        failures += not check(f"{PHRASE!r}", e.count(PHRASE)["count"], ocount(corpus, PHRASE.encode()))
        failures += not check("'alpha beta'", e.count("alpha beta")["count"], ocount(corpus, b"alpha beta"))

        # --- 2. a corpus small enough to have broken make-part/merge/concat ---
        print("2. small corpus with more cpus than it can usefully split")
        data, idx = tmp / "d2", tmp / "i2"
        data.mkdir()
        texts = make_corpus(data / "c.jsonl", 60, newlines=True)
        corpus = b"\xff".join(texts)
        if not build_index(data, idx, cpus=16):
            print("  FAIL  indexing a small corpus failed"); failures += 1
        else:
            e = InfiniGramMiniEngine(index_dirs=[str(idx)], load_to_ram=False, get_metadata=True)
            failures += not check("'supply'", e.count("supply")["count"], ocount(corpus, b"supply"))
            failures += not check("newline", e.count("\n")["count"], ocount(corpus, b"\n"))

        # --- 3. an incomplete index must raise, not answer 0 ---
        print("3. incomplete index raises instead of answering 0")
        broken = tmp / "broken"
        broken.mkdir()
        (broken / "data_offset").write_bytes(b"")
        try:
            InfiniGramMiniEngine(index_dirs=[str(broken)], load_to_ram=False, get_metadata=True)
            print("  FAIL  no error raised for an index with no .fm9"); failures += 1
        except FileNotFoundError:
            print("  PASS  FileNotFoundError raised")

    print()
    print("selftest: " + ("all checks passed" if not failures else f"{failures} FAILURES"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
