//! Native window + Dear ImGui (zgui) form for editing a Ziggy.toml file.
//! See SCHEMA.md for the file format and README.md for build/run notes.

const std = @import("std");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const toml = @import("toml.zig");

const window_title = "ziggy gui - Ziggy.toml editor (prototype)";
const default_path = "Ziggy.toml";

const optimize_options = [_][:0]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };
const output_type_options = [_][:0]const u8{ "exe", "lib", "obj" };

/// Fixed-size text buffers backing the ImGui text inputs. zgui's InputText
/// wants a mutable, null-terminated, fixed-capacity buffer rather than a
/// Zig slice, so the editable form state lives here instead of directly
/// in a toml.Manifest.
const FormState = struct {
    path_buf: [512:0]u8 = undefined,
    name_buf: [256:0]u8 = undefined,
    version_buf: [64:0]u8 = undefined,
    target_buf: [128:0]u8 = undefined,
    root_source_buf: [256:0]u8 = undefined,
    optimize_index: usize = 0,
    output_type_index: usize = 0,

    dep_names: std.ArrayListUnmanaged([256:0]u8) = .{},
    dep_paths: std.ArrayListUnmanaged([256:0]u8) = .{},
    new_dep_name_buf: [256:0]u8 = undefined,
    new_dep_path_buf: [256:0]u8 = undefined,

    status: [256:0]u8 = undefined,

    fn init() FormState {
        var s = FormState{};
        setZ(&s.path_buf, default_path);
        setZ(&s.name_buf, "myapp");
        setZ(&s.version_buf, "0.1.0");
        setZ(&s.target_buf, "native");
        setZ(&s.root_source_buf, "src/main.zig");
        setZ(&s.new_dep_name_buf, "");
        setZ(&s.new_dep_path_buf, "");
        setZ(&s.status, "Ready.");
        return s;
    }

    fn deinit(self: *FormState, allocator: std.mem.Allocator) void {
        self.dep_names.deinit(allocator);
        self.dep_paths.deinit(allocator);
    }

    fn loadFromManifest(self: *FormState, allocator: std.mem.Allocator, m: *const toml.Manifest) !void {
        setZ(&self.name_buf, m.project_name);
        setZ(&self.version_buf, m.project_version);
        setZ(&self.target_buf, m.build_target);
        setZ(&self.root_source_buf, m.build_root_source_file);
        self.optimize_index = indexOfOr(&optimize_options, m.build_optimize, 0);
        self.output_type_index = indexOfOr(&output_type_options, m.build_output_type, 0);

        self.dep_names.clearRetainingCapacity();
        self.dep_paths.clearRetainingCapacity();
        for (m.dependencies.items) |d| {
            var name_buf: [256:0]u8 = undefined;
            var path_buf: [256:0]u8 = undefined;
            setZ(&name_buf, d.name);
            setZ(&path_buf, d.path);
            try self.dep_names.append(allocator, name_buf);
            try self.dep_paths.append(allocator, path_buf);
        }
    }

    /// Builds a fresh toml.Manifest owned by `allocator` from the current
    /// form buffers.
    fn toManifest(self: *const FormState, allocator: std.mem.Allocator) !toml.Manifest {
        var m = toml.Manifest.init(allocator);
        errdefer m.deinit();
        m.project_name = try allocator.dupe(u8, sliceZ(&self.name_buf));
        m.project_version = try allocator.dupe(u8, sliceZ(&self.version_buf));
        m.build_target = try allocator.dupe(u8, sliceZ(&self.target_buf));
        m.build_optimize = try allocator.dupe(u8, optimize_options[self.optimize_index]);
        m.build_root_source_file = try allocator.dupe(u8, sliceZ(&self.root_source_buf));
        m.build_output_type = try allocator.dupe(u8, output_type_options[self.output_type_index]);
        for (self.dep_names.items, self.dep_paths.items) |*n, *p| {
            try m.addDependency(sliceZ(n), sliceZ(p));
        }
        return m;
    }
};

fn setZ(buf: []u8, value: []const u8) void {
    const n = @min(value.len, buf.len - 1);
    @memcpy(buf[0..n], value[0..n]);
    @memset(buf[n..], 0);
}

fn sliceZ(buf: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..n];
}

fn indexOfOr(options: []const [:0]const u8, value: []const u8, default_index: usize) usize {
    for (options, 0..) |opt, i| {
        if (std.mem.eql(u8, opt, value)) return i;
    }
    return default_index;
}

pub fn run(allocator: std.mem.Allocator) !void {
    try glfw.init();
    defer glfw.terminate();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(900, 640, window_title, null, null);
    defer window.destroy();
    window.setSizeLimits(500, 400, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);
    const gl = zopengl.bindings;

    zgui.init(allocator);
    defer zgui.deinit();

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    var state = FormState.init();
    defer state.deinit(allocator);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        glfw.pollEvents();

        gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0.10, 0.10, 0.12, 1.0 });

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

        zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 560.0, .h = 580.0, .cond = .first_use_ever });

        if (zgui.begin("Ziggy.toml editor", .{})) {
            _ = zgui.inputText("File path", .{ .buf = &state.path_buf });

            zgui.separatorText("[project]");
            _ = zgui.inputText("name", .{ .buf = &state.name_buf });
            _ = zgui.inputText("version", .{ .buf = &state.version_buf });

            zgui.separatorText("[build]");
            _ = zgui.inputText("target", .{ .buf = &state.target_buf });
            _ = zgui.inputText("root_source_file", .{ .buf = &state.root_source_buf });

            if (zgui.beginCombo("optimize", .{ .preview_value = optimize_options[state.optimize_index] })) {
                for (optimize_options, 0..) |opt, i| {
                    const selected = i == state.optimize_index;
                    if (zgui.selectable(opt, .{ .selected = selected })) state.optimize_index = i;
                }
                zgui.endCombo();
            }

            if (zgui.beginCombo("output_type", .{ .preview_value = output_type_options[state.output_type_index] })) {
                for (output_type_options, 0..) |opt, i| {
                    const selected = i == state.output_type_index;
                    if (zgui.selectable(opt, .{ .selected = selected })) state.output_type_index = i;
                }
                zgui.endCombo();
            }

            zgui.separatorText("[dependencies]  (path deps only, v1)");

            var remove_index: ?usize = null;
            for (state.dep_names.items, state.dep_paths.items, 0..) |*n, *p, i| {
                zgui.pushIntId(@intCast(i));
                _ = zgui.inputText("name", .{ .buf = n });
                zgui.sameLine(.{});
                _ = zgui.inputText("path", .{ .buf = p });
                zgui.sameLine(.{});
                if (zgui.button("Remove", .{})) remove_index = i;
                zgui.popId();
            }
            if (remove_index) |i| {
                _ = state.dep_names.orderedRemove(i);
                _ = state.dep_paths.orderedRemove(i);
            }

            _ = zgui.inputText("new dep name", .{ .buf = &state.new_dep_name_buf });
            _ = zgui.inputText("new dep path", .{ .buf = &state.new_dep_path_buf });
            if (zgui.button("Add dependency", .{})) {
                const name = sliceZ(&state.new_dep_name_buf);
                if (name.len > 0) {
                    var name_buf: [256:0]u8 = undefined;
                    var path_buf: [256:0]u8 = undefined;
                    setZ(&name_buf, name);
                    setZ(&path_buf, sliceZ(&state.new_dep_path_buf));
                    try state.dep_names.append(allocator, name_buf);
                    try state.dep_paths.append(allocator, path_buf);
                    setZ(&state.new_dep_name_buf, "");
                    setZ(&state.new_dep_path_buf, "");
                }
            }

            zgui.separator();

            if (zgui.button("Load", .{ .w = 100.0 })) {
                loadFile(&state, allocator) catch |err| {
                    setZ(&state.status, std.fmt.bufPrint(&status_scratch, "Load failed: {s}", .{@errorName(err)}) catch "Load failed.");
                };
            }
            zgui.sameLine(.{});
            if (zgui.button("Save", .{ .w = 100.0 })) {
                saveFile(&state, allocator) catch |err| {
                    setZ(&state.status, std.fmt.bufPrint(&status_scratch, "Save failed: {s}", .{@errorName(err)}) catch "Save failed.");
                };
            }

            zgui.textWrapped("{s}", .{sliceZ(&state.status)});
        }
        zgui.end();

        zgui.backend.draw();
        window.swapBuffers();
    }
}

var status_scratch: [256]u8 = undefined;

fn loadFile(state: *FormState, allocator: std.mem.Allocator) !void {
    const path = sliceZ(&state.path_buf);
    const text = try std.fs.cwd().readFileAlloc(path, allocator, .limited(1 << 20));
    defer allocator.free(text);

    var manifest = try toml.parse(allocator, text);
    defer manifest.deinit();

    try state.loadFromManifest(allocator, &manifest);
    setZ(&state.status, "Loaded.");
}

fn saveFile(state: *FormState, allocator: std.mem.Allocator) !void {
    var manifest = try state.toManifest(allocator);
    defer manifest.deinit();

    const text = try toml.serialize(allocator, &manifest);
    defer allocator.free(text);

    const path = sliceZ(&state.path_buf);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
    setZ(&state.status, "Saved.");
}
