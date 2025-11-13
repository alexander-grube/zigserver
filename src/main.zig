const std = @import("std");
const playground = @import("playground");
const server_mod = @import("./server.zig");
const pg = @import("pg");
const dotenv = @import("./dotenv.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var env = try dotenv.init(allocator, ".env");
    defer env.deinit();

    const worker_threads = try std.fmt.parseInt(usize, env.get("SERVER_WORKER_THREADS") orelse "40", 10);

    const postgres_pool_size = try std.fmt.parseInt(u16, env.get("POSTGRES_POOL_SIZE") orelse "40", 10);

    var pool = try pg.Pool.init(allocator, .{ .size = postgres_pool_size, .connect = .{
        .port = 5432,
        .host = "127.0.0.1",
    }, .auth = .{
        .username = env.get("POSTGRES_USER") orelse "postgres",
        .database = env.get("POSTGRES_DB") orelse "postgres",
        .password = env.get("POSTGRES_PASSWORD") orelse "password",
        .timeout = 10_000,
    } });
    defer pool.deinit();

    // Create and start server
    var server = try server_mod.Server.init(allocator, "127.0.0.1", 8080, pool, worker_threads);
    defer server.deinit();

    std.debug.print("Worker threads: {d}\n", .{worker_threads});
    std.debug.print("Postgres pool size: {d}\n", .{postgres_pool_size});

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
