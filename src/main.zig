const std = @import("std");
const playground = @import("playground");
const server_mod = @import("./server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize person store with sample data
    var store = playground.PersonStore.init(allocator);
    defer store.deinit();

    try store.add(.{
        .name = try allocator.dupe(u8, "Alice Smith"),
        .age = 28,
        .job = try allocator.dupe(u8, "Software Engineer"),
    });
    try store.add(.{
        .name = try allocator.dupe(u8, "Bob Johnson"),
        .age = 35,
        .job = try allocator.dupe(u8, "Product Manager"),
    });

    // Create and start server
    var server = try server_mod.Server.init(allocator, "127.0.0.1", 8080, &store);
    defer server.deinit();

    std.debug.print("REST API Server running\n", .{});
    std.debug.print("Available endpoints:\n", .{});
    std.debug.print("  GET    /people         - List all people\n", .{});
    std.debug.print("  GET    /people/:id     - Get person by index\n", .{});
    std.debug.print("  POST   /people         - Create new person\n", .{});
    std.debug.print("  PUT    /people/:id     - Update person by index\n", .{});
    std.debug.print("  DELETE /people/:id     - Delete person by index\n", .{});
    std.debug.print("\nPress Ctrl+C to stop the server\n\n", .{});

    try server.listen();
}
