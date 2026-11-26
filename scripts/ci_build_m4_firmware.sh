#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -eo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
edk="$root/work/edk2-m4"
revision=fbe0805b2091393406952e84724188f8c1941837
mkdir -p "$edk" "$root/build/firmware"
cd "$edk"
if [[ ! -e .git ]]; then git init -q; fi
if ! git cat-file -e "$revision^{commit}" 2>/dev/null; then
    git fetch --depth=1 https://github.com/tianocore/edk2.git "$revision"
fi
git checkout --detach "$revision"
git submodule update --init --depth=1 --jobs 4 -- \
    BaseTools/Source/C/BrotliCompress/brotli MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
    CryptoPkg/Library/OpensslLib/openssl CryptoPkg/Library/MbedTlsLib/mbedtls \
    MdePkg/Library/BaseFdtLib/libfdt MdePkg/Library/MipiSysTLib/mipisyst \
    MdeModulePkg/Universal/RegularExpressionDxe/oniguruma SecurityPkg/DeviceSecurity/SpdmLib/libspdm
# Upstream stores this module with CRLF. Use the same line endings for the patch.
patch_file="$root/work/m4-ramfb-crlf.patch"
sed '/^[ +-]/ { /^---/b; /^+++/b; s/$/\r/; }' "$root/firmware/m4-ramfb.patch" > "$patch_file"
if ! git apply --reverse --check "$patch_file" 2>/dev/null; then git apply "$patch_file"; fi
export GCC5_AARCH64_PREFIX=aarch64-linux-gnu-
source edksetup.sh
make -C BaseTools -j4
build -a AARCH64 -t GCC5 -b RELEASE -p ArmVirtPkg/ArmVirtQemu.dsc -n 4 \
    -D TPM2_ENABLE=TRUE -D TPM2_CONFIG_ENABLE=TRUE -D CAVIUM_ERRATUM_27456=TRUE \
    -D FD_SIZE_IN_MB=3
cp Build/ArmVirtQemu-AARCH64/RELEASE_GCC5/FV/QEMU_EFI.fd "$root/build/firmware/m4-1600x1200.fd"
cat License.txt CryptoPkg/Library/OpensslLib/openssl/LICENSE.txt \
    CryptoPkg/Library/MbedTlsLib/mbedtls/LICENSE MdePkg/Library/BaseFdtLib/libfdt/BSD-2-Clause \
    MdeModulePkg/Library/BrotliCustomDecompressLib/brotli/LICENSE \
    MdeModulePkg/Universal/RegularExpressionDxe/oniguruma/COPYING > "$root/build/firmware/EDK2-License.txt"
