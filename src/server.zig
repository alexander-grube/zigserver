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

pub const Server = struct {
    address: std.net.Address,
    router: router.Router,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, pool: *pg.Pool) !Server {
        const address = try std.net.Address.parseIp(host, port);
        var rt = router.Router.init(allocator, pool);

        // Register routes
        try rt.addRoute(.GET, "/people", router.handleGetAll);
        try rt.addRoute(.GET, "/people/:id", router.handleGetOne);
        try rt.addRoute(.POST, "/people", router.handleCreate);
        try rt.addRoute(.PUT, "/people/:id", router.handleUpdate);
        try rt.addRoute(.DELETE, "/people/:id", router.handleDelete);

        return .{
            .address = address,
            .router = rt,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
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

            // Create connection context
            const context = try self.allocator.create(ConnectionContext);
            context.* = .{
                .stream = connection.stream,
                .router = &self.router,
                .allocator = self.allocator,
            };

            // Spawn thread to handle connection
            const thread = try std.Thread.spawn(.{}, handleConnection, .{context});
            thread.detach();
        }
    }
};

fn handleConnection(context: *ConnectionContext) void {
    defer context.allocator.destroy(context);
    defer context.stream.close();

    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = http.readRequest(context.stream, &buffer, 30000) catch |err| {
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
        var request = http.Request.init(context.allocator, request_data) catch |err| {
            std.debug.print("Error parsing request: {}\n", .{err});
            const error_response = http.Response.json(.bad_request, "{\"error\":\"Invalid request\"}", false);
            error_response.write(context.allocator, context.stream) catch {};
            return;
        };
        defer request.deinit();

        std.debug.print("{any} {s}\n", .{ request.method, request.path });

        // Check if client wants to close
        const should_close = request.shouldClose();

        // Check for streaming response (GET /people)
        if (request.method == .GET and std.mem.eql(u8, request.path, "/people")) {
            router.streamGetAllResponse(context.stream, context.router.pool, context.allocator, request.wantsKeepAlive()) catch |err| {
                std.debug.print("Error streaming response: {}\n", .{err});
                return;
            };

            if (should_close) {
                return;
            }
            continue;
        }

        // Route and handle request normally
        var response = context.router.route(&request) catch |err| {
            std.debug.print("Error handling request: {}\n", .{err});
            const error_response = http.Response.json(.internal_server_error, "{\"error\":\"Internal server error\"}", false);
            error_response.write(context.allocator, context.stream) catch {};
            return;
        };
        defer response.deinit();

        // Send response
        response.write(context.allocator, context.stream) catch |err| {
            std.debug.print("Error sending response: {}\n", .{err});
            return;
        };

        // Close connection if requested or if keep-alive is not wanted
        if (should_close or !response.keep_alive) {
            return;
        }
    }
}
