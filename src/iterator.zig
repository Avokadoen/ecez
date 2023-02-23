const std = @import("std");
const testing = std.testing;

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

pub fn FromTypes(comptime types: []const type, comptime result_count: comptime_int) type {
    const ComponentStorage = meta.LengthComponentStorage(types);

    return struct {
        pub const Item = std.meta.Tuple(types);
        const Iterator = @This();

        outer_cursor: usize,
        inner_cursor: usize,
        iterate_data: [result_count]ComponentStorage,

        pub fn init(iterate_data: [result_count]ComponentStorage) Iterator {
            return Iterator{
                .outer_cursor = 0,
                .inner_cursor = 0,
                .iterate_data = iterate_data,
            };
        }

        pub fn next(self: *Iterator) ?Item {
            if (self.iterate_data.len == 0) {
                return null;
            }

            const outer_iter_done = (self.outer_cursor + 1) >= self.iterate_data.len;
            const inner_iter_done = (self.inner_cursor + 1) >= self.iterate_data[self.outer_cursor].len;

            // check if iterating is complete
            if (outer_iter_done and inner_iter_done) {
                return null;
            }

            // grab next item
            var item: Item = undefined;
            const storage = self.iterate_data[self.outer_cursor].storage;
            inline for (types, 0..) |T, i| {
                if (@sizeOf(T) > 0) {
                    // TODO: support AOS
                    item[i] = storage[i].items[self.inner_cursor];
                } else {
                    item[i] = storage[i];
                }
            }
            // if current array loop is complete we go to next array
            if (inner_iter_done) {
                self.outer_cursor += 1;
                self.inner_cursor = 0;
            } else {
                // else we keep iterating current array
                self.inner_cursor += 1;
            }

            return item;
        }
    };
}

test "simple iterating works" {
    const TypeComposition = &[_]type{ Testing.Component.A, Testing.Component.B, Testing.Component.C };
    // create iterator where we found 2 archetypes that match requirement
    const elem_len = 64;

    var test_data = [2]meta.LengthComponentStorage(TypeComposition){ .{
        .len = elem_len,
        .storage = .{
            std.ArrayList(Testing.Component.A).init(testing.allocator),
            std.ArrayList(Testing.Component.B).init(testing.allocator),
            Testing.Component.C{},
        },
    }, .{
        .len = elem_len / 2,
        .storage = .{
            std.ArrayList(Testing.Component.A).init(testing.allocator),
            std.ArrayList(Testing.Component.B).init(testing.allocator),
            Testing.Component.C{},
        },
    } };
    defer {
        test_data[0].storage[0].deinit();
        test_data[0].storage[1].deinit();
        test_data[1].storage[0].deinit();
        test_data[1].storage[1].deinit();
    }
    for (0..elem_len) |i| {
        try test_data[0].storage[0].append(Testing.Component.A{ .value = @intCast(u32, i) });
        try test_data[0].storage[1].append(Testing.Component.B{ .value = @intCast(u8, i) });
    }
    for (0..elem_len) |i| {
        try test_data[1].storage[0].append(Testing.Component.A{ .value = elem_len + @intCast(u32, i) });
        try test_data[1].storage[1].append(Testing.Component.B{ .value = @intCast(u8, elem_len + i) });
    }

    const Iter = FromTypes(TypeComposition, 2);

    {
        var i: u32 = 0;
        var iter = Iter.init(test_data);
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item[0]);
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item[1]);
            try testing.expectEqual(Testing.Component.C{}, item[2]);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
        try testing.expectEqual(iter.next(), null);
        try testing.expectEqual(iter.next(), null);
    }
}
