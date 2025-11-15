const std = @import("std");
const http = @import("./http.zig");
const router = @import("./router.zig");
const playground = @import("playground");
const pg = @import("pg");

const ConnectionContext = struct {
    stream: std.net.Stream,
    router: *router.Router,
    allocator: std.mem.Allocator,
};

const WorkItem = struct {
    stream: std.net.Stream,
};

const ThreadPool = struct {
    threads: []std.Thread,
    work_queue: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    router: *router.Router,
    allocator: std.mem.Allocator,
    shutdown: bool,

    pub fn init(allocator: std.mem.Allocator, size: usize, rt: *router.Router) !*ThreadPool {
        const pool = try allocator.create(ThreadPool);
        pool.* = .{
            .threads = try allocator.alloc(std.Thread, size),
            .work_queue = .empty,
            .mutex = .{},
            .cond = .{},
            .router = rt,
            .allocator = allocator,
            .shutdown = false,
        };

        // Spawn worker threads
        for (pool.threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{pool});
        }

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown
        self.mutex.lock();
        self.shutdown = true;
        self.cond.broadcast();
        self.mutex.unlock();

        // Wait for all threads to finish
        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.work_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *ThreadPool, stream: std.net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.work_queue.append(self.allocator, .{ .stream = stream });
        self.cond.signal();
    }

    fn workerThread(self: *ThreadPool) void {
        while (true) {
            self.mutex.lock();

            // Wait for work or shutdown signal
            while (self.work_queue.items.len == 0 and !self.shutdown) {
                self.cond.wait(&self.mutex);
            }

            if (self.shutdown) {
                self.mutex.unlock();
                return;
            }

            const work_item = self.work_queue.orderedRemove(0);
            self.mutex.unlock();

            // Process the connection
            handleConnection(work_item.stream, self.router, self.allocator);
        }
    }
};

pub const Server = struct {
    address: std.net.Address,
    router: router.Router,
    allocator: std.mem.Allocator,
    thread_pool: *ThreadPool,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, pool: *pg.Pool, thread_pool_size: usize) !*Server {
        const address = try std.net.Address.parseIp(host, port);
        var rt = router.Router.init(allocator, pool);

        // Register routes
        try rt.addRoute(.GET, "/people", router.handleGetAll);
        try rt.addRoute(.GET, "/people/:id", router.handleGetOne);
        try rt.addRoute(.POST, "/people", router.handleCreate);
        try rt.addRoute(.PUT, "/people/:id", router.handleUpdate);
        try rt.addRoute(.DELETE, "/people/:id", router.handleDelete);

        const server = try allocator.create(Server);
        server.* = .{
            .address = address,
            .router = rt,
            .allocator = allocator,
            .thread_pool = undefined,
        };

        server.thread_pool = try ThreadPool.init(allocator, thread_pool_size, &server.router);

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.thread_pool.deinit();
        self.router.deinit();
        self.allocator.destroy(self);
    }

    pub fn listen(self: *Server) !void {
        var server = try self.address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        const port = self.address.getPort();
        std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{port});

        while (true) {
            const connection = try server.accept();
            try self.thread_pool.submit(connection.stream);
        }
    }
};

fn handleConnection(stream: std.net.Stream, rt: *router.Router, allocator: std.mem.Allocator) void {
    defer stream.close();

    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = http.readRequest(stream, &buffer, 30000) catch |err| {
            if (err == error.Timeout) {
                std.debug.print("Connection timeout\n", .{});
                return;
            }
            if (err == error.ConnectionClosed) {
                return;
            }
            std.debug.print("Error reading request: {}\n", .{err});
            return;
        };

        if (bytes_read == 0) return;

        const request_data = buffer[0..bytes_read];

        // Parse request
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();
        var request = http.Request.init(arena_allocator, request_data) catch |err| {
            std.debug.print("Error parsing request: {}\n", .{err});
            const error_response = http.Response.json(.bad_request, "{\"error\":\"Invalid request\"}", false);
            error_response.write(allocator, stream) catch {};
            return;
        };
        defer request.deinit();

        std.debug.print("{any} {s}\n", .{ request.method, request.path });

        // Check if client wants to close
        const should_close = request.shouldClose();

        // Check for streaming response (GET /people)
        if (request.method == .GET and std.mem.eql(u8, request.path, "/people")) {
            router.streamGetAllResponse(stream, rt.pool, arena_allocator, request.wantsKeepAlive()) catch |err| {
                std.debug.print("Error streaming response: {}\n", .{err});
                return;
            };

            if (should_close) {
                return;
            }
            continue;
        }

        // Route and handle request normally
        var response = rt.route(&request) catch |err| {
            std.debug.print("Error handling request: {}\n", .{err});
            const error_response = http.Response.json(.internal_server_error, "{\"error\":\"Internal server error\"}", false);
            error_response.write(allocator, stream) catch {};
            return;
        };
        defer response.deinit();

        // Send response
        response.write(arena_allocator, stream) catch |err| {
            std.debug.print("Error sending response: {}\n", .{err});
            return;
        };

        // Close connection if requested or if keep-alive is not wanted
        if (should_close or !response.keep_alive) {
            return;
        }
    }
}
