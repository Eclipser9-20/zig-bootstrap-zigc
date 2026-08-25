const std = @import("std");
const toml = @import("toml.zig");
const gui = @import("gui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try gui.run(allocator);
}

test {
    _ = toml;
}
