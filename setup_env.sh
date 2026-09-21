#!/bin/bash
# Prepare this checkout: vendor the Cilk Plus runtime and build the query engine.
#
# The README used to ask for a conda env built around psi4::gcc-5=5.2.0 plus
# isl=0.12.2/mpc=1.0.3/mpfr=3.1.4. That recipe no longer solves (conda-forge
# dropped isl 0.12.2) and was never really needed: the only thing gcc-5 supplied
# is libcilkrts.so.5, which the prebuilt src/cpp_indexing links against.
#
#   $ objdump -p src/cpp_indexing | grep NEEDED
#     libstdc++.so.6  libm.so.6  libcilkrts.so.5  libgcc_s.so.1  libc.so.6
#
# Cilk Plus was removed from GCC in 8.x and no conda channel packages the
# runtime, so this vendors Debian buster's last build (gcc-7 7.4.0-6, verified
# by digest) into ./vendor/lib. Nothing else here is old: cpp_indexing needs
# GLIBCXX <= 3.4.21 and GLIBC <= 2.34, which current systems provide, and the
# query engine compiles fine under modern GCC.
#
# Usage:  ./setup_env.sh [--force]
# Then:   export LD_LIBRARY_PATH="$PWD/vendor/lib:$LD_LIBRARY_PATH"

set -euo pipefail

DEB_URL="https://archive.debian.org/debian/pool/main/g/gcc-7/libcilkrts5_7.4.0-6_amd64.deb"
DEB_SHA256="a83f83de816759636e09d3afda8838c6c1798308dfc9df4b7686b1d0778d3b8a"
SONAME="libcilkrts.so.5"
REAL_NAME="libcilkrts.so.5.0.0"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib_dir="${repo_root}/vendor/lib"
force="${1:-}"

if [[ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]]; then
    echo "ERROR: the indexing binaries are prebuilt linux-64 (amd64); this host is $(uname -s)-$(uname -m)." >&2
    exit 1
fi

# ---- 1. Cilk Plus runtime ----
if [[ -e "${lib_dir}/${SONAME}" && "${force}" != "--force" ]]; then
    echo "[1/2] ${SONAME} already vendored in vendor/lib"
else
    echo "[1/2] Fetching ${SONAME} ..."
    work_dir="$(mktemp -d)"
    trap 'rm -rf "${work_dir}"' EXIT
    curl -fsSL -o "${work_dir}/pkg.deb" "${DEB_URL}"
    echo "${DEB_SHA256}  ${work_dir}/pkg.deb" | sha256sum -c - >/dev/null
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "${work_dir}/pkg.deb" "${work_dir}/pkg"
    else
        (cd "${work_dir}" && ar x pkg.deb && mkdir -p pkg && tar -xf data.tar.* -C pkg)
    fi
    src="${work_dir}/pkg/usr/lib/x86_64-linux-gnu/${REAL_NAME}"
    [[ -f "${src}" ]] || { echo "ERROR: ${REAL_NAME} missing from the .deb payload." >&2; exit 1; }
    mkdir -p "${lib_dir}"
    install -m 0644 "${src}" "${lib_dir}/${REAL_NAME}"
    ln -sfn "${REAL_NAME}" "${lib_dir}/${SONAME}"
    echo "      installed vendor/lib/${SONAME}"
fi

chmod +x "${repo_root}/src/cpp_indexing" "${repo_root}/src/rust_indexing"

# ---- 2. Query engine ----
echo "[2/2] Building the query engine ..."
ext_suffix="$(python3-config --extension-suffix)"
(
    cd "${repo_root}/engine"
    c++ -std=c++17 -O3 -shared -fPIC \
        $(python3 -m pybind11 --includes) \
        src/cpp_engine.cpp \
        -o "src/cpp_engine${ext_suffix}" \
        -I../sdsl/include -L../sdsl/lib \
        -lsdsl -ldivsufsort -ldivsufsort64 -pthread 2>/dev/null
)
echo "      built engine/src/cpp_engine${ext_suffix}"

# cpp_indexing exits 1 on its usage message, so check what it prints.
probe="$(LD_LIBRARY_PATH="${lib_dir}:${LD_LIBRARY_PATH:-}" "${repo_root}/src/cpp_indexing" 2>&1 || true)"
if [[ "${probe}" != *Usage:* ]]; then
    echo "ERROR: cpp_indexing could not start. Reported: ${probe}" >&2
    exit 1
fi

cat <<MSG

Ready. Add the runtime to your loader path:

  export LD_LIBRARY_PATH="${lib_dir}:\$LD_LIBRARY_PATH"

then index a corpus of .jsonl / .jsonl.gz / .jsonl.zst files:

  cd src && python indexing.py --data_dir <abs> --save_dir <abs> --mem <GiB>
MSG
