#!/bin/bash
# Build the indexer and query engine from source.
#
# Everything here is compiled from source in this repo -- no prebuilt static
# libraries, and no libcilkrts. Upstream shipped src/cpp_indexing as a 2019
# amd64 binary built with gcc-5 and Intel Cilk Plus, which is why installing it
# used to require conda's psi4::gcc-5. indexing.cpp's own header comment
# documented a non-Cilk build all along; this script uses it, and the result is
# byte-identical to the binary upstream shipped.
#
# Backends (parallel_sdsl/include/sdsl/parallel.hpp selects between them):
#   openmp    tasks + taskloop, any C++17 compiler          (default)
#   opencilk  cilk_spawn/cilk_for via -fopencilk            (needs OpenCilk)
#   serial    no parallelism, plain sdsl                    (reference)
#
# Usage: ./build.sh [openmp|opencilk|serial]

set -euo pipefail

backend="${1:-openmp}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${root}/build/${backend}"
mkdir -p "${out}/obj"

case "${backend}" in
    openmp)   sdsl_inc="${root}/parallel_sdsl/include"; par_flags="-fopenmp -DOPENMP" ;;
    opencilk) sdsl_inc="${root}/parallel_sdsl/include"; par_flags="-fopencilk -DOPENCILK" ;;
    serial)   sdsl_inc="${root}/sdsl/include";          par_flags="" ;;
    *) echo "ERROR: unknown backend '${backend}' (openmp|opencilk|serial)" >&2; exit 1 ;;
esac

CXX="${CXX:-c++}"
CC="${CC:-cc}"
if [[ "${backend}" == "opencilk" ]]; then
    # OpenCilk ships its own clang; -fopencilk is not a GCC flag.
    CXX="${OPENCILK_CXX:-${root}/build/opencilk-toolchain/bin/clang++}"
    if [[ ! -x "${CXX}" ]]; then
        echo "ERROR: OpenCilk clang++ not found at ${CXX}." >&2
        echo "       Run: pixi run fetch-opencilk   (or set OPENCILK_CXX)" >&2
        exit 1
    fi
fi

echo "[1/4] libdivsufsort (vendored source)"
for f in "${root}"/external/libdivsufsort/lib/*.c; do
    "${CC}" -O3 -fPIC -w -DHAVE_CONFIG_H \
        -I"${root}/external/libdivsufsort/include" \
        -c "${f}" -o "${out}/obj/dss_$(basename "${f%.c}").o"
done
ar rcs "${out}/libdivsufsort.a" "${out}"/obj/dss_*.o

echo "[2/4] sdsl (${backend})"
for f in "$(dirname "${sdsl_inc}")"/lib/*.cpp; do
    "${CXX}" -std=c++17 -O3 -fPIC -w ${par_flags} \
        -I"${sdsl_inc}" -I"${root}/external/libdivsufsort/include" \
        -c "${f}" -o "${out}/obj/sdsl_$(basename "${f%.cpp}").o"
done
ar rcs "${out}/libsdsl.a" "${out}"/obj/sdsl_*.o

echo "[3/4] cpp_indexing"
"${CXX}" -std=c++17 -O3 -w ${par_flags} \
    -I"${sdsl_inc}" -I"${root}/external/libdivsufsort/include" \
    "${root}/src/indexing.cpp" -o "${out}/cpp_indexing" \
    "${out}/libsdsl.a" "${out}/libdivsufsort.a"

echo "[4/4] query engine (pybind11)"
# The engine uses the non-parallel sdsl headers, so it must link the matching
# archive -- mixing them with parallel_sdsl's would be an ODR violation.
# Built once and reused; it does not depend on the chosen backend.
eng="${root}/build/engine-sdsl"
if [[ ! -f "${eng}/libsdsl.a" ]]; then
    mkdir -p "${eng}/obj"
    for f in "${root}"/sdsl/lib/*.cpp; do
        "${CXX}" -std=c++17 -O3 -fPIC -w \
            -I"${root}/sdsl/include" -I"${root}/external/libdivsufsort/include" \
            -c "${f}" -o "${eng}/obj/$(basename "${f%.cpp}").o"
    done
    ar rcs "${eng}/libsdsl.a" "${eng}"/obj/*.o
fi

ext_suffix="$(python3-config --extension-suffix)"
"${CXX}" -std=c++17 -O3 -shared -fPIC -w \
    $(python3 -m pybind11 --includes) \
    "${root}/engine/src/cpp_engine.cpp" \
    -o "${root}/engine/src/cpp_engine${ext_suffix}" \
    -I"${root}/sdsl/include" -I"${root}/external/libdivsufsort/include" \
    "${eng}/libsdsl.a" "${out}/libdivsufsort.a" -pthread

chmod +x "${root}/src/rust_indexing"
install -m 0755 "${out}/cpp_indexing" "${root}/src/cpp_indexing"

echo
echo "Built ${backend}: src/cpp_indexing + engine/src/cpp_engine${ext_suffix}"
objdump -p "${root}/src/cpp_indexing" | awk '/NEEDED/{printf "  %s\n", $2}'
