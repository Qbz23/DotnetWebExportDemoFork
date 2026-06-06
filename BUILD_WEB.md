# build_web.sh — Web Export for GSG

## Quick reference — day-to-day export

Run from **Windows PowerShell**. Requires the editor + templates to already exist
(see [Required pieces](#required-pieces) below).

1. **Close the Godot Windows editor** — on save it rewrites `gsg/export_presets.cfg`
   and wipes the Linux template paths.

2. **Re-export** (compiles C# + regenerates `gsg/exports/web/`):

   ```powershell
   wsl bash -c 'cd /mnt/c/Repos/Gamedev/gsg/DotnetWebExportDemoFork && ./build_web.sh --only-export'
   ```

3. **Test locally**:

   ```powershell
   python C:\Repos\Gamedev\gsg\exports\serve_web.py
   ```

   Open <http://localhost:8060/index.html>, then **click the canvas** (browser
   autoplay policy) — music + SFX should play.

4. **Package for itch.io** — zip the **contents** of `gsg/exports/web/` (so
   `index.html` is at the zip root) and upload. Enable **SharedArrayBuffer** in
   the itch embed settings. The threaded build launches in a new tab/window
   (itch cannot iframe SharedArrayBuffer content — see notes).

---

## Required pieces

Two sets of artifacts must exist before `--only-export` works. They are
**gitignored** — not in source control, must be built once from source, and only
need rebuilding when the Godot fork version changes.

| Piece                         | Files                                                                                                   | Built by                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------- |
| **Editor + NuGet assemblies** | `godot/bin/godot.linuxbsd.editor.x86_64.llvm.mono`<br>`godot/bin/GodotSharp/`<br>`.nuget_local/*.nupkg` | [[#Build Editor and assemblies]] |
| **Web export templates**      | `godot/bin/godot.web.template_release.wasm32.mono.zip`                                                  | [[#Build web templates]]         |

> **WSL is required** on Windows. Every other dependency (clang-17, .NET SDK,
> scons, Emscripten 3.1.56, etc.) is checked and installed automatically by the
> script on first run. You need `sudo` rights and a supported package manager
> (`apt`, `dnf`, `pacman`, `zypper`, or `brew`).

All commands below are run from WSL in `gsg/DotnetWebExportDemoFork/`.
Run `chmod +x build_web.sh` once after cloning.

---

## Build scenarios

### Full build from scratch

Nothing in `godot/bin/` or `.nuget_local/`. Builds the editor, assemblies,
templates, and exports the game end-to-end. **Expect 1–3 hours.**

```bash
cd /mnt/c/Repos/Gamedev/gsg/DotnetWebExportDemoFork
chmod +x build_web.sh
./build_web.sh
```

### Build: Editor and assemblies

Produces the Linux editor binary, `GodotSharp/` API assemblies, and the
`.nuget_local/` NuGet packages. Run this after updating the Godot fork version,
or if `godot/bin/` was wiped.

```bash
./build_web.sh --skip-emscripten --skip-templates --skip-export
```

### Build: Windows editor (day-to-day editing)

The Linux editor built above is headless-only — used for the export pipeline.
To **edit GSG natively on Windows** you need a Windows `.exe` editor built from
the *same fork* (a stock Godot 4.7-beta editor will not match the
`Godot.NET.Sdk/4.7.0-beta` API the project targets). This is a separate artifact
from everything in [[#Required pieces]] and is **not** needed for
web export.

It is cross-compiled from WSL with mingw-w64 and **reuses the Linux build's
`GodotSharp/` assemblies + `.nuget_local/` feed** (managed code is
platform-agnostic), so you must build the Linux editor + assemblies first
([[#Build Editor and assemblies|above]]). mingw-w64 is auto-installed if missing.

```bash
cd /mnt/c/Repos/Gamedev/gsg/DotnetWebExportDemoFork
chmod +x build_windows_editor.sh
./build_windows_editor.sh
```

Output: `godot/bin/godot.windows.editor.x86_64.mono.exe`. The script prints the
Windows path and the command to open the project. Run it directly from Windows:

```powershell
C:\Repos\Gamedev\gsg\DotnetWebExportDemoFork\godot\bin\godot.windows.editor.x86_64.mono.exe --path C:\Repos\Gamedev\gsg --editor
```

> The editor restores C# packages from the local NuGet feed, so `gsg/nuget.config`
> must point at `DotnetWebExportDemoFork/.nuget_local` (it already does). Rebuild
> this editor whenever you update the Godot fork version.

> **Renderer note:** the build compiles with `d3d12=no winrt=no` because those
> drivers need separately-installed SDKs that otherwise abort the build with
> *"The Direct3D 12 rendering driver requires dependencies to be installed."* GSG
> uses Vulkan (Forward+), so they aren't needed. To build with D3D12, first run
> `godot/misc/scripts/install_d3d12_sdk_windows.py`, then override
> `WINDOWS_EDITOR_FLAGS` to drop `d3d12=no`.

### Build: web templates

Produces the threaded wasm template zip. Requires the editor to already exist.
Run this after updating the Godot fork version, or if the template zip was wiped.

```bash
./build_web.sh --skip-submodule --skip-editor --skip-glue --skip-assemblies --skip-export
```

### Build: export only (day-to-day)

Editor and templates already exist; recompile the game C# and pack the export.
This is the normal workflow after changing game code.

```bash
./build_web.sh --only-export
```

### Rebuild everything except the editor

Templates changed or assemblies changed, but you don't want to recompile the
editor binary (the slowest step):

```bash
./build_web.sh --skip-submodule --skip-editor --skip-glue
```

---

## Script options reference

```
--jobs N            Parallel build jobs (default: CPU count)
--skip-submodule    Skip git submodule update
--skip-workload     Skip dotnet wasm-tools workload install
--skip-editor       Skip compiling the editor binary
--skip-glue         Skip generating mono glue
--skip-assemblies   Skip building/pushing NuGet packages
--skip-emscripten   Skip Emscripten install/activate
--skip-templates    Skip building the wasm templates
--skip-export       Stop before the export step
--only-export       Shortcut: rewrite presets + export only (skips editor/template stages)
--no-auto-install   Check prerequisites but do not install anything
-h, --help          Show help
```

Override scons flags or clang version via environment variables if needed:

```bash
CLANG_VERSION=18 ./build_web.sh
EDITOR_SCONS_FLAGS="target=editor production=yes module_mono_enabled=yes" ./build_web.sh
```

## Notes & gotchas

- **Preset rewrite:** the export step overwrites the `custom_template/*` paths in
  `gsg/export_presets.cfg` to point at the built template zip. A backup is written
  to `export_presets.cfg.bak`. The Windows Godot editor also rewrites this file on
  save — **close the editor before running any export** or the template paths will
  be wiped.
- **Cross-origin isolation:** threaded (SharedArrayBuffer) builds need `COOP`/`COEP`
  headers when served. Use `gsg/exports/serve_web.py`, which sends
  `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy:
  require-corp`, fixes the `.mjs`/`.wasm` MIME types, and (importantly) uses a
  **threaded** HTTP server — a single-threaded server deadlocks because the browser
  holds many concurrent connections open for the wasm stream, pthread workers, and
  audio worklets:
  ```powershell
  python C:\Repos\Gamedev\gsg\exports\serve_web.py   # http://localhost:8060
  ```
- **Audio on web (already fixed in GSG):** Godot 4 defaults WAV `AudioStreamPlayer`s
  to *sample* playback on web, which `start()`s a one-shot `AudioBufferSourceNode`
  at boot while the `AudioContext` is still suspended (autoplay policy) — it can
  never restart, so audio stays silent. Two fixes live in the GSG repo so they
  survive every re-export:
  1. `scripts/Audio/AudioManager.cs` sets
     `PlaybackType = AudioServer.PlaybackType.Stream` on the music and every pooled
     SFX player (routes audio through the mixed AudioWorklet stream, which resumes
     correctly).
  2. `export_presets.cfg` `html/head_include` injects a small script that wraps
     `AudioContext` and resumes it on the first user gesture.
  Net effect: load the page, **click once**, and audio plays.
- **Stale mono cache:** if a build misbehaves or the editor reports "autoload not
  compiling" after a clean export, delete `gsg/.godot/mono/temp` and re-export.
  The export script's `rm -rf .godot/mono/temp` handles this automatically.
- **Stale NuGet cache (fixed-version SDK):** the Godot SDK packages always carry the
  same version string (e.g. `4.7.0-beta`). NuGet keys its **global** package cache
  (`~/.nuget/packages`) by id+version, so after a version has been extracted once it
  will *not* re-extract a rebuilt package with the same version — a later export then
  silently builds against the **stale** cached SDK and fails with *"Failed to build
  project"* on the first run, only to "self-heal" on a second run once something
  forces re-extraction. The script now defends against this: `stage_assemblies`
  purges `~/.nuget/packages/{godot.net.sdk,godotsharp,godotsharpeditor,
  godot.sourcegenerators}` right after pushing the fresh nupkgs, and the export's
  `dotnet restore --force` re-resolves them from the local feed. If you ever hit a
  stale-SDK error after a manual rebuild, clear those four cache folders by hand.
- **First run is long:** Godot is linked as a static library, so expect a lengthy
  initial compile. Subsequent incremental scons builds are much faster.
- **WSL on Windows — `chmod` fails (`Operation not permitted`):** by default WSL
  mounts Windows drives without Unix permission metadata, so `git submodule update`
  fails when it tries to `chmod` files under `/mnt/c`. Fix once:
  ```bash
  echo -e '[automount]\noptions = "metadata"' | sudo tee -a /etc/wsl.conf
  # then from PowerShell:
  wsl --shutdown
  ```
  Reopen WSL and re-run the script.
- **Clang optimizer crash on `scu_core_variant`:** clang 17–21 crash with a
  segfault in the LTO optimizer when `scu_build=yes` merges all variant code into
  one translation unit and `production=yes` enables `-flto=thin`. The script omits
  `scu_build` to avoid this. If you see a clang crash on `scu_core_variant.gen.cpp`,
  ensure `scu_build=yes` is not in your `EDITOR_SCONS_FLAGS` override, and delete
  the stale `.o` file before retrying:
  ```bash
  rm -f godot/bin/obj/core/variant/.scu/scu_core_variant.gen.linuxbsd.editor.x86_64.llvm.o
  ```

---

## Current status (June 2026)

The pipeline is **fully working for GSG**, end-to-end:

- GSG has been migrated to **Godot 4.7-beta** (`Godot.NET.Sdk/4.7.0-beta`,
  `net10.0`). The editor version matches the project, so the headless export runs
  cleanly.
- Custom Godot 4.7-beta editor + **threaded** web release template built from the
  NoctemCat fork (`libgodot_mono_web`); assemblies pushed to the local NuGet feed.
- GSG exports headlessly to **`gsg/exports/web/index.html`** via the `Web` preset.
- **Audio works** (music + SFX) after the two fixes documented in *Notes & gotchas*.
- Verified locally in Chrome + Firefox via `gsg/exports/serve_web.py` (COOP/COEP,
  correct MIME, threaded server).

### Threaded-only, and what that means for itch.io

The .NET wasm runtime **requires threads**, so the singlethreaded/nothreads template
is not an option for GSG — it hangs waiting for workers/SharedArrayBuffer the
nothreads shell never provides. The build is therefore always threaded
(`variant/thread_support=true`, SharedArrayBuffer enabled).

Consequence on itch.io: a SharedArrayBuffer game **cannot be embedded in an iframe**,
so itch launches it in a **new tab/window**. This is expected and unavoidable with
C# threaded export today; there is no in-page-embed option until official C# web
export ships in stable Godot.

### Repo layout assumed

This repo lives as a **submodule inside GSG** at
`C:\Repos\Gamedev\gsg\DotnetWebExportDemoFork`. The script exports the **parent**
project (`$REPO_ROOT/..` = `gsg`). Key paths:

- Editor binary: `gsg/DotnetWebExportDemoFork/godot/bin/godot.linuxbsd.editor.x86_64.llvm.mono`
- Threaded template (source): `gsg/DotnetWebExportDemoFork/godot/bin/godot.web.template_release.wasm32.mono.zip`
- Threaded template (in use): `gsg/.web_templates/godot.web.template_release.wasm32.mono.zip`
- Local NuGet feed: `gsg/nuget.config` → `DotnetWebExportDemoFork/.nuget_local`
- Export output: `gsg/exports/web/` · Local server: `gsg/exports/serve_web.py`
