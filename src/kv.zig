const std = @import("std");
const stdx = @import("stdx.zig");

// An LSM-based, disk-backed KV store.

const KeySchema = struct {
    identifier: [:0]const u8,
    parts: []const Part,

    const Part = union(enum) {
        static_bytes: []const u8,
        dynamic_bytes: struct {
            length: usize,
        },

        fn rep(comptime self: *const Part) ?type {
            return switch (self) {
                .static_bytes => null,
                .dynamic_bytes => |inner| [inner.length]u8,
            };
        }

        fn size(self: *const Part) usize {
            return switch (self.*) {
                .static_bytes => |inner| inner.len,
                .dynamic_bytes => |inner| inner.length,
            };
        }
    };

    fn size(self: *const KeySchema, sep_len: usize, num_parts: usize) usize {
        std.debug.assert(num_parts <= self.parts.len);
        var total: usize = 0;
        for (self.parts[0..num_parts]) |part| total += part.size();
        if (num_parts > 0)
            total += @min(num_parts, self.parts.len - 1) * sep_len;
        return total;
    }
};

fn KeyType(comptime tag_type: type, comptime sep: []const u8, comptime schema: []const KeySchema,) type {
    if (schema.len > std.math.maxInt(tag_type)) {
        @compileError("too many key schemas for tag type");
    }
    
    var tag_fields: [schema.len]std.builtin.Type.EnumField = undefined;
    for (schema, 0..) |s, i| {
        tag_fields[i] = .{
            .name = s.identifier,
            .value = i,
        };
    }
    const schema_tag = @Type(.{
        .Enum = .{
            .tag_type = tag_type,
            .fields = &tag_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

const test_key_schema = &[_]KeySchema{
    .{
        .identifier = "a",
        .parts = &[_]KeySchema.Part{
            .{ .static_bytes = "foo" },
            .{ .dynamic_bytes = .{ .length = 3 } },
        },
    },
};

test "key schema" {
    const k: KeyType(u8, ":", test_key_schema) = .a;
    @compileLog(k);
}
