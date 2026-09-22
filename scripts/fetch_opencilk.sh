#!/bin/bash
# Download the OpenCilk toolchain into build/opencilk-toolchain.
#
# OpenCilk is not published to any conda channel, so it cannot be an ordinary
# dependency. recipe/opencilk/ repackages this same release as a conda package;
# once that is pushed to a channel, replace this task with a dependency and
# delete the script. Until then the download is at least digest-verified.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
recipe="${root}/recipe/opencilk/recipe.yaml"

# The version and digest live in the recipe only, so a bump cannot be applied
# to one of the two and silently missed by the other.
VERSION="$(sed -n 's/^  version: "\(.*\)"$/\1/p' "${recipe}")"
RELEASE="$(sed -n 's/^  release: "\(.*\)"$/\1/p' "${recipe}")"
SHA256="$(sed -n 's/^  sha256: \(.*\)$/\1/p' "${recipe}")"
if [[ -z "${VERSION}" || -z "${RELEASE}" || -z "${SHA256}" ]]; then
    echo "ERROR: could not read version/release/sha256 from ${recipe}" >&2
    exit 1
fi
URL="https://github.com/OpenCilk/opencilk-project/releases/download/${RELEASE//\//%2F}/opencilk-${VERSION}-x86_64-linux-gnu-ubuntu-24.04.tar.gz"
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
