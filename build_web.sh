#!/usr/bin/env bash
#
# build_web.sh — End-to-end automation of the LibGodot C# Web export pipeline.
#
# Automates every step from README.md "How to build":
#   1. Update the Godot fork submodule
#   2. Install the dotnet `wasm-tools` workload
#   3. Compile the Godot editor (mono enabled)
#   4. Generate the mono glue
#   5. Build + push the Godot.NET.Sdk assemblies to the local NuGet feed
#   6. Install + activate Emscripten 3.1.56 (via emsdk)
#   7. Build the web release templates (multithreaded + singlethreaded)
#   8. Point the export presets at the freshly built templates
#   9. Run the headless export for both presets (mt + st)
#
# Designed for bash. Recommended environment: WSL / native Linux. Also works on
# macOS and Windows Git Bash (binary names are detected automatically).
#
# Usage:
#   ./build_web.sh [options]
#
# Options:
#   --jobs N            Parallel build jobs (default: number of CPUs)
#   --skip-submodule    Skip `git submodule update --init godot`
#   --skip-workload     Skip `dotnet workload install wasm-tools`
#   --skip-editor       Skip compiling the editor (reuse existing bin/godot*)
#   --skip-glue         Skip generating mono glue
#   --skip-assemblies   Skip building/pushing Godot.NET.Sdk nupkgs
#   --skip-emscripten   Skip emsdk install/activate (assume emcc 3.1.56 active)
#   --skip-templates    Skip building the web templates
#   --skip-export       Skip the final headless export
#   --only-export       Shortcut: only rewrite presets + export (skips 1-7)
#   --no-auto-install   Verify prerequisites but do not auto-install them
#   -h, --help          Show this help text
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration                                                               #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$SCRIPT_DIR"
GODOT_DIR="$REPO_ROOT/godot"
# The C# project to export. This repo lives as a submodule INSIDE the GSG
# project, so the project to export is the parent directory. Override with the
# CSHARP_PROJECT env var (e.g. point it at the bundled demo for self-tests:
#   CSHARP_PROJECT="$REPO_ROOT/csharp_project" ./build_web.sh).
CSHARP_PROJECT="${CSHARP_PROJECT:-$REPO_ROOT/..}"
# Normalize away any '/../' so logs and template paths are clean absolute paths.
CSHARP_PROJECT="$(cd "$CSHARP_PROJECT" 2>/dev/null && pwd || echo "$CSHARP_PROJECT")"
DEMO_PROJECT="$REPO_ROOT/csharp_project"
NUGET_LOCAL="$REPO_ROOT/.nuget_local"
EMSDK_DIR="$REPO_ROOT/emsdk"
EMSDK_VERSION="3.1.56"

# .NET SDK channel to install when not already present.
# Must be >= the TargetFramework used by csharp_project (currently net10.0).
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
# Clang 20+ has a known optimizer crash on Godot's variant code; pin to 17.
# Override via CLANG_VERSION env var (e.g. CLANG_VERSION=18 ./build_web.sh).
CLANG_VERSION="${CLANG_VERSION:-17}"

# scons flags. The editor flags mirror the repo's build_editor.sh; override via
# the EDITOR_SCONS_FLAGS / TEMPLATE_SCONS_FLAGS environment variables.
EDITOR_SCONS_FLAGS_DEFAULT="target=editor production=yes module_mono_enabled=yes use_llvm=yes linker=lld accesskit=no"
TEMPLATE_SCONS_FLAGS_DEFAULT="target=template_release platform=web library_type=static_library module_mono_enabled=yes lto=none disable_crash_handler=yes"
EDITOR_SCONS_FLAGS="${EDITOR_SCONS_FLAGS:-$EDITOR_SCONS_FLAGS_DEFAULT}"
TEMPLATE_SCONS_FLAGS="${TEMPLATE_SCONS_FLAGS:-$TEMPLATE_SCONS_FLAGS_DEFAULT}"

JOBS=""
AUTO_INSTALL=1
SKIP_SUBMODULE=0
SKIP_WORKLOAD=0
SKIP_EDITOR=0
SKIP_GLUE=0
SKIP_ASSEMBLIES=0
SKIP_EMSCRIPTEN=0
SKIP_TEMPLATES=0
SKIP_EXPORT=0

# --------------------------------------------------------------------------- #
# Logging helpers                                                             #
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

# --------------------------------------------------------------------------- #
# Argument parsing                                                            #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jobs)            JOBS="$2"; shift 2 ;;
        --skip-submodule)  SKIP_SUBMODULE=1; shift ;;
        --skip-workload)   SKIP_WORKLOAD=1; shift ;;
        --skip-editor)     SKIP_EDITOR=1; shift ;;
        --skip-glue)       SKIP_GLUE=1; shift ;;
        --skip-assemblies) SKIP_ASSEMBLIES=1; shift ;;
        --skip-emscripten) SKIP_EMSCRIPTEN=1; shift ;;
        --skip-templates)  SKIP_TEMPLATES=1; shift ;;
        --skip-export)     SKIP_EXPORT=1; shift ;;
        --no-auto-install) AUTO_INSTALL=0; shift ;;
        --only-export)
            SKIP_SUBMODULE=1; SKIP_EDITOR=1; SKIP_GLUE=1
            SKIP_ASSEMBLIES=1; SKIP_EMSCRIPTEN=1; SKIP_TEMPLATES=1; shift ;;
            # Note: SKIP_WORKLOAD is intentionally NOT set — wasm-tools must be
            # installed for whatever .NET SDK is active (versions are per-SDK).
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

# --------------------------------------------------------------------------- #
# Platform detection                                                          #
# --------------------------------------------------------------------------- #
detect_platform() {
    case "$(uname -s)" in
        Linux*)   GODOT_PLATFORM="linuxbsd" ;;
        Darwin*)  GODOT_PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) GODOT_PLATFORM="windows" ;;
        *)        GODOT_PLATFORM="linuxbsd"; warn "Unknown OS, assuming linuxbsd" ;;
    esac
    if [[ -z "$JOBS" ]]; then
        if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"
        elif command -v sysctl >/dev/null 2>&1; then JOBS="$(sysctl -n hw.ncpu)"
        else JOBS=4; fi
    fi
    log "Platform: ${GODOT_PLATFORM} | Parallel jobs: ${JOBS}"
}

# Locate the freshly built mono editor binary (name varies by platform/flags).
find_editor_binary() {
    local bin
    # Only the native Linux binary. A Windows .exe (built by
    # build_windows_editor.sh into the same bin/ dir) would be executed via WSL
    # binfmt interop and resolve template paths against the Windows APPDATA,
    # causing "export template not found" errors. Exclude .exe explicitly.
    bin="$(find "$GODOT_DIR/bin" -maxdepth 1 -type f \
        -name 'godot.linuxbsd*editor*mono*' \
        ! -name '*.exe' ! -name '*.zip' 2>/dev/null \
        | sort | tail -n1 || true)"
    [[ -n "$bin" ]] || return 1
    echo "$bin"
}

# --------------------------------------------------------------------------- #
# Prerequisite verification / auto-install                                    #
# --------------------------------------------------------------------------- #
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Resolve a privilege-escalation prefix for system package installs.
SUDO=""
resolve_sudo() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
    elif need_cmd sudo; then
        SUDO="sudo"
    else
        SUDO=""
        warn "Not root and 'sudo' not found — system package installs may fail."
    fi
}

# Detect the host package manager (sets PKG_MGR).
PKG_MGR=""
detect_pkg_mgr() {
    if   need_cmd apt-get; then PKG_MGR="apt"
    elif need_cmd dnf;     then PKG_MGR="dnf"
    elif need_cmd yum;     then PKG_MGR="yum"
    elif need_cmd pacman;  then PKG_MGR="pacman"
    elif need_cmd zypper;  then PKG_MGR="zypper"
    elif need_cmd brew;    then PKG_MGR="brew"
    else PKG_MGR=""; fi
    [[ -n "$PKG_MGR" ]] && log "Package manager: $PKG_MGR" \
        || warn "No supported package manager found (apt/dnf/yum/pacman/zypper/brew)."
}

# Install one or more native packages via the detected package manager.
APT_UPDATED=0
pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case "$PKG_MGR" in
        apt)
            if [[ "$APT_UPDATED" -eq 0 ]]; then $SUDO apt-get update -y; APT_UPDATED=1; fi
            $SUDO apt-get install -y "$@" ;;
        dnf)    $SUDO dnf install -y "$@" ;;
        yum)    $SUDO yum install -y "$@" ;;
        pacman) $SUDO pacman -S --needed --noconfirm "$@" ;;
        zypper) $SUDO zypper install -y "$@" ;;
        brew)   brew install "$@" ;;
        *)      return 1 ;;
    esac
}

# Ensure a command exists, auto-installing the named package when allowed.
ensure_cmd() {
    local cmd="$1" pkg="$2"
    need_cmd "$cmd" && return 0
    if [[ "$AUTO_INSTALL" -eq 1 ]]; then
        log "$cmd not found — installing ($pkg)"
        pkg_install "$pkg" || die "Failed to auto-install '$cmd'. Install it manually and re-run."
    else
        die "$cmd is required but not found (auto-install disabled)."
    fi
    need_cmd "$cmd" || die "'$cmd' still not found after install attempt."
}

# Install the .NET SDK into ~/.dotnet via Microsoft's official script and
# persist it on PATH for future shells.
install_dotnet() {
    # libicu is a hard .NET runtime dependency; install it first so dotnet
    # doesn't abort with "Couldn't find a valid ICU package" immediately.
    if [[ "$AUTO_INSTALL" -eq 1 ]] && [[ -n "$PKG_MGR" ]]; then
        if ! ldconfig -p 2>/dev/null | grep -q libicuuc; then
            log "libicu not found — installing (required by .NET runtime)"
            case "$PKG_MGR" in
                apt)    pkg_install libicu-dev ;;
                dnf|yum) pkg_install libicu ;;
                pacman) pkg_install icu ;;
                zypper) pkg_install libicu-devel ;;
                brew)   brew install icu4c ;;
            esac
        fi
    fi
    log "Installing .NET SDK (channel ${DOTNET_CHANNEL}) into \$HOME/.dotnet"
    local script; script="$(mktemp)"
    if need_cmd curl; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
    elif need_cmd wget; then
        wget -qO "$script" https://dot.net/v1/dotnet-install.sh
    else
        ensure_cmd curl curl
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$script"
    fi
    bash "$script" --channel "$DOTNET_CHANNEL" --install-dir "$HOME/.dotnet" \
        || die "dotnet-install.sh failed."
    rm -f "$script"
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
    if [[ -w "$HOME/.bashrc" || ! -e "$HOME/.bashrc" ]] \
       && ! grep -q 'DOTNET_ROOT=.*/.dotnet' "$HOME/.bashrc" 2>/dev/null; then
        {
            echo ''
            echo '# Added by build_web.sh'
            echo 'export DOTNET_ROOT="$HOME/.dotnet"'
            echo 'export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"'
        } >> "$HOME/.bashrc"
        ok "Persisted .NET on PATH in ~/.bashrc"
    fi
}

# Install the C/C++ toolchain + Godot's Linux build dependencies.
install_build_deps() {
    case "$PKG_MGR" in
        apt)
            pkg_install build-essential \
                clang-${CLANG_VERSION} clang++-${CLANG_VERSION} \
                lld-${CLANG_VERSION} llvm-${CLANG_VERSION} pkg-config \
                libx11-dev libxcursor-dev libxinerama-dev libxi-dev libxrandr-dev \
                libgl1-mesa-dev libglu1-mesa-dev libasound2-dev libpulse-dev \
                libudev-dev libwayland-dev ;;
        dnf|yum)
            pkg_install gcc-c++ clang lld pkgconf-pkg-config \
                libX11-devel libXcursor-devel libXinerama-devel libXi-devel \
                libXrandr-devel mesa-libGL-devel mesa-libGLU-devel \
                alsa-lib-devel pulseaudio-libs-devel systemd-devel wayland-devel ;;
        pacman)
            pkg_install base-devel clang lld libx11 libxcursor libxinerama \
                libxi libxrandr mesa glu alsa-lib libpulse wayland ;;
        zypper)
            pkg_install -t pattern devel_C_C++ \
                || pkg_install gcc-c++ clang lld ;;
        *)
            warn "Unknown package manager — install a C/C++ toolchain (clang/lld) and"
            warn "Godot's Linux build libraries manually if the editor build fails." ;;
    esac
}

ensure_prereqs() {
    stage "Checking prerequisites"
    resolve_sudo
    detect_pkg_mgr

    # Core CLI tools.
    ensure_cmd git git
    if ! need_cmd python3 && ! need_cmd python; then
        ensure_cmd python3 python3
    fi
    PYTHON="$(command -v python3 || command -v python)"

    # pip (needed for scons).
    if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then
        if [[ "$AUTO_INSTALL" -eq 1 ]]; then
            case "$PKG_MGR" in
                apt)        pkg_install python3-pip python3-venv ;;
                dnf|yum)    pkg_install python3-pip ;;
                pacman)     pkg_install python-pip ;;
                zypper)     pkg_install python3-pip ;;
                *)          warn "pip missing and cannot auto-install for $PKG_MGR." ;;
            esac
        fi
    fi

    # .NET SDK.
    if ! need_cmd dotnet; then
        if [[ "$AUTO_INSTALL" -eq 1 ]]; then
            install_dotnet
        else
            die "dotnet SDK is required but not found (auto-install disabled)."
        fi
    else
        # dotnet is present but libicu may still be missing (causes an abort at
        # runtime before any workload runs).
        if [[ "$AUTO_INSTALL" -eq 1 ]] && [[ -n "$PKG_MGR" ]] \
           && ! ldconfig -p 2>/dev/null | grep -q libicuuc; then
            log "libicu not found — installing (required by .NET runtime)"
            case "$PKG_MGR" in
                apt)     pkg_install libicu-dev ;;
                dnf|yum) pkg_install libicu ;;
                pacman)  pkg_install icu ;;
                zypper)  pkg_install libicu-devel ;;
                brew)    brew install icu4c ;;
            esac
        fi
    fi
    need_cmd dotnet || die "dotnet still unavailable after install attempt."

    # C/C++ toolchain + Godot build libs (only needed for Linux source builds).
    if [[ "$GODOT_PLATFORM" == "linuxbsd" && "$AUTO_INSTALL" -eq 1 ]]; then
        if ! need_cmd clang && ! need_cmd cc && ! need_cmd gcc; then
            install_build_deps
        else
            # Compiler already present but clang++, pkg-config, or dev libs may
            # still be missing (e.g. partial system install). Ensure individually.
            need_cmd "clang++-${CLANG_VERSION}" || pkg_install "clang-${CLANG_VERSION}"
            need_cmd pkg-config                 || ensure_cmd pkg-config pkg-config
            need_cmd "lld-${CLANG_VERSION}"     || pkg_install "lld-${CLANG_VERSION}"
            need_cmd "llvm-ar-${CLANG_VERSION}" || pkg_install "llvm-${CLANG_VERSION}"
        fi
    fi

    # scons (prefer pip; fall back to the system package).
    if ! need_cmd scons; then
        if [[ "$AUTO_INSTALL" -eq 1 ]]; then
            log "scons not found — installing via pip"
            "$PYTHON" -m pip install --user scons \
                || pkg_install scons \
                || die "Failed to install scons."
        else
            die "scons not found (re-run with auto-install, or 'pip install scons')."
        fi
    fi
    # pip --user installs land in ~/.local/bin; make sure it's reachable.
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac

    ok "Prerequisites satisfied (git, dotnet, python, scons)"
}

# --------------------------------------------------------------------------- #
# Stage 1: Godot submodule                                                    #
# --------------------------------------------------------------------------- #
stage_submodule() {
    [[ "$SKIP_SUBMODULE" -eq 1 ]] && { warn "Skipping submodule update"; return; }
    stage "1/9 Updating Godot fork submodule"
    ( cd "$REPO_ROOT" && git submodule update --init godot )
    [[ -f "$GODOT_DIR/SConstruct" ]] || die "godot submodule did not populate (SConstruct missing)."
    ok "godot submodule ready"
}

# --------------------------------------------------------------------------- #
# Stage 2: wasm-tools workload                                                #
# --------------------------------------------------------------------------- #
stage_workload() {
    [[ "$SKIP_WORKLOAD" -eq 1 ]] && { warn "Skipping wasm-tools workload"; return; }
    stage "2/9 Installing dotnet wasm-tools workload"
    if dotnet workload list 2>/dev/null | grep -qi 'wasm-tools'; then
        ok "wasm-tools workload already installed"
    elif [[ "$AUTO_INSTALL" -eq 1 ]]; then
        dotnet workload install wasm-tools
        ok "wasm-tools installed"
    else
        die "wasm-tools workload missing (auto-install disabled)."
    fi
}

# --------------------------------------------------------------------------- #
# Stage 3: compile editor                                                     #
# --------------------------------------------------------------------------- #
stage_editor() {
    [[ "$SKIP_EDITOR" -eq 1 ]] && { warn "Skipping editor compile"; return; }
    stage "3/9 Compiling Godot editor (mono)"
    log "scons $EDITOR_SCONS_FLAGS platform=$GODOT_PLATFORM -j$JOBS"
    local llvm_bin="/usr/lib/llvm-${CLANG_VERSION}/bin"
    ( cd "$GODOT_DIR" && \
        PATH="${llvm_bin}:$PATH" \
        CC="clang-${CLANG_VERSION}" CXX="clang++-${CLANG_VERSION}" AR="llvm-ar-${CLANG_VERSION}" \
        scons platform="$GODOT_PLATFORM" $EDITOR_SCONS_FLAGS -j"$JOBS" )
    local bin; bin="$(find_editor_binary)" || die "Editor binary not found after build."
    ok "Editor built: ${bin#$REPO_ROOT/}"
}

# --------------------------------------------------------------------------- #
# Stage 4: generate mono glue                                                 #
# --------------------------------------------------------------------------- #
stage_glue() {
    [[ "$SKIP_GLUE" -eq 1 ]] && { warn "Skipping mono glue"; return; }
    stage "4/9 Generating mono glue"
    local bin; bin="$(find_editor_binary)" \
        || die "No editor binary in godot/bin — build the editor first (or drop --skip-editor)."
    ( cd "$GODOT_DIR" && "$bin" --headless --generate-mono-glue ./modules/mono/glue )
    ok "Mono glue generated"
}

# --------------------------------------------------------------------------- #
# Stage 5: build + push assemblies                                            #
# --------------------------------------------------------------------------- #
# The Godot SDK packages always carry the SAME version string (e.g. 4.7.0-beta).
# NuGet keys its global package cache by id+version, so once 4.7.0-beta has been
# extracted it will NOT re-extract a rebuilt package with the same version — a
# later export then silently builds against a STALE cached SDK. This caused the
# "Failed to build project" export failure on the first run after rebuilding.
# Purge the cached copies so the next restore re-extracts the freshly-pushed feed.
purge_godot_nuget_cache() {
    local pkg_root="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
    local id
    for id in godot.net.sdk godotsharp godotsharpeditor godot.sourcegenerators; do
        if [[ -d "$pkg_root/$id" ]]; then
            rm -rf "$pkg_root/$id"
            ok "Purged stale NuGet cache: $id"
        fi
    done
}

stage_assemblies() {
    [[ "$SKIP_ASSEMBLIES" -eq 1 ]] && { warn "Skipping assemblies"; return; }
    stage "5/9 Building Godot.NET.Sdk assemblies → local NuGet feed"
    mkdir -p "$NUGET_LOCAL"
    ( cd "$GODOT_DIR" && "$PYTHON" ./modules/mono/build_scripts/build_assemblies.py \
        --godot-output-dir ./bin --push-nupkgs-local "$NUGET_LOCAL" )
    purge_godot_nuget_cache
    ok "Assemblies pushed to ${NUGET_LOCAL#$REPO_ROOT/}"
}

# --------------------------------------------------------------------------- #
# Stage 6: emscripten 3.1.56                                                  #
# --------------------------------------------------------------------------- #
stage_emscripten() {
    [[ "$SKIP_EMSCRIPTEN" -eq 1 ]] && { warn "Skipping emscripten setup"; return; }
    stage "6/9 Setting up Emscripten ${EMSDK_VERSION}"

    if need_cmd emcc && emcc --version 2>/dev/null | grep -q "$EMSDK_VERSION"; then
        ok "Active emcc is already ${EMSDK_VERSION}"
        return
    fi

    if [[ "$AUTO_INSTALL" -ne 1 ]]; then
        die "Emscripten ${EMSDK_VERSION} not active (auto-install disabled)."
    fi

    if [[ ! -d "$EMSDK_DIR" ]]; then
        log "Cloning emsdk → ${EMSDK_DIR#$REPO_ROOT/}"
        git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
    fi
    ( cd "$EMSDK_DIR" && ./emsdk install "$EMSDK_VERSION" && ./emsdk activate "$EMSDK_VERSION" )
    # shellcheck disable=SC1091
    source "$EMSDK_DIR/emsdk_env.sh"
    emcc --version | head -n1
    ok "Emscripten ${EMSDK_VERSION} activated for this session"
}

# Make sure emcc is on PATH for the template builds even if stage was skipped.
ensure_emcc_active() {
    if ! need_cmd emcc && [[ -f "$EMSDK_DIR/emsdk_env.sh" ]]; then
        # shellcheck disable=SC1091
        source "$EMSDK_DIR/emsdk_env.sh"
    fi
    need_cmd emcc || die "emcc not on PATH — emscripten is required to build web templates."
}

# --------------------------------------------------------------------------- #
# Stage 7: build web templates                                                #
# --------------------------------------------------------------------------- #
stage_templates() {
    [[ "$SKIP_TEMPLATES" -eq 1 ]] && { warn "Skipping web templates"; return; }
    stage "7/9 Building web release templates (mt + st)"
    ensure_emcc_active

    local llvm_bin="/usr/lib/llvm-${CLANG_VERSION}/bin"
    log "Multithreaded template (proxy_to_pthread=yes)"
    ( cd "$GODOT_DIR" && \
        PATH="${llvm_bin}:$PATH" \
        CC="clang-${CLANG_VERSION}" CXX="clang++-${CLANG_VERSION}" AR="llvm-ar-${CLANG_VERSION}" \
        scons $TEMPLATE_SCONS_FLAGS proxy_to_pthread=yes -j"$JOBS" )

    log "Singlethreaded template (threads=no)"
    ( cd "$GODOT_DIR" && \
        PATH="${llvm_bin}:$PATH" \
        CC="clang-${CLANG_VERSION}" CXX="clang++-${CLANG_VERSION}" AR="llvm-ar-${CLANG_VERSION}" \
        scons $TEMPLATE_SCONS_FLAGS threads=no -j"$JOBS" )

    [[ -f "$GODOT_DIR/bin/godot.web.template_release.wasm32.mono.zip" ]] \
        || die "Multithreaded template zip not produced."
    [[ -f "$GODOT_DIR/bin/godot.web.template_release.wasm32.nothreads.mono.zip" ]] \
        || die "Singlethreaded template zip not produced."
    ok "Both web templates built in godot/bin"
}

# --------------------------------------------------------------------------- #
# Stage 8 + 9: rewrite presets and export                                     #
# --------------------------------------------------------------------------- #
MT_ZIP="$GODOT_DIR/bin/godot.web.template_release.wasm32.mono.zip"
ST_ZIP="$GODOT_DIR/bin/godot.web.template_release.wasm32.nothreads.mono.zip"

rewrite_presets() {
    stage "8/9 Pointing export presets at the built templates"
    local cfg="$CSHARP_PROJECT/export_presets.cfg"
    [[ -f "$cfg" ]] || die "export_presets.cfg not found in csharp_project."
    [[ -f "$MT_ZIP" ]] || die "Multithreaded template missing: $MT_ZIP"

    if [[ "$CSHARP_PROJECT" == "$DEMO_PROJECT" ]]; then
        # --- Demo: preset.0 = "Web" (mt), preset.1 = "Web (copy)" (st) ---
        [[ -f "$ST_ZIP" ]] || die "Singlethreaded template missing: $ST_ZIP"
        cp -f "$cfg" "$cfg.bak"
        "$PYTHON" - "$cfg" "$MT_ZIP" "$ST_ZIP" <<'PY'
import sys
cfg, mt, st = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg, "r", encoding="utf-8") as f:
    lines = f.readlines()

current = None
zips = {"[preset.0.options]": mt, "[preset.1.options]": st}
out = []
for line in lines:
    s = line.strip()
    if s in ("[preset.0.options]", "[preset.1.options]"):
        current = zips[s]
    elif s.startswith("[") and s.endswith("]"):
        current = None
    if current and (line.startswith("custom_template/release=")
                    or line.startswith("custom_template/debug=")):
        key = line.split("=", 1)[0]
        out.append(f'{key}="{current}"\n')
        continue
    out.append(line)

with open(cfg, "w", encoding="utf-8") as f:
    f.writelines(out)
print(f"  mt -> {mt}")
print(f"  st -> {st}")
PY
        ok "export_presets.cfg updated (backup at export_presets.cfg.bak)"
        return
    fi

    # --- External project (GSG): copy the mt template into the project's
    #     .web_templates/ and rewrite ONLY the "Web" preset's custom_template
    #     lines. The project may have other presets (e.g. Windows Desktop) that
    #     must be left untouched, so we locate the Web preset by name.
    local tmpl_dir="$CSHARP_PROJECT/.web_templates"
    mkdir -p "$tmpl_dir"
    cp -f "$MT_ZIP" "$tmpl_dir/"
    local tmpl="$tmpl_dir/$(basename "$MT_ZIP")"

    cp -f "$cfg" "$cfg.bak"
    "$PYTHON" - "$cfg" "$tmpl" <<'PY'
import sys
cfg, tmpl = sys.argv[1], sys.argv[2]
with open(cfg, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Map each [preset.N] header to its name so we know which .options block is Web.
import re
name_by_idx, idx = {}, None
for line in lines:
    m = re.match(r"\[preset\.(\d+)\]", line.strip())
    if m:
        idx = m.group(1); continue
    if idx is not None and line.startswith("name="):
        name_by_idx[idx] = line.split("=", 1)[1].strip().strip('"')
        idx = None

in_web = False
out = []
for line in lines:
    s = line.strip()
    m = re.match(r"\[preset\.(\d+)\.options\]", s)
    if m:
        in_web = (name_by_idx.get(m.group(1)) == "Web")
    elif s.startswith("[") and s.endswith("]"):
        in_web = False
    if in_web and (line.startswith("custom_template/release=")
                   or line.startswith("custom_template/debug=")):
        key = line.split("=", 1)[0]
        out.append(f'{key}="{tmpl}"\n')
        continue
    out.append(line)

with open(cfg, "w", encoding="utf-8") as f:
    f.writelines(out)
print(f"  Web custom_template -> {tmpl}")
PY
    ok "export_presets.cfg updated (backup at export_presets.cfg.bak)"
}

stage_export() {
    [[ "$SKIP_EXPORT" -eq 1 ]] && { warn "Skipping export"; return; }
    rewrite_presets
    stage "9/9 Headless export (mt + st)"
    local bin; bin="$(find_editor_binary)" \
        || die "No editor binary to run the export with."

    # Ensure NuGet restore can find the locally built Godot.NET.Sdk packages.
    # Fail hard here — a restore failure means the export will also fail, and
    # the error message is clearer at this point than inside Godot's headless run.
    # Use --force so a rebuilt-but-same-version SDK is re-resolved instead of a
    # cached no-op restore (see purge_godot_nuget_cache in stage 5).
    log "Running dotnet restore --force in csharp_project"
    ( cd "$CSHARP_PROJECT" && dotnet restore --force ) \
        || die "dotnet restore failed. Common causes:\n  - Wrong .NET SDK version (project targets net$(grep -oP '(?<=net)\S+' "$CSHARP_PROJECT"/*.csproj 2>/dev/null | head -1))\n  - wasm-tools workload not installed for this SDK (run: dotnet workload install wasm-tools)\n  - Local NuGet feed missing — rebuild assemblies (drop --skip-assemblies)"

    if [[ "$CSHARP_PROJECT" == "$DEMO_PROJECT" ]]; then
        mkdir -p "$CSHARP_PROJECT/export/mt" "$CSHARP_PROJECT/export/st"

        log "Exporting multithreaded preset → export/mt/index.html"
        ( cd "$CSHARP_PROJECT" && "$bin" --headless --path . \
            --export-release "Web" export/mt/index.html )

        # The C# mono temp cache is incompatible between mt and st builds.
        # Delete it so the singlethreaded export gets a clean compile.
        log "Clearing .godot/mono/temp between mt and st exports"
        rm -rf "$CSHARP_PROJECT/.godot/mono/temp"

        log "Exporting singlethreaded preset → export/st/index.html"
        ( cd "$CSHARP_PROJECT" && "$bin" --headless --path . \
            --export-release "Web (copy)" export/st/index.html )

        ok "Export complete:"
        ok "  ${CSHARP_PROJECT#$REPO_ROOT/}/export/mt/index.html"
        ok "  ${CSHARP_PROJECT#$REPO_ROOT/}/export/st/index.html"
        return
    fi

    # --- External project (GSG): single "Web" preset → exports/web/index.html ---
    mkdir -p "$CSHARP_PROJECT/exports/web"

    log "Exporting Web preset → exports/web/index.html"
    ( cd "$CSHARP_PROJECT" && "$bin" --headless --path . \
        --export-release "Web" exports/web/index.html )

    ok "Export complete:"
    ok "  ${CSHARP_PROJECT}/exports/web/index.html"
}

# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #
main() {
    detect_platform
    ensure_prereqs
    stage_submodule
    stage_workload
    stage_editor
    stage_glue
    stage_assemblies
    stage_emscripten
    stage_templates
    stage_export
    echo
    ok "All requested stages finished."
    echo -e "${C_YELLOW}Note:${C_RESET} the web build must be served with COOP/COEP cross-origin"
    echo "isolation headers. Serve the export locally with the bundled helper:"
    echo "  python gsg/exports/serve_web.py   # http://localhost:8060"
}

main "$@"
