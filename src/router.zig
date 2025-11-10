const std = @import("std");
const http = @import("./http.zig");
const playground = @import("playground");

pub const RouteHandler = *const fn (*playground.PersonStore, *const http.Request, std.mem.Allocator) anyerror!http.Response;

pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    store: *playground.PersonStore,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store: *playground.PersonStore) Router {
        return .{
            .routes = .empty,
            .store = store,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    pub fn addRoute(self: *Router, method: http.Method, pattern: []const u8, handler: RouteHandler) !void {
        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
        });
    }

    pub fn route(self: *Router, request: *const http.Request) !http.Response {
        // Handle OPTIONS for CORS
        if (request.method == .OPTIONS) {
            return http.Response.text(.ok, "OK", request.wantsKeepAlive());
        }

        // Try to match routes
        for (self.routes.items) |r| {
            if (r.method != request.method) continue;

            // Exact match
            if (std.mem.eql(u8, r.pattern, request.path)) {
                return r.handler(self.store, request, self.allocator);
            }

            // Pattern match (e.g., /people/:id)
            if (matchPattern(r.pattern, request.path)) {
                return r.handler(self.store, request, self.allocator);
            }
        }

        return http.Response.json(.not_found, "{\"error\":\"Not found\"}", request.wantsKeepAlive());
    }
};

fn matchPattern(pattern: []const u8, path: []const u8) bool {
    // Simple pattern matching for :id style patterns
    var pattern_parts = std.mem.splitSequence(u8, pattern, "/");
    var path_parts = std.mem.splitSequence(u8, path, "/");

    while (pattern_parts.next()) |pattern_part| {
        const path_part = path_parts.next() orelse return false;

        if (pattern_part.len > 0 and pattern_part[0] == ':') {
            // This is a parameter, match anything
            continue;
        }

        if (!std.mem.eql(u8, pattern_part, path_part)) {
            return false;
        }
    }

    // Make sure we consumed all path parts
    return path_parts.next() == null;
}

pub fn extractId(path: []const u8) ?usize {
    var parts = std.mem.splitSequence(u8, path, "/");
    var last: ?[]const u8 = null;

    while (parts.next()) |part| {
        if (part.len > 0) last = part;
    }

    if (last) |id_str| {
        return std.fmt.parseInt(usize, id_str, 10) catch null;
    }

    return null;
}

// Handler functions
pub fn handleGetAll(store: *playground.PersonStore, request: *const http.Request, allocator: std.mem.Allocator) !http.Response {
    _ = store; // Will be handled via streaming
    // Create a special streaming response marker
    // We'll handle this specially in the server to stream the data
    const marker = try allocator.dupe(u8, "STREAM");
    const response = http.Response.init(.ok, marker, "application/json", request.wantsKeepAlive(), false, null);
    return response;
}

/// Stream the people array with chunked transfer encoding
pub fn streamGetAllResponse(stream: std.net.Stream, store: *playground.PersonStore, allocator: std.mem.Allocator, keep_alive: bool) !void {
    var header_buf: std.ArrayList(u8) = .empty;
    defer header_buf.deinit(allocator);

    // Write headers with chunked encoding
    try std.fmt.format(header_buf.writer(allocator), "HTTP/1.1 200 OK\r\n", .{});
    try std.fmt.format(header_buf.writer(allocator), "Content-Type: application/json\r\n", .{});
    try std.fmt.format(header_buf.writer(allocator), "Transfer-Encoding: chunked\r\n", .{});
    try std.fmt.format(header_buf.writer(allocator), "Cache-Control: no-cache\r\n", .{});

    if (keep_alive) {
        try std.fmt.format(header_buf.writer(allocator), "Connection: keep-alive\r\n", .{});
        try std.fmt.format(header_buf.writer(allocator), "Keep-Alive: timeout=30, max=100\r\n", .{});
    } else {
        try std.fmt.format(header_buf.writer(allocator), "Connection: close\r\n", .{});
    }

    try std.fmt.format(header_buf.writer(allocator), "\r\n", .{});
    try stream.writeAll(header_buf.items);

    // Stream the JSON array
    const all = try store.getAll();

    // Reuse a single buffer for all chunks to avoid repeated allocations
    var chunk_buf: std.ArrayList(u8) = .empty;
    defer chunk_buf.deinit(allocator);

    // Write opening bracket as first chunk
    try http.writeChunk(stream, "[");

    // Write each person as a separate chunk with flush
    for (all, 0..) |person, i| {
        chunk_buf.clearRetainingCapacity();

        if (i > 0) {
            try chunk_buf.appendSlice(allocator, ",");
        }

        try std.fmt.format(chunk_buf.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ person.name, person.age, person.job });

        try http.writeChunk(stream, chunk_buf.items);
    }

    // Write closing bracket
    try http.writeChunk(stream, "]");

    // Send final chunk (0 size) to signal end
    try stream.writeAll("0\r\n\r\n");
}

pub fn handleGetOne(store: *playground.PersonStore, request: *const http.Request, allocator: std.mem.Allocator) !http.Response {
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    const person = try store.get(id);
    if (person) |p| {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);
        try std.fmt.format(buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ p.name, p.age, p.job });

        const response_body = try allocator.dupe(u8, buffer.items);
        var response = http.Response.json(.ok, response_body, request.wantsKeepAlive());
        response.allocator = allocator;
        return response;
    } else {
        return http.Response.json(.not_found, "{\"error\":\"Person not found\"}", request.wantsKeepAlive());
    }
}

pub fn handleCreate(store: *playground.PersonStore, request: *const http.Request, allocator: std.mem.Allocator) !http.Response {
    const parsed = try std.json.parseFromSlice(playground.Person, allocator, request.body, .{});
    defer parsed.deinit();

    const person = parsed.value;
    try store.add(person);

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try std.fmt.format(buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ person.name, person.age, person.job });

    const response_body = try allocator.dupe(u8, buffer.items);
    var response = http.Response.json(.created, response_body, request.wantsKeepAlive());
    response.allocator = allocator;
    return response;
}

pub fn handleUpdate(store: *playground.PersonStore, request: *const http.Request, allocator: std.mem.Allocator) !http.Response {
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    const parsed = try std.json.parseFromSlice(playground.Person, allocator, request.body, .{});
    defer parsed.deinit();

    const person = parsed.value;
    const success = try store.update(id, person);

    if (success) {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);
        try std.fmt.format(buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ person.name, person.age, person.job });

        const response_body = try allocator.dupe(u8, buffer.items);
        var response = http.Response.json(.ok, response_body, request.wantsKeepAlive());
        response.allocator = allocator;
        return response;
    } else {
        return http.Response.json(.not_found, "{\"error\":\"Person not found\"}", request.wantsKeepAlive());
    }
}

pub fn handleDelete(store: *playground.PersonStore, request: *const http.Request, allocator: std.mem.Allocator) !http.Response {
    _ = allocator;
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    const success = try store.delete(id);
    if (success) {
        return http.Response.json(.ok, "{\"message\":\"Deleted\"}", request.wantsKeepAlive());
    } else {
        return http.Response.json(.not_found, "{\"error\":\"Person not found\"}", request.wantsKeepAlive());
    }
}
