#!/bin/bash
# Download the OpenCilk toolchain into build/opencilk-toolchain.
#
# OpenCilk is not published to any conda channel, so it cannot be an ordinary
# dependency. recipe/opencilk/ repackages this same release as a conda package;
# once that is pushed to a channel, replace this task with a dependency and
# delete the script. Until then the download is at least digest-verified.

set -euo pipefail

VERSION="3.0.0"
URL="https://github.com/OpenCilk/opencilk-project/releases/download/opencilk%2Fv3.0/opencilk-${VERSION}-x86_64-linux-gnu-ubuntu-24.04.tar.gz"
SHA256="38e16208a0d086f72858c2024474a0a69c519830d3d3268a80e1ef50d6116838"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${root}/build/opencilk-toolchain"

if [[ -x "${dest}/bin/clang++" ]]; then
    echo "OpenCilk already present in build/opencilk-toolchain"
    exit 0
fi

echo "Downloading OpenCilk ${VERSION} (~1.4 GB) ..."
mkdir -p "${root}/build"
tarball="${root}/build/opencilk.tar.gz"
curl -fsSL -o "${tarball}" "${URL}"
echo "${SHA256}  ${tarball}" | sha256sum -c -
mkdir -p "${dest}"
tar -xzf "${tarball}" -C "${dest}" --strip-components=1
rm -f "${tarball}"
echo "Installed ${dest} ($("${dest}/bin/clang++" --version | head -1))"
