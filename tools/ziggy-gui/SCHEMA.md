# Ziggy.toml schema (v1)

`Ziggy.toml` is a Cargo.toml-style project manifest, intended as an
alternative/companion to hand-writing `build.zig` for simple `ziggy`
projects. This is the v1 schema targeted by the `ziggy gui` prototype
in this directory.

```toml
[project]
name = "myapp"
version = "0.1.0"

[build]
target = "native"        # "native" or a real target triple, e.g. "x86_64-windows-gnu"
optimize = "Debug"        # Debug | ReleaseSafe | ReleaseFast | ReleaseSmall
root_source_file = "src/main.zig"
output_type = "exe"       # exe | lib | obj

[dependencies]
# v1 supports path dependencies only, mirroring build.zig.zon's shape:
# foo = { path = "../foo" }
#
# Future (not yet supported by this prototype's parser/GUI):
# bar = { url = "https://example.com/bar.tar.gz", hash = "1220..." }
```

## Field notes

- `[project].name` — string, required. Package/binary name.
- `[project].version` — string, required. Semver-ish, free-form for v1.
- `[build].target` — string. `"native"` means "build for the host"; any
  other value is treated as a raw Zig target triple string passed through
  to `-Dtarget=` style resolution later when this is wired into the real
  build. Not validated by the GUI beyond non-empty.
- `[build].optimize` — one of `Debug`, `ReleaseSafe`, `ReleaseFast`,
  `ReleaseSmall`. Presented as a dropdown in the GUI.
- `[build].root_source_file` — string path, relative to the project root.
- `[build].output_type` — one of `exe`, `lib`, `obj`. Presented as a
  dropdown in the GUI.
- `[dependencies]` — table of `name = { path = "..." }` entries. Each key
  is a dependency name, value is an inline table with a `path` string.
  This mirrors the shape `build.zig.zon` already uses for path deps, so
  it should look familiar. URL/hash-based (remote) dependencies are
  intentionally out of scope for v1 — see SCHEMA future note above.

## Example round-trip file

```toml
[project]
name = "hello"
version = "0.1.0"

[build]
target = "native"
optimize = "Debug"
root_source_file = "src/main.zig"
output_type = "exe"

[dependencies]
mylib = { path = "../mylib" }
```

This is the exact file format the `ziggy-gui` prototype's Load/Save
buttons read and write.
