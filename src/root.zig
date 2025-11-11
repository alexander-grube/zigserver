//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

/// Person struct representing a person with basic information
pub const Person = struct {
    name: []const u8,
    age: u32,
    job: []const u8,

    pub fn format(self: Person, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        // If format spec is "any", manually output JSON
        if (comptime std.mem.eql(u8, fmt, "any")) {
            try writer.print("{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ self.name, self.age, self.job });
        } else {
            try writer.print("{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ self.name, self.age, self.job });
        }
    }
};
