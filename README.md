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

To query a local index (e.g., `pile-train`), you need to initialize an engine with the corresponding index and invoke its methods.
Below is a step-by-step example.

### 1. Initialize the engine

Create an engine instance using the appropriate index directory.
You can configure:

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


## Building

```command
pixi run build
```

That compiles libdivsufsort, sdsl, the `cpp_indexing` binary and the pybind11 query engine with any C++17 compiler.
No old GCC, no Cilk runtime, nothing prebuilt.
Rebuilds are cached on the source files.

Backends, selected by `parallel_sdsl/include/sdsl/parallel.hpp`:

| build | parallelism | needs |
| --- | --- | --- |
| `pixi run build` | OpenMP tasks + taskloop | any C++17 compiler (default) |
| `pixi run build serial` | none | any C++17 compiler (reference) |
| `pixi run build-opencilk` | `cilk_spawn` / `cilk_for` | [OpenCilk](https://opencilk.org), fetched by the task |

All three produce byte-identical indexes.
See [Performance](#performance) for which to use.

Other tasks:

| task | |
| --- | --- |
| `pixi run test` | regression tests for the bugs fixed here |
| `pixi run bench` | time construction over progressively larger corpora |
| `pixi run index` | index a corpus (arguments below) |

<details>
<summary>Why the old <code>psi4::gcc-5=5.2.0</code> instructions are gone</summary>

Upstream shipped `src/cpp_indexing` as a 2019 amd64 binary built with gcc-5 and Intel Cilk Plus, so running it needed `libcilkrts.so.5`:

```command
$ objdump -p src/cpp_indexing | grep NEEDED
  libstdc++.so.6   libm.so.6   libcilkrts.so.5   libgcc_s.so.1   libc.so.6
```

Installing gcc-5 was only ever a way to obtain that library.
The recipe no longer works anyway -- conda-forge dropped `isl 0.12.2` -- and it was never necessary: `indexing.cpp`'s own header comment documents a non-Cilk build, and Cilk Plus itself was removed from GCC in 8.x.

This fork builds everything from source instead.
The result is byte-identical to the binary upstream shipped, and depends only on libstdc++/libm/libgcc_s/libc, plus libgomp for the OpenMP build.

`src/rust_indexing` is still used as a prebuilt binary and is the one artifact
not built here -- but its source *is* in this repo, under `suffix_array/` (a
Cargo crate, `rust_indexing` 1.0.0). Building it would remove the last prebuilt
artifact and lift the linux-64 restriction. Note `overflow-checks = false` in
its `Cargo.toml`: that is why an underflow in the merge step surfaces as
`range end index 18446744073709491749` rather than a clean panic.
</details>

## Indexing new datasets

Input is a directory of `.jsonl`, `.jsonl.gz` or `.jsonl.zst` files, one JSON object per line with a `text` field.
Every other field is kept as metadata and returned with search hits.
Paths must be absolute.

```command
pixi run index --data_dir /abs/corpus --save_dir /abs/index --mem 32
```

`--cpus` defaults to every core; `--ulimit` defaults to 1048576, which exceeds the hard limit on some hosts, so lower it if `setrlimit` fails.
For the full download-and-index workflows see `src/index_v2_dclm.py`, `src/index_v2_cc.py` and friends.

## Performance

Only the `cpp_indexing` stage is timed below.
The suffix-array stage before it (`rust_indexing`) is already multi-threaded and identical for every backend, so including it would dilute the comparison; the end-to-end effect is noted after the table.

Mean of 2-3 runs on one machine (64 cores, `OMP_NUM_THREADS=16`, `CILK_NWORKERS=16`, intermediates on tmpfs). Every backend produced byte-identical `data.fm9` at every size.

| corpus | serial (gcc) | **OpenMP (gcc)** | serial (clang) | OpenCilk |
| --- | --- | --- | --- | --- |
| 120 MB synthetic | 6.98 s | **3.27 s — 2.14x** | — | 6.10 s |
| 213 MB real text | 11.48 s | **5.21 s — 2.20x** | 13.25 s | 9.57 s — 1.38x |
| 1.0 GB real text | 53.0 s | **24.4 s — 2.17x** | 62.8 s | 44.9 s — 1.40x |

The speedup is flat at ~2.2x across an 8x range of corpus sizes, and unchanged between synthetic text and real web text -- which is not a given, since `wt_huff` builds a Huffman-shaped wavelet tree whose shape depends on the byte distribution.

**OpenMP is the default because it wins on both counts.** Each parallel backend is compared against a serial build from *its own* compiler, because clang's serial codegen is ~15-18% slower than gcc's here; OpenCilk's honest figure is 1.40x against its own baseline, not 2.17x's worth.
In absolute terms OpenMP is 1.8x faster than OpenCilk, and it needs no 1.4 GB toolchain.

**End to end the gain is smaller.** On the 1 GB corpus the `rust_indexing` prep took 107 s, so the pipeline goes 107 + 53 = 160 s serial to 107 + 24 = 131 s, about 1.22x.
The 2.17x is real but applies to one stage.

Reproduce with `pixi run bench --data-dir /abs/corpus --sizes 128,512,1024`, which times progressively larger slices. Omit `--data-dir` for a synthetic corpus, which is convenient but not representative for the reason above.

### Correctness

Validated against ground truth on real Common Crawl text at each size, counting with overlapping byte semantics:

* every distinct ASCII byte, ~600 random substrings of length 3-45, multi-word   domain queries, multi-byte UTF-8 characters, and document/metadata round-trips -- all exact
* both prepare paths: `prepare_fewfiles` and, at 1 GB across 100 files, `prepare_manyfiles`
* all four builds produce byte-identical indexes at every size

`pixi run test` covers the three defects below as regressions.

## Changes in this fork

**Everything C++ builds from source with a current toolchain.** Upstream's prebuilt gcc-5/Cilk `cpp_indexing` and its 2019 static libraries are gone, along with the `libcilkrts.so.5` requirement.
Getting there needed six fixes that modern compilers surface but older ones did not:

* `louds_tree.hpp` referenced `tree.m_select1/0` where the members are `m_bv_select1/0` — never diagnosed while the template went uninstantiated.
* `csa_sampling_strategy.hpp` called `construct()` before any declaration was visible; GCC 15 enforces two-phase lookup.
`construct.hpp` includes that header, so the call is routed through a dependent type and resolved at instantiation instead.
* The prebuilt `libdivsufsort.a` was non-PIE, which modern toolchains reject when linking a PIE executable.
The source is now vendored under `external/` and compiled with `-fPIC`; only the `.a` files were in this repo before.
* `wt_hutu.hpp` compared `h1->left->rank < h1->right->rank`, which Clang parses as the start of a template argument list; parenthesised.
Only surfaced once a second compiler was in play.
* The build originally produced only the 32-bit libdivsufsort, while sdsl's `construct_sa` references `divsufsort64`.
GCC optimised the reference away so the GCC builds linked by luck; Clang did not.
Both variants are built now.
* `parallel.hpp`'s OpenMP branch defined `cilk_spawn`/`cilk_sync` as **empty**, silently serialising every recursive spawn.
It now maps them onto OpenMP tasks, and adds an OpenCilk branch.
Two Cilk behaviours needed care: Cilk syncs implicitly when a function returns (five spawn sites relied on it, so explicit syncs were added — no-ops under Cilk/OpenCilk), and OpenMP tasks only go parallel inside a region, so loops became `taskloop` and recursive entry points are wrapped in `spawn_region()`.

The 24 Cilk call sites are unchanged; all of it lives in `parallel.hpp`.
See [Performance](#performance) for what the backends measure at.

**Fixed: the lowest byte value in a corpus was silently unsearchable.** `prepare` wrote the indexed text as `[0xff doc][0xff doc]…[0xfa]`, which never contains `0x00`.
sdsl's CSA reserves comp 0 for its own sentinel, so with no `0x00` present the smallest byte actually occurring in the corpus took that slot and `backward_search` returned 0 for it — while every other byte counted correctly.
In a corpus whose `text` fields contain no newlines, that smallest byte is the space, so **every multi-word query silently returned zero**:

```text
count('alpha')                        = 47947    correct
count('natural language processing')  = 0        wrong (should be 10)
count(' ')                            = 0        wrong (488050 spaces present)
```

The fix appends a `0x00` sentinel to the indexed text in both `prepare_fewfiles` and `prepare_manyfiles`, so comp 0 is occupied by a byte no one searches for.
After it, all 33 distinct bytes of that corpus count exactly right.

**Fixed: an incomplete index answered 0 to every query.** A failed or interrupted indexing run leaves the intermediate `.sdsl` files but no `.fm9`, and the engine loaded that directory without complaint, reporting 0 for everything rather than erroring.
`InfiniGramMiniEngine` now checks up front.

**Fixed: indexing crashed on small corpora.** `make-part` overlapped parts by `HACK = 100000` bytes and `merge` subtracted the same amount, so when a part was smaller than the overlap the subtraction underflowed:

```text
thread '<unnamed>' panicked at src/main.rs:395:52:
range end index 18446744073709491749 out of range for slice of length 40133
```

The overlap is now capped at the part size (`hack = min(HACK, S)`), applied consistently to both `make-part` and `merge`.
`concat` then turned out to panic separately (`main.rs:534`) once parts get down to ~10 KB — an 84 KB corpus built fine at `--cpus 4` but died at `--cpus 8` — so parts are additionally kept above a 1 MiB floor by using fewer jobs, reporting when it does so.
Neither cap binds on a corpus large enough to need the parallelism.

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
