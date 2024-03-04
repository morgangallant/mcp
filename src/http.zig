const std = @import("std");
const stdx = @import("stdx.zig");
const xev = @import("xev");

const logger = std.log.scoped(.http);

// A high-performance HTTP server built atop libxev.
pub fn ServerType(
    comptime context: type,
    comptime errType: type,
    comptime handlerFn: fn (context, *ResponseWriter, *const Request) errType!void,
) type {
    return struct {
        const Server = @This();

        ctx: context,
        gpa: std.mem.Allocator,
        addr: std.net.Address,
        loop: *xev.Loop,
        socket: std.os.socket_t,
        accept_cpl: xev.Completion,
        connections: ConcurrentMemoryPoolType(Connection),

        pub fn init(
            self: *Server,
            ctx: context,
            gpa: std.mem.Allocator,
            addr: std.net.Address,
            loop: *xev.Loop,
        ) !void {
            self.* = .{
                .ctx = ctx,
                .gpa = gpa,
                .addr = addr,
                .loop = loop,
                .socket = undefined, // Initialized below
                .accept_cpl = undefined, // Initialized below
                .connections = ConcurrentMemoryPoolType(Connection).init(gpa),
            };
            try self.startListening();
        }

        pub fn deinit(self: *Server) void {
            std.os.closeSocket(self.socket);
            self.connections.deinit();
            self.* = undefined;
        }

        fn startListening(self: *Server) !void {
            const flags = blk: {
                var flags: u32 = std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC;
                if (xev.backend != .io_uring) flags |= std.os.SOCK.NONBLOCK;
                break :blk flags;
            };

            self.socket = try std.os.socket(
                std.os.AF.INET,
                flags,
                std.os.IPPROTO.TCP,
            );
            errdefer std.os.closeSocket(self.socket);
            try std.os.setsockopt(
                self.socket,
                std.os.SOL.SOCKET,
                std.os.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.os.bind(self.socket, &self.addr.any, self.addr.getOsSockLen());
            try std.os.listen(self.socket, 32);

            self.accept_cpl = .{
                .op = .{
                    .accept = .{ .socket = self.socket },
                },
                .userdata = self,
                .callback = accept_cb,
            };
            self.loop.add(&self.accept_cpl);
        }

        fn accept_cb(
            ud: ?*anyopaque,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            const server = @as(*Server, @ptrCast(@alignCast(ud.?)));
            const sockfd = r.accept catch |err| {
                logger.err("accepting incoming connection: {s}", .{@errorName(err)});
                return .rearm;
            };
            const conn = server.connections.create() catch |err| {
                std.os.closeSocket(sockfd);
                logger.err("failed to allocate connection object: {s}", .{@errorName(err)});
                return .rearm;
            };
            conn.init(server, sockfd);
            logger.debug("accepted new connection (fd={d})", .{sockfd});
            return .rearm;
        }

        const Connection = struct {
            server: *Server,
            fd: std.os.socket_t,
            read_buf: [4 << 10]u8 = undefined, // 4KiB is what Go uses
            read_overlap: usize = 0,
            cpl: union(enum) {
                reading: xev.Completion,
                writing: xev.Completion,
                closing: xev.Completion,
            },
            request: Request,
            responder: ResponseWriter,

            fn init(self: *Connection, server: *Server, connfd: std.os.socket_t) void {
                self.* = .{
                    .server = server,
                    .fd = connfd,
                    .cpl = undefined, // Initialized below
                    .request = undefined, // Initialized below
                    .responder = undefined, // Initialized below
                };
                self.request.init(server.gpa);
                self.responder.init(server.gpa);
                self.scheduleRead(&self.read_buf);
            }

            fn scheduleClose(self: *Connection) void {
                logger.debug("closing connection fd={d}", .{self.fd});
                self.cpl = .{
                    .closing = .{
                        .op = .{ .close = .{ .fd = self.fd } },
                        .userdata = self,
                        .callback = close_cb,
                    },
                };
                self.server.loop.add(&self.cpl.closing);
            }

            fn close_cb(
                ud: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const conn = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                _ = r.close catch |err| {
                    logger.warn(
                        "error occured while closing socket fd={d}: {s}",
                        .{ conn.fd, @errorName(err) },
                    );
                };
                conn.request.reset();
                conn.server.connections.destroy(conn);
                return .disarm;
            }

            fn scheduleRead(self: *Connection, dst: []u8) void {
                self.cpl = .{
                    .reading = .{
                        .op = .{
                            .recv = .{
                                .fd = self.fd,
                                .buffer = .{ .slice = dst },
                            },
                        },
                        .userdata = self,
                        .callback = read_cb,
                    },
                };
                self.server.loop.add(&self.cpl.reading);
            }

            fn read_cb(
                ud: ?*anyopaque,
                _: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const conn = @as(*Connection, @ptrCast(@alignCast(ud.?)));

                var got = r.recv catch |err| switch (err) {
                    error.EOF => {
                        conn.scheduleClose();
                        return .disarm;
                    },
                    else => {
                        logger.err(
                            "recv() failed, socket fd={d}: {s}",
                            .{ conn.fd, @errorName(err) },
                        );
                        conn.scheduleClose();
                        return .disarm;
                    },
                };
                if (conn.read_overlap > 0) {
                    got += conn.read_overlap;
                    conn.read_overlap = 0;
                }

                const consumed = conn.request.consumeStream(conn.read_buf[0..got]) catch |err| {
                    logger.err(
                        "failed to consume stream on fd={d}: {s}",
                        .{ conn.fd, @errorName(err) },
                    );
                    conn.scheduleClose();
                    return .disarm;
                };
                logger.debug("consumed {d} bytes on fd={d}", .{ consumed, conn.fd });

                const remaining = got - consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, &conn.read_buf, conn.read_buf[consumed..got]);
                    conn.read_overlap = remaining;
                }

                logger.debug(
                    "remaining={d},stage={s}",
                    .{ remaining, @tagName(conn.request.stage) },
                );

                if (conn.request.stage == .ready) {
                    conn.onRequestReady() catch |err| {
                        logger.err(
                            "failed to handle request on fd={d}: {s}",
                            .{ conn.fd, @errorName(err) },
                        );
                        conn.scheduleClose();
                    };
                    return .disarm;
                }

                c.op.recv.buffer.slice = conn.read_buf[conn.read_overlap..];

                return .rearm;
            }

            fn onRequestReady(self: *Connection) !void {
                std.debug.assert(self.request.stage == .ready);
                logger.debug("invoking handler function for fd={d}", .{self.fd});
                handlerFn(self.server.ctx, &self.responder, &self.request) catch |err| {
                    self.responder.status = .internal_server_error;
                    self.responder.body.clearRetainingCapacity();
                    try self.responder.body.appendSlice("an internal server error occured");
                    logger.err(
                        "request handler on fd={d} returned error {s}",
                        .{ self.fd, @errorName(err) },
                    );
                };

                const w = self.responder.preamble.writer();

                const version: std.http.Version = .@"HTTP/1.1";
                try w.writeAll(@tagName(version));
                try w.print(" {d} ", .{@intFromEnum(self.responder.status)});
                if (self.responder.status.phrase()) |phrase| {
                    try w.writeAll(phrase);
                }
                try w.writeAll("\r\n");

                if (!self.responder.headers.contains("server")) {
                    try w.writeAll("Server: lstd\r\n");
                }

                if (!self.responder.headers.contains("connection")) {
                    const req_connection = self.request.headers.getFirstValue("connection");
                    const req_keepalive = req_connection != null and
                        !std.ascii.eqlIgnoreCase("close", req_connection.?);
                    if (req_keepalive) {
                        try w.writeAll("Connection: keep-alive\r\n");
                    } else {
                        try w.writeAll("Connection: close\r\n");
                    }
                }

                if (self.responder.headers.getFirstValue("content-length")) |cl| {
                    const parsed = try std.fmt.parseInt(usize, cl, 10);
                    std.debug.assert(parsed == self.responder.body.items.len);
                } else {
                    const length = self.responder.body.items.len;
                    if (length > 0) try w.print("Content-Length: {d}\r\n", .{length});
                }

                try w.print("{}", .{self.responder.headers});

                try w.writeAll("\r\n");

                if (self.request.method == .HEAD) {
                    self.responder.body.clearAndFree();
                }

                self.request.reset();

                self.scheduleWrite();
            }

            fn scheduleWrite(self: *Connection) void {
                self.cpl = .{
                    .writing = .{
                        .op = .{
                            .send = .{
                                .fd = self.fd,
                                .buffer = .{ .slice = self.responder.preamble.items },
                            },
                        },
                        .userdata = self,
                        .callback = write_cb,
                    },
                };
                self.server.loop.add(&self.cpl.writing);
            }

            fn write_cb(
                ud: ?*anyopaque,
                _: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const conn = @as(*Connection, @ptrCast(@alignCast(ud.?)));

                const wrote = r.send catch |err| {
                    logger.err(
                        "send() failed on socket fd={d}: {s}",
                        .{ conn.fd, @errorName(err) },
                    );
                    conn.scheduleClose();
                    return .disarm;
                };
                conn.responder.sent += wrote;

                const preamble_len = conn.responder.preamble.items.len;
                const body_len = conn.responder.body.items.len;
                if (conn.responder.sent < preamble_len) {
                    c.op.send.buffer.slice = conn.responder.preamble.items[conn.responder.sent..];
                    return .rearm;
                } else if (conn.responder.sent < preamble_len + body_len) {
                    const offset = conn.responder.sent - preamble_len;
                    c.op.send.buffer.slice = conn.responder.body.items[offset..];
                    return .rearm;
                }
                std.debug.assert(conn.responder.sent == preamble_len + body_len);
                conn.responder.reset();
                conn.scheduleRead(conn.read_buf[conn.read_overlap..]);
                return .disarm;
            }
        };
    };
}

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    version: std.http.Version,
    content_length: ?u64,
    headers: std.http.Headers,
    transfer_encoding: std.http.TransferEncoding,
    transfer_compression: std.http.ContentEncoding,

    stage: enum { start, headers, body, ready },
    body: std.ArrayList(u8),

    fn init(self: *Request, gpa: std.mem.Allocator) void {
        self.* = .{
            .method = undefined,
            .target = undefined,
            .version = undefined,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .headers = .{
                .allocator = gpa,
                .owned = true,
            },
            .stage = .start,
            .body = std.ArrayList(u8).init(gpa),
        };
    }

    fn reset(self: *Request) void {
        self.method = undefined;
        self.target = undefined;
        self.version = undefined;
        self.content_length = null;
        self.headers.clearAndFree();
        self.transfer_encoding = .none;
        self.transfer_compression = .identity;
        self.stage = .start;
        self.body.clearAndFree();
    }

    fn consumeStream(self: *Request, incoming: []const u8) !usize {
        std.debug.assert(self.stage != .ready);
        var consumed: usize = 0;
        outer: while (incoming.len - consumed > 0) {
            if (self.stage == .body) {
                const remaining = if (self.content_length) |cl|
                    cl - self.body.items.len
                else
                    0;
                const take = @min(remaining, incoming.len);
                if (take > 0) {
                    try self.body.appendSlice(incoming[0..take]);
                    consumed += take;
                }
                if (remaining - take == 0) self.stage = .ready;
                break;
            }
            var buffer = incoming;
            var index = std.mem.indexOf(u8, buffer, "\r\n");
            while (index) |end| {
                consumed += 2;
                const entry = buffer[0..end];
                if (entry.len == 0) {
                    if (self.stage != .headers) return error.InvalidRequest;
                    if (self.content_length) |_| {
                        self.stage = .body;
                        continue :outer;
                    }
                    self.stage = .ready;
                    break :outer;
                }
                consumed += entry.len;
                try self.parseLine(entry);
                buffer = buffer[end + 2 ..];
                index = std.mem.indexOf(u8, buffer, "\r\n");
            }
            break;
        }
        return consumed;
    }

    fn parseLine(self: *Request, line: []const u8) !void {
        std.debug.assert(line.len > 0);
        switch (self.stage) {
            .start => {
                if (line.len < 10) return error.InvalidRequest;

                const method_end = std.mem.indexOfScalar(u8, line, ' ');
                if (method_end == null or method_end.? > 24) return error.InvalidRequest;

                const version_start = std.mem.lastIndexOfScalar(u8, line, ' ');
                if (version_start == null or version_start == method_end.?)
                    return error.InvalidRequest;
                const version_str = line[version_start.? + 1 ..];

                self.method = @as(
                    std.http.Method,
                    @enumFromInt(std.http.Method.parse(line[0..method_end.?])),
                );
                self.target = line[method_end.? + 1 .. version_start.?];
                self.version = if (stdx.eqlComptime(u8, version_str, "HTTP/1.0"))
                    .@"HTTP/1.0"
                else if (stdx.eqlComptime(u8, version_str, "HTTP/1.1"))
                    .@"HTTP/1.1"
                else
                    return error.InvalidRequest;

                self.stage = .headers;
            },
            .headers => {
                switch (line[0]) {
                    ' ', '\t' => return error.HeaderContinuationsUnsupported,
                    else => {},
                }

                var iter = std.mem.tokenizeAny(u8, line, ": ");
                const name = iter.next() orelse return error.InvalidHeader;
                const value = iter.rest();

                try self.appendHeader(name, value);
            },
            else => unreachable,
        }
    }

    fn appendHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.headers.append(name, value);

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (self.content_length != null) return error.InvalidHeader;
            self.content_length = std.fmt.parseInt(u8, value, 10) catch {
                return error.InvalidContentLength;
            };
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            var components = std.mem.splitBackwardsScalar(u8, value, ',');

            const first = components.first();
            const trimmed_first = std.mem.trim(u8, first, " ");

            var next: ?[]const u8 = first;
            if (std.meta.stringToEnum(std.http.TransferEncoding, trimmed_first)) |transfer| {
                if (self.transfer_encoding != .none) return error.InvalidHeader;
                self.transfer_encoding = transfer;
                next = components.next();
            }

            if (next) |second| {
                const trimmed_second = std.mem.trim(u8, second, " ");
                if (std.meta.stringToEnum(std.http.ContentEncoding, trimmed_second)) |content| {
                    if (self.transfer_compression != .identity) return error.InvalidHeader;
                    self.transfer_compression = content;
                } else {
                    return error.UnsupportedTransferEncoding;
                }
            }

            if (components.next()) |_| return error.UnsupportedTransferEncoding;
        } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
            if (self.transfer_compression != .identity) return error.InvalidHeader;
            const trimmed = std.mem.trim(u8, value, " ");
            if (std.meta.stringToEnum(std.http.ContentEncoding, trimmed)) |content| {
                self.transfer_compression = content;
            } else {
                return error.UnsupportedTransferEncoding;
            }
        }
    }
};

pub const ResponseWriter = struct {
    status: std.http.Status,
    headers: std.http.Headers,
    body: std.ArrayList(u8),
    preamble: std.ArrayList(u8),
    sent: usize,

    fn init(self: *ResponseWriter, gpa: std.mem.Allocator) void {
        self.* = .{
            .status = .ok,
            .headers = .{
                .allocator = gpa,
                .owned = true,
            },
            .body = std.ArrayList(u8).init(gpa),
            .preamble = std.ArrayList(u8).init(gpa),
            .sent = 0,
        };
    }

    fn deinit(self: *ResponseWriter) void {
        self.headers.clearAndFree();
        self.body.deinit();
        self.preamble.deinit();
        self.* = undefined;
    }

    fn reset(self: *ResponseWriter) void {
        self.status = .ok;
        self.headers.clearAndFree();
        self.body.clearAndFree();
        self.preamble.clearAndFree();
        self.sent = 0;
    }
};

fn ConcurrentMemoryPoolType(comptime T: type) type {
    return struct {
        const Self = @This();
        const InnerType = std.heap.MemoryPool(T);

        inner: InnerType,
        lock: std.Thread.Mutex,

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .inner = InnerType.init(allocator),
                .lock = .{},
            };
        }

        fn deinit(self: *Self) void {
            self.inner.deinit();
            self.* = undefined;
        }

        const ItemPtr = *align(InnerType.item_alignment) T;

        fn create(self: *Self) !ItemPtr {
            self.lock.lock();
            defer self.lock.unlock();
            return try self.inner.create();
        }

        fn destroy(self: *Self, ptr: ItemPtr) void {
            self.lock.lock();
            defer self.lock.unlock();
            return self.inner.destroy(ptr);
        }
    };
}
