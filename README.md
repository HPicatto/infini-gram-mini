# 📖 Infini-gram mini

> **Fork note.** This fork drops the gcc-5 requirement for indexing and fixes
> two indexing bugs (a silently unsearchable byte, and a crash on small
> corpora). See [Changes in this fork](#changes-in-this-fork).

This repo hosts the source code of the infini-gram mini search engine, which is described in this paper: Infini-gram mini: Exact n-gram Search at the Internet Scale with FM-Index.

To learn more about infini-gram mini:
* Paper: <https://arxiv.org/abs/2506.12229>
* Project Home: <https://infini-gram-mini.io/>
* Web Interface: <https://infini-gram-mini.io/demo>
* API Endpoint: <https://infini-gram-mini.io/api_doc>
* Code: <https://infini-gram-mini.io/code>
* Benchmark Contamination Monitoring System: <https://infini-gram-mini.io/bulletin>


## Overview

Infini-gram mini is an engine that processes queries on the largest body of text in the current open-source community (as of May 2025).
It can count the occurrence of arbitrarily long strings in 45.6 TB of text corpora and retrieve their containing documents in seconds.

Infini-gram mini is powered by indexes based on FM-Index.
This repo contains everything you might need for constructing an infini-gram mini index of a text corpus, and perform queries on this index.


## Getting Started

To query a local index (e.g., `pile-train`), you need to initialize an engine with the corresponding index and invoke its methods. Below is a step-by-step example.

### 1. Initialize the engine

Create an engine instance using the appropriate index directory. You can configure:

- Whether the index stays on disk (`load_to_ram=False`, uses less RAM but is slower), or is fully loaded into memory (`load_to_ram=True`, uses more RAM but is faster).
- Whether to return metadata for each result (`get_metadata=True`).

```python
from src.engine import InfiniGramMiniEngine

engine = InfiniGramMiniEngine(index_dirs=["../index/v2_piletrain"], load_to_ram=False, get_metadata=True)
```

### 2. Counting a query

To count the occurrences of a string `natural language processing` in Pile-train corpus:

```python
query = "natural language processing"
engine.count(query)
#83,470
```

### 3. Retrieving a matching document

First, call `find()` to get information about where the query locates.

```python
engine.find(query)
# {"cnt":83470, "segment_by_shard":[[442381579355,442381620985],[443017902435,443017944275]]}
```
- `segment_by_shard` is a list of `[start, end]` byte ranges in each shard where the query appears.

Then, to retrieve text snippet around the first occurrance in shard 0:
```python
engine.get_doc_by_rank(s=0, rank=442381579355, needle_len=len(query), max_ctx_len=20)
# {"disp_len":67, "doc_ix":48649509, "doc_len":813513, "metadata":{"path": "06.jsonl", "linenum": 6526203, "metadata": {"meta": {"pile_set_name": "HackerNews"}}}, "needle_offset":20, "text":"Research Engineer \\- natural language processing\n\n    \n    \n      - "}
```


## Customizing the engine
If you modify the C++ backend of the engine, follow the steps below to recompile and use your custom version:

### 1. Prerequisites

Make sure you have the following installed:

- A C++ compiler with support for `-std=c++17`
- The `pybind11` Python package:
  ```bash
  pip install pybind11
  ```

### 2. Compilation
Under `engine` folder, compile with the following command:
```command
c++ -std=c++17 -O3 -shared -fPIC $(python3 -m pybind11 --includes) src/cpp_engine.cpp -o src/cpp_engine$(python3-config --extension-suffix) -I../sdsl/include -L../sdsl/lib -lsdsl -ldivsufsort -ldivsufsort64 -pthread
```

### 3. Import the engine
Once compiled, you can import and use the customized engine in Python:
```python
from engine.src import InfiniGramMiniEngine
```

## Indexing new datasets

### 1. Prerequisites

Run the setup script. It vendors the one library the prebuilt indexer needs and
builds the query engine:

```command
./setup_env.sh
export LD_LIBRARY_PATH="$PWD/vendor/lib:$LD_LIBRARY_PATH"
```

You need Python with `numpy`, `tqdm` and `zstandard`, plus `pybind11` and any
C++17 compiler for the engine. No old GCC required.

<details>
<summary>Why the old <code>psi4::gcc-5=5.2.0</code> instructions are gone</summary>

The prebuilt `src/cpp_indexing` is linked against the Cilk Plus runtime:

```command
$ objdump -p src/cpp_indexing | grep NEEDED
  libstdc++.so.6   libm.so.6   libcilkrts.so.5   libgcc_s.so.1   libc.so.6
```

Installing gcc-5 was only ever a way to obtain `libcilkrts.so.5`. That recipe no
longer works — conda-forge dropped `isl 0.12.2` — and it was never necessary.
Cilk Plus was removed from GCC in 8.x and no conda channel packages the runtime,
so `setup_env.sh` vendors Debian buster's last build (`gcc-7 7.4.0-6`, verified
by sha256) into `vendor/lib`.

Nothing else in the toolchain is old: `cpp_indexing` requires only GLIBCXX
≤ 3.4.21 and GLIBC ≤ 2.34, `rust_indexing` needs nothing beyond libc, and the
query engine compiles cleanly under GCC 15 against the prebuilt `libsdsl.a`.
</details>

### 2. Run the indexing script

Go to `src/` and run `python indexing.py` with the appropriate arguments.

We have scripts for the full workflow of downloading datasets and indexing them, which you can refer to: `index_v2_dclm.py`, `index_v2_cc.py`, etc.

## Changes in this fork

**Indexing no longer needs gcc-5.** See the prerequisites above.

**Fixed: the lowest byte value in a corpus was silently unsearchable.**
`prepare` wrote the indexed text as `[0xff doc][0xff doc]…[0xfa]`, which never
contains `0x00`. sdsl's CSA reserves comp 0 for its own sentinel, so with no
`0x00` present the smallest byte actually occurring in the corpus took that slot
and `backward_search` returned 0 for it — while every other byte counted
correctly. In a corpus whose `text` fields contain no newlines, that smallest
byte is the space, so **every multi-word query silently returned zero**:

```text
count('alpha')                        = 47947    correct
count('natural language processing')  = 0        wrong (should be 10)
count(' ')                            = 0        wrong (488050 spaces present)
```

The fix appends a `0x00` sentinel to the indexed text in both `prepare_fewfiles`
and `prepare_manyfiles`, so comp 0 is occupied by a byte no one searches for.
After it, all 33 distinct bytes of that corpus count exactly right.

**Fixed: indexing crashed on small corpora.** `make-part` overlapped parts by
`HACK = 100000` bytes and `merge` subtracted the same amount, so when a part was
smaller than the overlap the subtraction underflowed:

```text
thread '<unnamed>' panicked at src/main.rs:395:52:
range end index 18446744073709491749 out of range for slice of length 40133
```

The overlap is now capped at the part size (`hack = min(HACK, S)`), applied
consistently to both `make-part` and `merge`. Unchanged for any corpus large
enough that the cap does not bind. Splitting into more jobs than there are bytes
now raises a clear error instead of producing empty parts.

Verified against ground truth on synthetic corpora: 240 random substrings of
length 2–30, counted with overlapping semantics, match exactly on both a capped
and an uncapped index.

## Citation
If you find infini-gram mini useful, please kindly cite our paper:

```bibtex
@misc{xu2025infinigramminiexactngram,
      title={Infini-gram mini: Exact n-gram Search at the Internet Scale with FM-Index}, 
      author={Hao Xu and Jiacheng Liu and Yejin Choi and Noah A. Smith and Hannaneh Hajishirzi},
      year={2025},
      eprint={2506.12229},
      archivePrefix={arXiv},
      primaryClass={cs.CL},
      url={https://arxiv.org/abs/2506.12229}, 
}
```
