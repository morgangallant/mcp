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
        c_accept: xev.Completion,
        connections: std.heap.MemoryPool(Connection),

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
                .c_accept = undefined, // Initialized below
                .connections = std.heap.MemoryPool(Connection).init(gpa),
            };
            try self.startListening();
        }

        pub fn deinit(self: *Server) void {
            std.os.close(self.socket);
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
            errdefer std.os.close(self.socket);
            try std.os.setsockopt(
                self.socket,
                std.os.SOL.SOCKET,
                std.os.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.os.bind(self.socket, &self.addr.any, self.addr.getOsSockLen());
            try std.os.listen(self.socket, 32);

            self.c_accept = .{
                .op = .{
                    .accept = .{ .socket = self.socket },
                },
                .userdata = self,
                .callback = acceptCb,
            };
            self.loop.add(&self.c_accept);
        }

        fn acceptCb(
            ud: ?*anyopaque,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.Result,
        ) xev.CallbackAction {
            const server = @as(*Server, @ptrCast(@alignCast(ud.?)));
            std.debug.assert(l == server.loop);
            std.debug.assert(c == &server.c_accept);
            const sockfd = r.accept catch |err| {
                logger.err("error accepting incoming connection: {s}", .{@errorName(err)});
                return .rearm;
            };
            const conn = server.connections.create() catch |err| {
                std.os.close(sockfd);
                logger.err("failed to allocate connection object: {s}", .{@errorName(err)});
                return .rearm;
            };
            conn.init(server, sockfd);
            logger.info("accepted new connection (fd={d})", .{sockfd});
            return .rearm;
        }

        const Connection = struct {
            server: *Server,
            fd: std.os.socket_t,
            read_buf: [4 << 10]u8, // 4KiB is what Go uses
            read_overlap: usize,
            pending_request: Request,
            responder: ResponseWriter,
            closing: bool,
            cmpl: xev.Completion,

            fn init(self: *Connection, server: *Server, connfd: std.os.socket_t) void {
                self.* = .{
                    .server = server,
                    .fd = connfd,
                    .read_buf = undefined,
                    .read_overlap = 0,
                    .pending_request = undefined, // Initialized below
                    .responder = undefined, // Initialized below
                    .closing = false,
                    .cmpl = undefined, // Initialized by `scheduleNextCompletion`
                };
                self.pending_request.init(server.gpa);
                self.responder.init(server.gpa);
                self.scheduleNextCompletion();
            }

            fn deinit(self: *Connection) void {
                std.debug.assert(self.closing);
                logger.info("closing connection fd={d}", .{self.fd});
                self.pending_request.deinit();
                self.responder.deinit();
                self.server.connections.destroy(self);
            }

            fn scheduleNextCompletion(self: *Connection) void {
                if (self.closing) {
                    self.cmpl = .{
                        .op = .{ .close = .{ .fd = self.fd } },
                        .userdata = self,
                        .callback = closeCallback,
                    };
                } else if (self.pending_request.stage == .ready) {
                    const sent = self.responder.sent_bytes;
                    const preamble_len = self.responder.preamble.items.len;
                    const body_len = self.responder.body.items.len;
                    if (sent < preamble_len) {
                        const slice = self.responder.preamble.items[sent..];
                        self.cmpl = .{
                            .op = .{
                                .send = .{
                                    .fd = self.fd,
                                    .buffer = .{
                                        .slice = slice,
                                    },
                                },
                            },
                            .userdata = self,
                            .callback = writeCallback,
                        };
                    } else if (sent < preamble_len + body_len) {
                        const offset = sent - preamble_len;
                        const slice = self.responder.body.items[offset..];
                        self.cmpl = .{
                            .op = .{
                                .send = .{
                                    .fd = self.fd,
                                    .buffer = .{ .slice = slice },
                                },
                            },
                            .userdata = self,
                            .callback = writeCallback,
                        };
                    } else {
                        std.debug.assert(sent == preamble_len + body_len);
                        if (!self.pending_request.head.keep_alive) {
                            self.closing = true;
                        }
                        self.pending_request.reset();
                        self.responder.reset();
                        self.scheduleNextCompletion();
                        return;
                    }
                } else {
                    const buf = self.read_buf[self.read_overlap..];
                    self.cmpl = .{
                        .op = .{
                            .recv = .{
                                .fd = self.fd,
                                .buffer = .{ .slice = buf },
                            },
                        },
                        .userdata = self,
                        .callback = readCallback,
                    };
                }
                self.server.loop.add(&self.cmpl);
            }

            fn closeCallback(
                ud: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                _ = r.close catch |err| {
                    logger.warn(
                        "failed to close socket fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                };
                self.deinit();
                return .disarm;
            }

            fn readCallback(
                ud: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                defer self.scheduleNextCompletion();

                var got = r.recv catch |err| {
                    if (err != error.EOF) {
                        logger.err(
                            "recv() failed on socket fd={d}: {s}",
                            .{ self.fd, @errorName(err) },
                        );
                    }
                    self.closing = true;
                    return .disarm;
                };
                got += self.read_overlap;
                self.read_overlap = 0;

                const consumed = self.pending_request.consume(self.read_buf[0..got]) catch |err| {
                    logger.err(
                        "failed to consume stream on fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.closing = true;
                    return .disarm;
                };

                const remaining = got - consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, &self.read_buf, self.read_buf[consumed..got]);
                    self.read_overlap = remaining;
                }

                if (self.pending_request.stage == .ready) {
                    self.processReadyRequest() catch |err| {
                        logger.err(
                            "failed to process request on fd={d}: {s}",
                            .{ self.fd, @errorName(err) },
                        );
                        self.closing = true;
                    };
                }

                return .disarm;
            }

            fn processReadyRequest(self: *Connection) !void {
                std.debug.assert(self.pending_request.stage == .ready);

                handlerFn(self.server.ctx, &self.responder, &self.pending_request) catch |err| {
                    self.responder.setStatus(.internal_server_error);
                    self.responder.body.clearAndFree();
                    try self.responder.writer().writeAll("an internal server error occured");
                    logger.err(
                        "request handler failed (fd={d}): {s}",
                        .{ self.fd, @errorName(err) },
                    );
                };

                try self.responder.finalize(&self.pending_request);
            }

            fn writeCallback(
                ud: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                defer self.scheduleNextCompletion();

                const wrote = r.send catch |err| {
                    logger.err(
                        "send() failed on socket fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.closing = true;
                    return .disarm;
                };
                self.responder.sent_bytes += wrote;

                return .disarm;
            }
        };
    };
}

pub const Request = struct {
    head: std.http.Server.Request.Head,
    stage: enum { head, body, ready },
    read_buffer: std.ArrayList(u8),
    headers_end: usize,

    fn init(self: *Request, alloc: std.mem.Allocator) void {
        self.* = .{
            .head = undefined, // Set in `consume`
            .stage = .head,
            .read_buffer = std.ArrayList(u8).init(alloc),
            .headers_end = undefined, // Set once stage reaches body
        };
    }

    fn deinit(self: *Request) void {
        self.read_buffer.deinit();
        self.* = undefined;
    }

    fn reset(self: *Request) void {
        self.head = undefined;
        self.stage = .head;
        self.read_buffer.clearRetainingCapacity();
        self.headers_end = undefined;
    }

    pub fn consume(self: *Request, stream: []const u8) !usize {
        var consumed: usize = 0;
        outer: while (consumed < stream.len) {
            switch (self.stage) {
                .ready => break :outer,
                .body => {
                    const remaining = if (self.head.content_length) |cl|
                        cl - self.body().len
                    else
                        0;
                    const take = @min(remaining, stream.len - consumed);
                    if (take > 0) {
                        try self.read_buffer.appendSlice(stream[consumed .. consumed + take]);
                        consumed += take;
                    }
                    if (remaining - take == 0) self.stage = .ready;
                },
                .head => {
                    const remaining = stream[consumed..];
                    const take = if (std.mem.indexOf(u8, remaining, "\r\n\r\n")) |stop| blk: {
                        self.stage = .body;
                        break :blk stop + 4;
                    } else remaining.len;
                    try self.read_buffer.appendSlice(remaining[0..take]);
                    if (self.stage == .body) {
                        self.head = try std.http.Server.Request.Head.parse(self.read_buffer.items);
                        self.headers_end = self.read_buffer.items.len;
                        if ((self.head.content_length orelse 0) == 0) {
                            self.stage = .ready;
                        }
                    }
                    consumed += take;
                },
            }
        }
        return consumed;
    }

    pub fn iterateHeaders(self: *Request) std.http.HeaderIterator {
        return std.http.HeaderIterator.init(self.read_buffer[0..self.headers_end]);
    }

    pub fn body(self: *const Request) []const u8 {
        std.debug.assert(self.stage != .head);
        return self.read_buffer.items[self.headers_end..];
    }
};

pub const ResponseWriter = struct {
    options: std.http.Server.Request.RespondOptions,
    preamble: std.ArrayList(u8),
    body: std.ArrayList(u8),
    sent_bytes: usize,

    fn init(self: *ResponseWriter, alloc: std.mem.Allocator) void {
        self.* = .{
            .options = .{},
            .preamble = std.ArrayList(u8).init(alloc),
            .body = std.ArrayList(u8).init(alloc),
            .sent_bytes = 0,
        };
    }

    fn deinit(self: *ResponseWriter) void {
        self.preamble.deinit();
        self.body.deinit();
        self.* = undefined;
    }

    fn reset(self: *ResponseWriter) void {
        self.preamble.clearRetainingCapacity();
        self.body.clearAndFree();
        self.sent_bytes = 0;
    }

    fn finalize(self: *ResponseWriter, request: *const Request) !void {
        std.debug.assert(self.preamble.items.len == 0);
        const w = self.preamble.writer();

        try w.print(
            "{s} {d} {s}\r\n",
            .{
                @tagName(self.options.version),
                @intFromEnum(self.options.status),
                self.options.reason orelse self.options.status.phrase() orelse "",
            },
        );

        switch (self.options.version) {
            .@"HTTP/1.0" => if (request.head.keep_alive) try w.writeAll("connection: keep-alive\r\n"),
            .@"HTTP/1.1" => if (!request.head.keep_alive) try w.writeAll("connection: close\r\n"),
        }

        if (self.options.transfer_encoding) |transfer_encoding| switch (transfer_encoding) {
            .none => {},
            .chunked => try w.writeAll("transfer-encoding: chunked\r\n"),
        } else {
            try w.print("content-length: {d}\r\n", .{self.body.items.len});
        }

        var server_header = false;
        for (self.options.extra_headers) |header| {
            try w.print("{s}: {s}\r\n", .{ header.name, header.value });
            if (std.ascii.eqlIgnoreCase(header.name, "server")) {
                server_header = true;
            }
        }
        if (!server_header) {
            try w.writeAll("server: mcp\r\n");
        }
        try w.writeAll("\r\n");

        if (request.head.method == .HEAD) {
            self.body.clearAndFree();
        }
    }

    pub fn setStatus(self: *ResponseWriter, status: std.http.Status) void {
        self.options.status = status;
        if (status.phrase()) |phrase| {
            self.options.reason = phrase;
        }
    }

    pub fn writer(self: *ResponseWriter) std.ArrayList(u8).Writer {
        return self.body.writer();
    }
};
