#!/usr/bin/env bash
#
# build_windows_editor.sh — Build a native Windows editor (.exe) from the fork.
#
# The Linux editor + assemblies must already be built (run build_web.sh stages
# 1–5 first, or the full build_web.sh). This script only compiles the Windows
# editor binary — glue generation and assembly building are skipped because
# the managed assemblies produced by the Linux build are platform-agnostic and
# can be reused.
#
# Cross-compilation is done from WSL/Linux using mingw-w64.
#
# Usage:
#   ./build_windows_editor.sh [--jobs N] [--no-auto-install]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$SCRIPT_DIR"
GODOT_DIR="$REPO_ROOT/godot"

# Must match the version used for the Linux editor build.
CLANG_VERSION="${CLANG_VERSION:-17}"

# scons flags for the Windows editor. production=yes enables optimisations but
# skips lto/llvm (mingw handles that differently). Override via env var.
#
# d3d12=no / winrt=no: the Direct3D 12 driver needs a separately-installed SDK
# (misc/scripts/install_d3d12_sdk_windows.py) and WinRT needs its own deps —
# both abort/warn the build if missing. GSG renders with Vulkan (Forward+) by
# default, so these drivers are not needed; disabling them keeps the build
# dependency-free. Re-enable by overriding WINDOWS_EDITOR_FLAGS if you ever need
# the D3D12 renderer (and run the install scripts first).
WINDOWS_EDITOR_FLAGS_DEFAULT="target=editor production=yes module_mono_enabled=yes accesskit=no d3d12=no winrt=no"
WINDOWS_EDITOR_FLAGS="${WINDOWS_EDITOR_FLAGS:-$WINDOWS_EDITOR_FLAGS_DEFAULT}"

JOBS=""
AUTO_INSTALL=1

# --------------------------------------------------------------------------- #
# Logging                                                                     #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
    C_RESET="\033[0m"; C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
log()   { echo -e "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}  ✓${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}  !${C_RESET} $*" >&2; }
die()   { echo -e "${C_RED}  ✗ $*${C_RESET}" >&2; exit 1; }
stage() { echo; echo -e "${C_BLUE}========== $* ==========${C_RESET}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Argument parsing                                                            #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)            JOBS="$2"; shift 2 ;;
        --no-auto-install) AUTO_INSTALL=0; shift ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

if [[ -z "$JOBS" ]]; then
    JOBS="$(nproc 2>/dev/null || echo 4)"
fi

# --------------------------------------------------------------------------- #
# Prerequisites                                                               #
# --------------------------------------------------------------------------- #
ensure_mingw() {
    stage "Checking mingw-w64"
    if ! need_cmd x86_64-w64-mingw32-gcc; then
        if [[ "$AUTO_INSTALL" -eq 1 ]]; then
            log "mingw-w64 not found — installing"
            sudo apt-get update -y
            sudo apt-get install -y mingw-w64
        else
            die "mingw-w64 not found (auto-install disabled). Install with: sudo apt-get install mingw-w64"
        fi
    fi
    ok "mingw-w64 present ($(x86_64-w64-mingw32-gcc --version | head -1))"
}

check_linux_editor() {
    stage "Checking Linux editor (prerequisite)"
    local bin
    bin="$(find "$GODOT_DIR/bin" -maxdepth 1 -type f \
        -name 'godot.linuxbsd*editor*mono*' ! -name '*.zip' 2>/dev/null \
        | sort | tail -n1 || true)"
    [[ -n "$bin" ]] \
        || die "Linux editor not found in godot/bin.\nRun build_web.sh (at least stages 1–5) first."
    ok "Linux editor present: ${bin#$REPO_ROOT/}"

    [[ -d "$REPO_ROOT/.nuget_local" ]] \
        || die ".nuget_local feed missing — assemblies not yet built.\nRun build_web.sh stages 1–5 first."
    ok ".nuget_local feed present"
}

# --------------------------------------------------------------------------- #
# Build                                                                       #
# --------------------------------------------------------------------------- #
build_windows_editor() {
    stage "Building Windows editor (mono, mingw cross-compile)"
    log "scons $WINDOWS_EDITOR_FLAGS platform=windows use_mingw=yes -j$JOBS"

    local llvm_bin="/usr/lib/llvm-${CLANG_VERSION}/bin"
    ( cd "$GODOT_DIR" && \
        PATH="${llvm_bin}:$PATH" \
        scons platform=windows $WINDOWS_EDITOR_FLAGS use_mingw=yes -j"$JOBS" )

    local exe
    exe="$(find "$GODOT_DIR/bin" -maxdepth 1 -type f \
        -name 'godot.windows*editor*mono*.exe' 2>/dev/null \
        | sort | tail -n1 || true)"
    [[ -n "$exe" ]] || die "Windows editor .exe not found after build."

    ok "Windows editor built: ${exe#$REPO_ROOT/}"

    # Print the Windows-accessible path so the user can find it in Explorer.
    local win_path
    win_path="$(wslpath -w "$exe" 2>/dev/null || echo "$exe")"
    echo
    log "Windows path: ${win_path}"
    log "You can now run this .exe directly on Windows."
    log ""
    log "To open your project:"
    log "  ${win_path} --path C:\\\\Repos\\\\Gamedev\\\\gsg --editor"
    log ""
    log "Note: The editor needs the local NuGet feed to restore C# packages."
    log "  nuget.config in your project must point at:"
    log "  $(wslpath -w "$REPO_ROOT/.nuget_local" 2>/dev/null || echo "$REPO_ROOT/.nuget_local")"
}

# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #
main() {
    ensure_mingw
    check_linux_editor
    build_windows_editor
    echo
    ok "Done. Run the .exe on Windows to edit your project natively."
}

main "$@"
