# Engine API reference for building Pasture3D

`extension_api-4.7.0-stable.json` is the GDExtension API dumped from
**Godot 4.7.0-stable** (`--dump-extension-api`). The plugin is built against this exact
file via SCons `custom_api_file=` so that godot-cpp's generated method-bind hashes match
the stable engine the plugin runs in.

This override exists because, at migration time, **godot-cpp had no `godot-4.7` tag/branch**;
`master` (godot-cpp 10.0.0-rc1) bundles only a 4.7-**rc3** `extension_api-4-7.json`, whose
method hashes differ from 4.7.0-stable. Once godot-cpp publishes a 4.7-stable tag, this
override can be dropped in favour of the submodule's bundled file.

## Build commands

From the repo root:

```sh
# Editor / debug (loads in the Godot 4.7 editor)
python -m SCons platform=windows target=editor \
  custom_api_file=engine_api/extension_api-4.7.0-stable.json -j8

# Export / release template
python -m SCons platform=windows target=template_release \
  custom_api_file=engine_api/extension_api-4.7.0-stable.json -j8
```

`scons` is not on PATH; invoke it as `python -m SCons`.

## Regenerating the dump (e.g. for a newer 4.7 patch)

```sh
"<path>/Godot_v4.7-stable_win64_console.exe" --headless \
  --dump-extension-api --dump-gdextension-interface
```

`--dump-extension-api` writes `extension_api.json` to the current directory; copy it here.
