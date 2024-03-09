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
                std.os.closeSocket(sockfd);
                logger.err("failed to allocate connection object: {s}", .{@errorName(err)});
                return .rearm;
            };
            conn.init(server, sockfd) catch |err| {
                server.connections.destroy(conn);
                std.os.closeSocket(sockfd);
                logger.err("failed to init connection object: {s}", .{@errorName(err)});
                return .rearm;
            };
            logger.into("accepted new connection (fd={d})", .{sockfd});
            return .rearm;
        }

        const Connection = struct {
            server: *Server,
            fd: std.os.socket_t,
            read_buf: [4 << 10]u8, // 4KiB is what Go uses
            read_overlap: usize,
            request_queue: FifoType,
            pending_request: Request,
            responder: ResponseWriter,

            c_reading: xev.Completion,
            c_writing: xev.Completion,
            c_closing: ?xev.Completion,

            c_writing_wakeup: xev.Completion,
            writing_wakeup: xev.Async,

            c_reading_wakeup: xev.Completion,
            reading_wakeup: xev.Async,

            const fifo_length = 3;
            const FifoType = std.fifo.LinearFifo(Request, .{ .Static = fifo_length });

            fn init(self: *Connection, server: *Server, fd: std.os.socket_t) !void {
                self.* = .{
                    .server = server,
                    .fd = fd,
                    .read_buf = undefined,
                    .read_overlap = 0,
                    .request_queue = FifoType.init(),
                    .pending_request = undefined, // Initialized below
                    .responder = undefined, // Initialized below
                    .c_reading = .{
                        .op = .{
                            .recv = .{
                                .fd = fd,
                                .buffer = .{ .slice = &self.read_buf },
                            },
                        },
                        .userdata = self,
                        .callback = readCb,
                    },
                    .c_writing = undefined, // Not initialized yet
                    .c_closing = null,
                    .c_writing_wakeup = undefined,
                    .writing_wakeup = try xev.Async.init(),
                };
                self.pending_request.init(server.gpa);
                self.responder.init(server.gpa);
                self.writing_wakeup.wait(
                    self.server.loop,
                    &self.c_writing_wakeup,
                    Connection,
                    self,
                    writingWakeupCb,
                );
                self.server.loop.add(&self.c_reading);
            }

            fn deinit(self: *Connection) void {
                logger.info("closing connection fd={d}", .{self.fd});
                self.pending_request.reset();
                var queued: ?Request = self.request_queue.readItem();
                while (queued) |*q| {
                    q.reset();
                    queued = self.request_queue.readItem();
                }
                self.responder.deinit();
                self.writing_wakeup.deinit();
                self.server.connections.destroy(self);
            }

            fn closeCb(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                std.debug.assert(l == self.server.loop);
                std.debug.assert(c == &self.c_closing.?);
                _ = r.close catch |err| {
                    logger.warn(
                        "failed to close socket fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                };
                self.deinit();
                return .disarm;
            }

            fn scheduleClose(self: *Connection) void {
                if (self.c_closing != null) return;
                self.c_closing = .{
                    .op = .{ .close = .{ .fd = self.fd } },
                    .userdata = self,
                    .callback = closeCb,
                };
                self.server.loop.add(&self.c_closing.?);
            }

            fn readCb(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                std.debug.assert(l == self.server.loop);
                std.debug.assert(c == &self.c_reading);
                std.debug.assert(self.request_queue.readableLength() < fifo_length);

                var got = r.recv catch |err| {
                    if (err != error.EOF) {
                        logger.err(
                            "recv() failed on socket fd={d}: {s}",
                            .{ self.fd, @errorName(err) },
                        );
                    }
                    self.scheduleClose();
                    return .disarm;
                };
                got += self.read_overlap;
                self.read_overlap = 0;

                const consumed = self.pending_request.consumeStream(
                    self.read_buf[0..got],
                ) catch |err| {
                    logger.err(
                        "failed to consume stream on fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.scheduleClose();
                    return .disarm;
                };

                const remaining = got - consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, &self.read_buf, self.read_buf[consumed..got]);
                    self.read_overlap = remaining;
                }

                c.op.recv.buffer.slice = self.read_buf[self.read_overlap..];

                if (self.pending_request.stage == .ready) {
                    const before = self.request_queue.readableLength();
                    self.request_queue.writeItem(self.pending_request) catch unreachable;
                    self.pending_request.init(self.server.gpa);
                    if (before == 0) {
                        self.writing_wakeup.notify() catch |err| {
                            logger.err(
                                "failed to wakeup writer on fd={d}: {s}",
                                .{ self.fd, @errorName(err) },
                            );
                            self.scheduleClose();
                            return .disarm;
                        };
                    } else if (before == fifo_length - 1) {
                        return .disarm; // No more space in queue
                    }
                }

                return .rearm;
            }

            fn writingWakeupCb(
                ud: ?*Connection,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Async.WaitError!void,
            ) xev.CallbackAction {
                const self = ud.?;
                std.debug.assert(l == self.server.loop);
                std.debug.assert(c == &self.c_writing_wakeup);

                _ = r catch |err| {
                    logger.err(
                        "got error on writer wakeup (fd={d}): {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.scheduleClose();
                    return .disarm;
                };

                self.processQueuedRequest() catch |err| {
                    logger.err(
                        "failed to process request on fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.responder.reset();
                    return .rearm;
                };

                self.c_writing = .{
                    .op = .{
                        .send = .{
                            .fd = self.fd,
                            .buffer = .{ .slice = self.responder.preamble.items },
                        },
                    },
                    .userdata = self,
                    .callback = writeCb,
                };
                self.server.loop.add(&self.c_writing);

                return .rearm;
            }

            fn processQueuedRequest(self: *Connection) !void {
                std.debug.assert(self.request_queue.readableLength() > 0);

                var request = self.request_queue.readItem().?;
                defer request.reset();

                std.debug.assert(request.stage == .ready);

                handlerFn(self.server.ctx, &self.responder, &request) catch |err| {
                    self.responder.status = .internal_server_error;
                    self.responder.body.clearRetainingCapacity();
                    try self.responder.body.appendSlice("an internal server error occured");
                    logger.err(
                        "request handler failed (fd={d}): {s}",
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
                    try w.writeAll("Server: mcp\r\n");
                }

                if (!self.responder.headers.contains("connection")) {
                    const req_connection = self.pending_request.headers.getFirstValue("connection");
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

                if (self.pending_request.method == .HEAD) {
                    self.responder.body.clearAndFree();
                }
            }

            fn writeCb(
                ud: ?*anyopaque,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.Result,
            ) xev.CallbackAction {
                const self = @as(*Connection, @ptrCast(@alignCast(ud.?)));
                std.debug.assert(l == self.server.loop);
                std.debug.assert(c == &self.c_writing);

                const wrote = r.send catch |err| {
                    logger.err(
                        "send() failed on socket fd={d}: {s}",
                        .{ self.fd, @errorName(err) },
                    );
                    self.scheduleClose();
                    return .disarm;
                };
                self.responder.sent += wrote;

                const preamble_len = self.responder.preamble.items.len;
                const body_len = self.responder.body.items.len;
                if (self.responder.sent < preamble_len) {
                    self.c_writing = .{
                        .op = .{
                            .send = .{
                                .fd = self.fd,
                                .buffer = .{
                                    .slice = self.responder.preamble.items[self.responder.sent..],
                                },
                            },
                        },
                        .userdata = self,
                        .callback = writeCb,
                    };
                    self.server.loop.add(&self.c_writing);
                    return .disarm;
                } else if (self.responder.sent < preamble_len + body_len) {
                    const offset = self.responder.sent - preamble_len;
                    self.c_writing = .{
                        .op = .{
                            .send = .{
                                .fd = self.fd,
                                .buffer = .{
                                    .slice = self.responder.body.items[offset..],
                                },
                            },
                        },
                        .userdata = self,
                        .callback = writeCb,
                    };
                    self.server.loop.add(&self.c_writing);
                    return .disarm;
                }
                std.debug.assert(self.responder.sent == preamble_len + body_len);

                while (self.request_queue.readableLength() > 0) {
                    self.responder.reset();
                    self.processQueuedRequest() catch |err| {
                        logger.err(
                            "failed to process request on fd={d}: {s}",
                            .{ self.fd, @errorName(err) },
                        );
                        continue;
                    };
                    self.c_writing = .{
                        .op = .{
                            .send = .{
                                .fd = self.fd,
                                .buffer = .{
                                    .slice = self.responder.preamble.items,
                                },
                            },
                        },
                        .userdata = self,
                        .callback = writeCb,
                    };
                    self.server.loop.add(&self.c_writing);
                    return .disarm;
                }

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
