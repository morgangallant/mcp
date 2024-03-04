pub const stdx = @import("stdx.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
