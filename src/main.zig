const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const http = @import("http.zig");

pub fn main() !void {
    var gp_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    const use_gpa = builtin.mode != .ReleaseFast or !builtin.link_libc;
    const alloc = alloc: {
        if (use_gpa) {
            break :alloc gp_alloc.allocator();
        }
        if (@alignOf(std.c.max_align_t) < @alignOf(i128)) {
            break :alloc std.heap.c_allocator;
        }
        break :alloc std.heap.raw_c_allocator;
    };
    defer if (use_gpa) {
        _ = gp_alloc.deinit();
    };

    //var tpool = xev.ThreadPool.init(.{});
    //defer {
    //    tpool.shutdown();
    //    tpool.deinit();
    //}

    //var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var port: u16 = 8080;
    if (std.os.getenv("PORT")) |ps| {
        port = try std.fmt.parseInt(u16, ps, 10);
    }
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);

    const serverType = http.ServerType(void, errType, handlerFn);
    var server: serverType = undefined;
    try server.init({}, alloc, addr, &loop);
    defer server.deinit();

    std.log.debug("listening on 0.0.0.0:{d}", .{port});

    try loop.run(.until_done);
}

const errType = error{OutOfMemory};

fn handlerFn(_: void, rw: *http.ResponseWriter, _: *const http.Request) errType!void {
    rw.status = .ok;
    try rw.body.appendSlice("End of line.");
}
