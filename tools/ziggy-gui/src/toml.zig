//! A minimal, hand-rolled TOML reader/writer sufficient for the Ziggy.toml
//! v1 schema documented in SCHEMA.md. This is NOT a general-purpose TOML
//! parser: it understands exactly what Ziggy.toml needs -
//!   - `[section]` headers
//!   - flat `key = "string"` / `key = value` (bare word) lines inside a
//!     section
//!   - one special case: `[dependencies]` entries of the form
//!       name = { path = "../foo" }
//!
//! Rationale: as of writing there is no actively-maintained, Zig
//! 0.16.0-dev-compatible general TOML library that was easy to vendor
//! for this prototype. The schema this tool needs is small enough that
//! a ~150 line hand-rolled reader is a reasonable v1 shortcut (this was
//! called out explicitly as an acceptable path in the task brief).

const std = @import("std");

pub const Dependency = struct {
    name: []const u8,
    path: []const u8,
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,

    project_name: []const u8 = "",
    project_version: []const u8 = "",

    build_target: []const u8 = "native",
    build_optimize: []const u8 = "Debug",
    build_root_source_file: []const u8 = "src/main.zig",
    build_output_type: []const u8 = "exe",

    dependencies: std.ArrayListUnmanaged(Dependency) = .{},

    pub fn init(allocator: std.mem.Allocator) Manifest {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.project_name);
        self.allocator.free(self.project_version);
        self.allocator.free(self.build_target);
        self.allocator.free(self.build_optimize);
        self.allocator.free(self.build_root_source_file);
        self.allocator.free(self.build_output_type);
        for (self.dependencies.items) |d| {
            self.allocator.free(d.name);
            self.allocator.free(d.path);
        }
        self.dependencies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addDependency(self: *Manifest, name: []const u8, path: []const u8) !void {
        try self.dependencies.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
        });
    }

    pub fn removeDependency(self: *Manifest, index: usize) void {
        if (index >= self.dependencies.items.len) return;
        const d = self.dependencies.orderedRemove(index);
        self.allocator.free(d.name);
        self.allocator.free(d.path);
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Strips one layer of surrounding double quotes, if present.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub const ParseError = error{
    InvalidLine,
    InvalidDependency,
} || std.mem.Allocator.Error;

/// Parses `text` (already-loaded file contents) into a Manifest.
/// Any field not present in the source keeps the struct's defaults.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Manifest {
    var manifest = Manifest.init(allocator);
    errdefer manifest.deinit();

    // Own defaults so deinit() can always free unconditionally.
    manifest.project_name = try allocator.dupe(u8, "");
    manifest.project_version = try allocator.dupe(u8, "");
    manifest.build_target = try allocator.dupe(u8, "native");
    manifest.build_optimize = try allocator.dupe(u8, "Debug");
    manifest.build_root_source_file = try allocator.dupe(u8, "src/main.zig");
    manifest.build_output_type = try allocator.dupe(u8, "exe");

    var section: enum { none, project, build, dependencies } = .none;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = line[1 .. line.len - 1];
            if (std.mem.eql(u8, name, "project")) {
                section = .project;
            } else if (std.mem.eql(u8, name, "build")) {
                section = .build;
            } else if (std.mem.eql(u8, name, "dependencies")) {
                section = .dependencies;
            } else {
                section = .none;
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
        const key = trim(line[0..eq]);
        const value = trim(line[eq + 1 ..]);
        if (key.len == 0) return error.InvalidLine;

        switch (section) {
            .project => {
                if (std.mem.eql(u8, key, "name")) {
                    allocator.free(manifest.project_name);
                    manifest.project_name = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "version")) {
                    allocator.free(manifest.project_version);
                    manifest.project_version = try allocator.dupe(u8, unquote(value));
                }
            },
            .build => {
                if (std.mem.eql(u8, key, "target")) {
                    allocator.free(manifest.build_target);
                    manifest.build_target = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "optimize")) {
                    allocator.free(manifest.build_optimize);
                    manifest.build_optimize = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "root_source_file")) {
                    allocator.free(manifest.build_root_source_file);
                    manifest.build_root_source_file = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "output_type")) {
                    allocator.free(manifest.build_output_type);
                    manifest.build_output_type = try allocator.dupe(u8, unquote(value));
                }
            },
            .dependencies => {
                // value looks like: { path = "../foo" }
                const open = std.mem.indexOfScalar(u8, value, '{') orelse return error.InvalidDependency;
                const close = std.mem.lastIndexOfScalar(u8, value, '}') orelse return error.InvalidDependency;
                if (close < open) return error.InvalidDependency;
                const inner = trim(value[open + 1 .. close]);
                const inner_eq = std.mem.indexOfScalar(u8, inner, '=') orelse return error.InvalidDependency;
                const inner_key = trim(inner[0..inner_eq]);
                if (!std.mem.eql(u8, inner_key, "path")) return error.InvalidDependency;
                const path_val = unquote(trim(inner[inner_eq + 1 ..]));
                try manifest.addDependency(key, path_val);
            },
            .none => {},
        }
    }

    return manifest;
}

/// Serializes a Manifest back to Ziggy.toml text. Caller owns returned slice.
pub fn serialize(allocator: std.mem.Allocator, manifest: *const Manifest) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    try out.print(allocator, "[project]\n", .{});
    try out.print(allocator, "name = \"{s}\"\n", .{manifest.project_name});
    try out.print(allocator, "version = \"{s}\"\n\n", .{manifest.project_version});

    try out.print(allocator, "[build]\n", .{});
    try out.print(allocator, "target = \"{s}\"\n", .{manifest.build_target});
    try out.print(allocator, "optimize = \"{s}\"\n", .{manifest.build_optimize});
    try out.print(allocator, "root_source_file = \"{s}\"\n", .{manifest.build_root_source_file});
    try out.print(allocator, "output_type = \"{s}\"\n\n", .{manifest.build_output_type});

    try out.print(allocator, "[dependencies]\n", .{});
    for (manifest.dependencies.items) |d| {
        try out.print(allocator, "{s} = {{ path = \"{s}\" }}\n", .{ d.name, d.path });
    }

    return out.toOwnedSlice(allocator);
}

test "parse and serialize round trip" {
    const allocator = std.testing.allocator;
    const src =
        \\[project]
        \\name = "hello"
        \\version = "0.1.0"
        \\
        \\[build]
        \\target = "native"
        \\optimize = "Debug"
        \\root_source_file = "src/main.zig"
        \\output_type = "exe"
        \\
        \\[dependencies]
        \\mylib = { path = "../mylib" }
        \\
    ;

    var manifest = try parse(allocator, src);
    defer manifest.deinit();

    try std.testing.expectEqualStrings("hello", manifest.project_name);
    try std.testing.expectEqualStrings("0.1.0", manifest.project_version);
    try std.testing.expectEqualStrings("native", manifest.build_target);
    try std.testing.expectEqualStrings("Debug", manifest.build_optimize);
    try std.testing.expectEqual(@as(usize, 1), manifest.dependencies.items.len);
    try std.testing.expectEqualStrings("mylib", manifest.dependencies.items[0].name);
    try std.testing.expectEqualStrings("../mylib", manifest.dependencies.items[0].path);

    const out = try serialize(allocator, &manifest);
    defer allocator.free(out);

    var manifest2 = try parse(allocator, out);
    defer manifest2.deinit();
    try std.testing.expectEqualStrings(manifest.project_name, manifest2.project_name);
    try std.testing.expectEqualStrings(manifest.dependencies.items[0].path, manifest2.dependencies.items[0].path);
}
