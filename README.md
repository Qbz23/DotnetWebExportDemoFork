# C# Web Export Demo (Through LibGodot)

Link https://noctemcat.itch.io/wasm-demo

## Major downsides 

- It will force the support for Emscripten 3.1.56 until C# is updated (https://github.com/dotnet/runtime/issues/113786).
- Can't export with GDExtension supported, C# can't be build with `-sMAIN_MODULE` flag.
- Currently it is not a problem, but CoreCLR also uses `Object` without namespace, so it causes duplicate symbols for `Object` vtable. 
If wasm will move to CoreCLR https://github.com/dotnet/runtime/issues/121511 after updating emscipten to be new enough to use 
allow-multiple-definition https://github.com/llvm/llvm-project/pull/97699 this won't be a problem.

## Small downsides

- Slow to export, as it needs to link Godot as a static library.
- C# multithreading runs main C# thread as a thread https://github.com/dotnet/runtime/issues/101421, https://github.com/dotnet/runtime/issues/126438.
- C# multithreading is incompatible with webxr, similar to `proxy_to_pthread`.
- C# multithreading `await Task.Delay` causes a massive lag spike for the first time.
- Can't use Godot as lto library.
- When changing from multithreaded build to singlethreaded C# needs full rebuild, i.e. deleting `.godot/mono/temp`.
- C# JS interop in multithreading doesn't allow sync C#->JS->C# or JS->C#->JS, with `jsThreadBlockingMode: 'ThrowWhenBlockingWait'` 
it allows sync C#->JS and JS->C#, but that's all. More info https://github.com/dotnet/runtime/issues/101421#issuecomment-2072439395 
and this seems also correct https://dev.to/lostbeard/blazor-wasms-deputy-thread-model-will-break-javascript-interop-heres-why-that-matters-1n9n.

## Big hacks

- Calls web's `_export_begin` after extracting templates. It's needed for passing the path to the static library in `ExportPlugin.cs._ExportBegin`. 
I think it is possible to add a separate step after extracting templates, but before _export_file begins... not sure tho.

## How to build

Steps:
- Update Godot fork
```
cd godot
git submodule update --init
```
- C# install `wasm-tools` workload
```
dotnet workload install wasm-tools
```
- Read https://docs.godotengine.org/en/latest/engine_details/development/compiling/compiling_with_dotnet.html along
and compile editor with mono enabled
```
scons target=editor production=yes module_mono_enabled=yes
```
- Generate glue
```
<godot_binary> --generate-mono-glue ./modules/mono/glue --headless
```
- Build and put build assemblies in the place `csharp_project/nuget.config` expects
```
./modules/mono/build_scripts/build_assemblies.py --godot-output-dir ./bin --push-nupkgs-local ./../.nuget_local/
```
- Install and activate Emscripten 3.1.56 https://emscripten.org/docs/getting_started/downloads.html#emsdk-install-targets.
- Build release template
```
# multithreaded
scons target=template_release platform=web library_type=static_library module_mono_enabled=yes lto=none disable_crash_handler=yes proxy_to_pthread=yes
# singlethreaded
scons target=template_release platform=web library_type=static_library module_mono_enabled=yes lto=none disable_crash_handler=yes threads=no
```
- Select compiled `.zip` template in export window custom template
- Select the correct `Thread Support`, it is important
- Export the game
