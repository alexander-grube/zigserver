const std = @import("std");
const http = @import("./http.zig");
const playground = @import("playground");
const pg = @import("pg");

pub const RouteHandler = *const fn (*const http.Request, std.mem.Allocator, *pg.Pool) anyerror!http.Response;

pub const Route = struct {
    method: http.Method,
    pattern: []const u8,
    handler: RouteHandler,
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,
    pool: *pg.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *pg.Pool) Router {
        return .{
            .routes = .empty,
            .allocator = allocator,
            .pool = pool,
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
                return r.handler(request, self.allocator, self.pool);
            }

            // Pattern match (e.g., /people/:id)
            if (matchPattern(r.pattern, request.path)) {
                return r.handler(request, self.allocator, self.pool);
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
pub fn handleGetAll(request: *const http.Request, allocator: std.mem.Allocator, pool: *pg.Pool) !http.Response {
    _ = pool; // Will be handled via streaming
    // Create a special streaming response marker
    // We'll handle this specially in the server to stream the data
    const marker = try allocator.dupe(u8, "STREAM");
    const response = http.Response.init(.ok, marker, "application/json", request.wantsKeepAlive(), false, null);
    return response;
}

/// Stream the people array with chunked transfer encoding
pub fn streamGetAllResponse(stream: std.net.Stream, pool: *pg.Pool, allocator: std.mem.Allocator, keep_alive: bool) !void {
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
    const result = try pool.query("SELECT name, age, job FROM people", .{});
    defer result.deinit();

    // Reuse a single buffer for all chunks to avoid repeated allocations
    var chunk_buf: std.ArrayList(u8) = .empty;
    defer chunk_buf.deinit(allocator);

    // Write opening bracket as first chunk
    try http.writeChunk(stream, "[");

    var is_first = true;

    // Write each person as a separate chunk with flush
    while (try result.next()) |row| {
        const name = row.get([]u8, 0);
        const age = row.get(i32, 1);
        const job = row.get([]u8, 2);

        chunk_buf.clearRetainingCapacity();

        if (!is_first) {
            try chunk_buf.appendSlice(allocator, ",");
        }

        try std.fmt.format(chunk_buf.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ name, age, job });

        try http.writeChunk(stream, chunk_buf.items);
        is_first = false;
    }

    // Write closing bracket
    try http.writeChunk(stream, "]");

    // Send final chunk (0 size) to signal end
    try stream.writeAll("0\r\n\r\n");
}

pub fn handleGetOne(request: *const http.Request, allocator: std.mem.Allocator, pool: *pg.Pool) !http.Response {
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    var result = try pool.query("SELECT name, age, job FROM people WHERE id = $1", .{id});
    defer result.deinit();
    while (try result.next()) |row| {
        const name = row.get([]u8, 0);
        const age = row.get(i32, 1);
        const job = row.get([]u8, 2);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);
        try std.fmt.format(buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ name, age, job });
        const response_body = try allocator.dupe(u8, buffer.items);
        var response = http.Response.json(.ok, response_body, request.wantsKeepAlive());
        response.allocator = allocator;
        return response;
    } else {
        return http.Response.json(.not_found, "{\"error\":\"Person not found\"}", request.wantsKeepAlive());
    }
}

pub fn handleCreate(request: *const http.Request, allocator: std.mem.Allocator, pool: *pg.Pool) !http.Response {
    const parsed = try std.json.parseFromSlice(playground.Person, allocator, request.body, .{});
    defer parsed.deinit();

    const person = parsed.value;
    _ = try pool.exec("INSERT INTO people (name, age, job) VALUES ($1, $2, $3) RETURNING id", .{ person.name, person.age, person.job });

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try std.fmt.format(buffer.writer(allocator), "{{\"name\":\"{s}\",\"age\":{d},\"job\":\"{s}\"}}", .{ person.name, person.age, person.job });

    const response_body = try allocator.dupe(u8, buffer.items);
    var response = http.Response.json(.created, response_body, request.wantsKeepAlive());
    response.allocator = allocator;
    return response;
}

pub fn handleUpdate(request: *const http.Request, allocator: std.mem.Allocator, pool: *pg.Pool) !http.Response {
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    const parsed = try std.json.parseFromSlice(playground.Person, allocator, request.body, .{});
    defer parsed.deinit();

    const person = parsed.value;

    const success = try pool.exec("UPDATE people SET name = $1, age = $2, job = $3 WHERE id = $4", .{ person.name, person.age, person.job, id }) orelse 0 > 0;

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

pub fn handleDelete(request: *const http.Request, allocator: std.mem.Allocator, pool: *pg.Pool) !http.Response {
    _ = allocator;
    const id = extractId(request.path) orelse return http.Response.json(.bad_request, "{\"error\":\"Invalid ID\"}", request.wantsKeepAlive());

    const success = try pool.exec("DELETE FROM people WHERE id = $1", .{id}) orelse 0 > 0;
    if (success) {
        return http.Response.json(.ok, "{\"message\":\"Deleted\"}", request.wantsKeepAlive());
    } else {
        return http.Response.json(.not_found, "{\"error\":\"Person not found\"}", request.wantsKeepAlive());
    }
}
