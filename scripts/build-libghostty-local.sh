#!/bin/bash
set -euo pipefail

# Build libghostty using local Ghostty repository
# Usage: ./scripts/build-libghostty-local.sh [arch]
#   - arch: target architecture (aarch64|x86_64, default: build both)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/ghostty/Vendor"
GHOSTTY_DIR="/Volumes/External/GitHub/ghostty"

REQUESTED_ARCH="${1:-}"

echo "Building libghostty from local repo..."
echo "Ghostty dir: ${GHOSTTY_DIR}"

# Check if Ghostty directory exists
if [ ! -d "${GHOSTTY_DIR}" ]; then
    echo "Error: Ghostty directory not found at ${GHOSTTY_DIR}" >&2
    exit 1
fi

# Get current commit
cd "${GHOSTTY_DIR}"
REF="$(git rev-parse HEAD)"
echo "Using Ghostty commit: ${REF}"

# Setup temp dir for patches
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# Copy Ghostty to temp dir (to avoid modifying original)
echo "Copying Ghostty to temp build directory..."
cp -R "${GHOSTTY_DIR}" "${WORKDIR}/ghostty"
cd "${WORKDIR}/ghostty"

# Patch build.zig to install libs on macOS
perl -0pi -e 's/if \(!config\.target\.result\.os\.tag\.isDarwin\(\)\) \{/if (true) {/' "${WORKDIR}/ghostty/build.zig"

# Patch to link Metal frameworks
perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"

# Patch bundle ID to use CodMate's
sed -i '' 's/com\.mitchellh\.ghostty/ai.umate.codmate/g' "${WORKDIR}/ghostty/src/build_config.zig"

ZIG_FLAGS=(
    -Dapp-runtime=none
    -Demit-xcframework=false
    -Demit-macos-app=false
    -Demit-exe=false
    -Demit-docs=false
    -Demit-webdata=false
    -Demit-helpgen=false
    -Demit-terminfo=true
    -Demit-termcap=false
    -Demit-themes=false
    -Doptimize=ReleaseFast
    -Dstrip
)

build_arch() {
    local arch="$1"
    local outdir="${WORKDIR}/zig-out-${arch}"
    echo "Building for ${arch}..." >&2
    (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget="${arch}-macos" -p "${outdir}")
    if [ ! -f "${outdir}/lib/libghostty.a" ]; then
        echo "Error: build failed - ${outdir}/lib/libghostty.a not found" >&2
        exit 1
    fi
    
    # Copy architecture-specific library to Vendor/lib/{arch}/
    local arch_dir="${VENDOR_DIR}/lib/${arch}"
    mkdir -p "${arch_dir}"
    cp "${outdir}/lib/libghostty.a" "${arch_dir}/libghostty.a"
    
    # Strip debug symbols from the static library to reduce size
    # Note: This removes DWARF debug info but keeps symbol table for linking
    if command -v strip >/dev/null 2>&1; then
        # Use -S to strip only debug symbols, keeping symbol table for linking
        strip -S "${arch_dir}/libghostty.a" 2>/dev/null || true
        echo "Stripped debug symbols from ${arch} library"
    fi
    
    echo "Copied ${arch} library to ${arch_dir}/libghostty.a"
    echo "${outdir}/lib/libghostty.a"
}

# Determine which architectures to build
ARCHES=()
if [ -z "${REQUESTED_ARCH}" ]; then
    # Build both architectures
    ARCHES=(aarch64 x86_64)
elif [ "${REQUESTED_ARCH}" = "aarch64" ] || [ "${REQUESTED_ARCH}" = "arm64" ]; then
    ARCHES=(aarch64)
elif [ "${REQUESTED_ARCH}" = "x86_64" ]; then
    ARCHES=(x86_64)
else
    echo "Error: Invalid architecture '${REQUESTED_ARCH}'. Use 'aarch64' or 'x86_64'." >&2
    exit 1
fi

# Build each requested architecture
mkdir -p "${VENDOR_DIR}/lib" "${VENDOR_DIR}/include"
for arch in "${ARCHES[@]}"; do
    build_arch "${arch}"
done

# Copy headers (preserve module.modulemap which is custom)
if [ -d "${WORKDIR}/ghostty/include" ]; then
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/include/"
fi

# Record version
printf "%s\n" "${REF}" > "${VENDOR_DIR}/VERSION"

echo "Done: Built ${#ARCHES[@]} architecture(s)"
for arch in "${ARCHES[@]}"; do
    local arch_lib="${VENDOR_DIR}/lib/${arch}/libghostty.a"
    if [ -f "${arch_lib}" ]; then
        echo "  ${arch}: $(lipo -info "${arch_lib}")"
    fi
done
