const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    UNKNOWN,

    pub fn fromString(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return .UNKNOWN;
    }
};

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    bad_request = 400,
    not_found = 404,
    internal_server_error = 500,

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .bad_request => "Bad Request",
            .not_found => "Not Found",
            .internal_server_error => "Internal Server Error",
        };
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, raw_data: []const u8) !Request {
        var headers = std.StringHashMap([]const u8).init(allocator);
        errdefer headers.deinit();

        // Parse request line
        var lines = std.mem.splitSequence(u8, raw_data, "\r\n");
        const request_line = lines.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method_str = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        // Parse headers
        while (lines.next()) |line| {
            if (line.len == 0) break; // End of headers

            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const key = line[0..colon_pos];
                const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                try headers.put(key, value);
            }
        }

        // Find body
        const body_start = std.mem.indexOf(u8, raw_data, "\r\n\r\n");
        const body = if (body_start) |start| raw_data[start + 4 ..] else "";

        return Request{
            .method = Method.fromString(method_str),
            .path = path,
            .body = body,
            .headers = headers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn wantsKeepAlive(self: *const Request) bool {
        if (self.headers.get("Connection")) |value| {
            return std.ascii.eqlIgnoreCase(value, "keep-alive");
        }
        return true; // HTTP/1.1 default
    }

    pub fn shouldClose(self: *const Request) bool {
        if (self.headers.get("Connection")) |value| {
            return std.ascii.eqlIgnoreCase(value, "close");
        }
        return false;
    }
};

pub const Response = struct {
    status: Status,
    body: []const u8,
    content_type: []const u8,
    keep_alive: bool,
    owns_body: bool,
    allocator: ?std.mem.Allocator,

    pub fn init(status: Status, body: []const u8, content_type: []const u8, keep_alive: bool, owns_body: bool, allocator: ?std.mem.Allocator) Response {
        return .{
            .status = status,
            .body = body,
            .content_type = content_type,
            .keep_alive = keep_alive,
            .owns_body = owns_body,
            .allocator = allocator,
        };
    }

    pub fn json(status: Status, body: []const u8, keep_alive: bool) Response {
        return init(status, body, "application/json", keep_alive, true, null);
    }

    pub fn text(status: Status, body: []const u8, keep_alive: bool) Response {
        return init(status, body, "text/plain", keep_alive, false, null);
    }

    pub fn deinit(self: *Response) void {
        if (self.owns_body) {
            if (self.allocator) |alloc| {
                alloc.free(self.body);
            }
        }
    }

    pub fn write(self: Response, allocator: std.mem.Allocator, stream: std.net.Stream) !void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        try std.fmt.format(buffer.writer(allocator), "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), self.status.text() });
        try std.fmt.format(buffer.writer(allocator), "Content-Type: {s}\r\n", .{self.content_type});
        try std.fmt.format(buffer.writer(allocator), "Content-Length: {d}\r\n", .{self.body.len});
        try std.fmt.format(buffer.writer(allocator), "Cache-Control: no-cache\r\n", .{});

        if (self.keep_alive) {
            try std.fmt.format(buffer.writer(allocator), "Connection: keep-alive\r\n", .{});
            try std.fmt.format(buffer.writer(allocator), "Keep-Alive: timeout=30, max=100\r\n", .{});
        } else {
            try std.fmt.format(buffer.writer(allocator), "Connection: close\r\n", .{});
        }

        try std.fmt.format(buffer.writer(allocator), "\r\n", .{});
        try buffer.appendSlice(allocator, self.body);

        try stream.writeAll(buffer.items);
    }
};

/// Write a chunk in chunked transfer encoding format
pub fn writeChunk(stream: std.net.Stream, data: []const u8) !void {
    var size_buf: [32]u8 = undefined;
    const size_str = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len});
    try stream.writeAll(size_str);
    try stream.writeAll(data);
    try stream.writeAll("\r\n");
}

pub fn readRequest(stream: std.net.Stream, buffer: []u8, timeout_ms: i32) !usize {
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        // Poll for data
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = try std.posix.poll(&poll_fds, timeout_ms);
        if (poll_result == 0) {
            if (total_read > 0) break;
            return error.Timeout;
        }

        if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
            break;
        }

        const bytes_read = stream.read(buffer[total_read..]) catch |err| {
            if (err == error.WouldBlock) {
                if (total_read > 0) break;
                continue;
            }
            return err;
        };

        if (bytes_read == 0) {
            if (total_read == 0) return error.ConnectionClosed;
            break;
        }

        total_read += bytes_read;

        // Check if we have complete headers
        if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |_| {
            break;
        }

        // Quick check for more data
        var check_poll = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const more_data = try std.posix.poll(&check_poll, 10);
        if (more_data == 0) break;
    }

    return total_read;
}
