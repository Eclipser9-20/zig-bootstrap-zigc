# ziggy-gui (prototype)

A standalone, native GUI editor for a proposed `Ziggy.toml` project-manifest
format — the eventual `ziggy gui` subcommand. This directory is a
**self-contained Zig project** (its own `build.zig` / `build.zig.zon` /
`src/`) and is **not** wired into the main compiler's `main.zig` or
`build.zig`. Nothing under `zig/`, `llvm/`, `clang/`, `lld/`, `out-win/`,
etc. was touched.

## Status: working v1

- Opens a real native window (GLFW + OpenGL3, via zgui/zglfw/zopengl).
- Form fields for `[project]` name/version, `[build]` target/optimize/
  root_source_file/output_type (dropdowns for optimize + output_type),
  and an add/remove list for `[dependencies]` path entries.
- Load / Save buttons read and write a real `Ziggy.toml` file at the path
  typed in the "File path" field (defaults to `Ziggy.toml` in the cwd).
- `zig build` succeeds and produces `zig-out/bin/ziggy-gui.exe`; running it
  opens the window and stays responsive (verified by launching it and
  letting it run for several seconds without crashing).
- `zig build test` passes a round-trip unit test of the TOML reader/writer.

Built and verified with the repo's own freshly-built compiler:
`C:\Users\gideo\lightning-ziggy\out-win\zig-x86_64-windows-gnu-baseline\zig.exe`
(version `0.16.0-dev.1354+94e98bfe8`), used read-only as a compiler for this
new tool — it was never modified.

## Ziggy.toml schema

See [SCHEMA.md](./SCHEMA.md) for the full spec. Summary:

```toml
[project]
name = "myapp"
version = "0.1.0"

[build]
target = "native"
optimize = "Debug"
root_source_file = "src/main.zig"
output_type = "exe"

[dependencies]
mylib = { path = "../mylib" }
```

## TOML parsing approach: hand-rolled

There is no actively-maintained, Zig-0.16.0-dev-compatible general TOML
library that was straightforward to vendor for this prototype (the
well-known `zig-toml` and similarly-named packages target older Zig
versions and weren't verified against `0.16.0-dev.1354`). Since the
Ziggy.toml v1 schema is intentionally small — flat `key = value` pairs
under a handful of fixed `[section]` headers, plus one special inline-table
case for `[dependencies]` — a ~150-line hand-rolled reader/writer
(`src/toml.zig`) was written instead. It is **not** a general TOML parser;
it understands exactly the shape documented in SCHEMA.md. This was
explicitly called out as an acceptable v1 shortcut in the task brief.

If a proper TOML library becomes available/maintained for the target Zig
version later, `src/toml.zig`'s `parse`/`serialize`/`Manifest` API is small
enough that swapping the implementation should not require GUI-side
changes.

## GUI stack: zgui + zglfw + zopengl (real deps, real build)

Vendored via `zig fetch --save=<name> <url>` against each package's
`main` branch tarball, matching zgui's own documented setup
(`Backend.glfw_opengl3`):

- `zglfw` 0.10.0-dev — window/input (GLFW bindings)
- `zopengl` 0.6.0-dev — OpenGL function loader
- `zgui` 0.6.0-dev — Dear ImGui bindings, built with `.backend = .glfw_opengl3`
- `system_sdk` 0.3.0-dev — lazy dep, only pulled in on Linux/macOS for
  system library paths (unused on this Windows build)

zgui's `build.zig.zon` states `minimum_zig_version = "0.16.0"`, which lines
up well with this repo's pinned `0.16.0-dev.1354+94e98bfe8` — all four
`zig fetch` calls succeeded cleanly with no hash/version resolution issues.

### Compatibility gap that had to be worked around

zig-gamedev's `main` branches track Zig's `master`/dev builds, and two
small pieces of vendored *source* (not just our own code) had drifted
just enough from `0.16.0-dev.1354` to fail to compile:

1. **`zgui`'s `build.zig`** (lines ~331, ~456) referenced
   `b.graph.environ_map`, but this Zig's `std.Build.Graph` names that
   field `env_map`. This only affects the (unused, in our case)
   `glfw_vulkan` / `sdl3_vulkan` backend branches, but Zig still
   type-checks all `switch` prongs when compiling `build.zig`, so it
   failed regardless of which backend was selected.
2. **`zgui`'s `src/gui.zig`** (its custom ImGui allocator hooks) called
   `std.Io.Mutex.State.swap(...)`, an API `std.Io.Mutex` no longer exposes
   in this Zig — mutex unlocking moved to `Mutex.unlock(io)` / an internal
   `mutexUnlock` vtable call. The zgui code was doing a simple manual
   unconditional unlock, which was replaced with an equivalent
   `@atomicStore(std.Io.Mutex.State, &mem_mutex.state, .unlocked, .release)`.

Both fixes were applied **directly to the vendored copies in the local Zig
package cache** (`%LOCALAPPDATA%\zig\p\zgui-...\build.zig` and
`...\src\gui.zig`), not to anything in this repo. This means:

- The fix is not tracked by this repo's git history and will not survive
  clearing the global Zig package cache or fetching zgui fresh on another
  machine.
- Anyone re-running `zig fetch --save=zgui ...` from scratch, or building
  on a different machine, will hit the same two errors and need to apply
  the same two one-line patches (`environ_map` → `env_map`, and the two
  `mem_mutex.state.swap(...)` calls → `@atomicStore(...)`) to their local
  zgui package cache copy, or wait for upstream zig-gamedev to catch up to
  this std lib rename.
- A longer-term fix would be pinning to a zgui commit/tag known to match
  this Zig dev snapshot exactly (none was found in zgui's tags at time of
  writing — its releases lag `main`, and `main` itself was only briefly
  ahead of this Zig snapshot's own churn), or vendoring a local fork of
  zgui with the fix committed into this repo instead of relying on the
  global package cache.

Given both issues were one-line, well-understood renames rather than
structural incompatibilities, patching the cache in place was the fastest
path to an actually-running window for this prototype.

## Build / run

```sh
cd tools/ziggy-gui
"C:\Users\gideo\lightning-ziggy\out-win\zig-x86_64-windows-gnu-baseline\zig.exe" build
./zig-out/bin/ziggy-gui.exe
```

Run unit tests (TOML round-trip):

```sh
"C:\Users\gideo\lightning-ziggy\out-win\zig-x86_64-windows-gnu-baseline\zig.exe" build test
```

Type a path in the "File path" field (default `Ziggy.toml`, relative to
wherever you launch the exe from) and use Load/Save to round-trip a real
file.

## What integrating this into the real `ziggy gui` subcommand would need

1. Vendor the same four dependencies (`zglfw`, `zopengl`, `zgui`,
   `system_sdk`) into `zig/build.zig.zon`, ideally pinned to a fork/commit
   with the two compatibility patches above committed in, rather than
   relying on `main` + a local cache patch.
2. Add a `gui.zig` module under `zig/src/` (e.g.
   `zig/src/tools/ziggy_gui.zig` or similar) containing the window/form
   logic — largely a copy of `src/gui.zig` and `src/toml.zig` here, with
   the manifest type shared with wherever `zig/build.zig`-generation logic
   ends up living.
3. Wire a `gui` dispatch branch into `zig/src/main.zig`'s subcommand
   dispatch (the way `zig/src/main.zig` already dispatches things like the
   `llvm-tools`/other tool subcommands) so `ziggy gui` launches the window
   instead of a separate `.exe`.
4. Decide how a `Ziggy.toml` maps to an actual generated `build.zig` (out
   of scope for this prototype — this tool only edits the manifest file
   itself, it does not yet generate or invoke a build from it).
5. Extend the manifest/parser for remote (`url`/`hash`) dependencies once
   path-only v1 is validated, mirroring `build.zig.zon`'s own dependency
   shape more completely.

None of this integration work was done as part of this task, per the
instructions to keep it fully separate from the working compiler build.
