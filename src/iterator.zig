const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const meta = @import("meta.zig");
const query = @import("query.zig");

/// Initialize an iterator given an sorted slice of types
pub fn FromTypes(
    comptime names: []const []const u8,
    comptime sorted_outer_types: []const type,
    comptime component_bitmap: anytype,
    comptime OpaqueArchetype: type,
) type {
    return struct {
        pub const Item = meta.ComponentStruct(names, sorted_outer_types);

        /// This iterator allow users to iterate results of queries without having to care about internal
        /// storage details
        const Iterator = @This();

        allocator: Allocator,
        query_result: []const *OpaqueArchetype,

        storage_buffer: OpaqueArchetype.StorageData,
        outer_storage_buffer: [sorted_outer_types.len][]u8,

        outer_cursor: i32 = -1,
        inner_cursor: usize = 0,

        /// Initialize an ``iterator``. The ``iterator`` will own the ``query_result`` meaning the caller must make sure to call
        /// ```js
        ///     iterator.deinit();
        /// ```
        pub fn init(allocator: Allocator, query_result: []const *OpaqueArchetype) Iterator {
            return Iterator{
                .allocator = allocator,
                .query_result = query_result,
                .storage_buffer = OpaqueArchetype.StorageData{
                    .inner_len = 0,
                    .outer = undefined,
                },
                .outer_storage_buffer = undefined,
            };
        }

        pub fn deinit(self: Iterator) void {
            self.allocator.free(self.query_result);
        }

        pub fn next(self: *Iterator) ?Item {
            const zone = ztracy.ZoneNC(@src(), "Query Iterator next", Color.iterator);
            defer zone.End();

            if (self.query_result.len == 0) {
                return null;
            }

            // check if inner iteration is complete
            while (self.inner_cursor >= self.storage_buffer.inner_len) {
                // check if we are completly done iterating
                if ((self.outer_cursor + 1) >= self.query_result.len) {
                    return null;
                }

                self.outer_cursor += 1;
                self.inner_cursor = 0;
                self.storage_buffer.outer = &self.outer_storage_buffer;

                self.query_result[@intCast(usize, self.outer_cursor)].getStorageData(&self.storage_buffer, component_bitmap);
            }

            self.inner_cursor += 1;
            return populateItem(self.storage_buffer, self.inner_cursor - 1);
        }

        /// Retrieve an item from a flat index, this operation is **not** 0(1)
        pub fn at(self: Iterator, index: usize) ?Item {
            const zone = ztracy.ZoneNC(@src(), "Query Iterator at", Color.iterator);
            defer zone.End();

            var cursor: usize = 0;
            for (0..self.query_result.len) |outer_index| {
                for (0..self.query_result[outer_index].entities.count()) |inner_index| {
                    if (cursor != index) {
                        cursor += 1;
                        continue;
                    }

                    var temp_storage_data_buffer: [sorted_outer_types.len][]u8 = undefined;
                    var temp_storage_data = OpaqueArchetype.StorageData{
                        .inner_len = 0,
                        .outer = &temp_storage_data_buffer,
                    };
                    self.query_result[outer_index].getStorageData(&temp_storage_data, component_bitmap);

                    return populateItem(temp_storage_data, inner_index);
                }
            }

            return null;
        }

        inline fn populateItem(populated_storage_data: OpaqueArchetype.StorageData, inner_index: usize) Item {
            const zone = ztracy.ZoneNC(@src(), "Query Iterator populateItem", Color.iterator);
            defer zone.End();

            var item: Item = undefined;
            const item_fields = std.meta.fields(Item);
            inline for (item_fields, 0..) |field, type_index| {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .Pointer => |pointer| {
                        if (@sizeOf(pointer.child) == 0) {
                            @field(item, field.name) = &pointer.child{};
                        } else {
                            const from = inner_index * @sizeOf(pointer.child);
                            const to = from + @sizeOf(pointer.child);
                            const bytes = populated_storage_data.outer[type_index][from..to];

                            @field(item, field.name) = @ptrCast(
                                field.type,
                                @alignCast(@alignOf(pointer.child), bytes.ptr),
                            );
                        }
                    },
                    else => {
                        if (@sizeOf(field.type) == 0) {
                            @field(item, field.name) = field.type{};
                        } else {
                            const from = inner_index * @sizeOf(field.type);
                            const to = from + @sizeOf(field.type);
                            const bytes = populated_storage_data.outer[type_index][from..to];

                            @field(item, field.name) = @ptrCast(
                                *field.type,
                                @alignCast(@alignOf(field.type), bytes.ptr),
                            ).*;
                        }
                    },
                }
            }
            return item;
        }
    };
}

const testing = std.testing;
const Testing = @import("Testing.zig");
const A = Testing.Component.A;
const B = Testing.Component.B;
const C = Testing.Component.C;
const hashType = @import("query.zig").hashType;

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;

const TestOpaqueArchetype = @import("opaque_archetype.zig").FromComponentMask(Testing.ComponentBitmask);

test "value iterating works" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype_ab = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A | Testing.Bits.B);
    defer archetype_ab.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [2][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetype_ab.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    var archetype_abc = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype_abc.deinit();

    for (100..200) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype_abc.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    {
        const A_Iterator = FromTypes(
            &[_][]const u8{"a"},
            &[_]type{A},
            Testing.Bits.A,
            TestOpaqueArchetype,
        );
        var iter = A_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const B_Iterator = FromTypes(
            &[_][]const u8{"b"},
            &[_]type{B},
            Testing.Bits.B,
            TestOpaqueArchetype,
        );
        var iter = B_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.b);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_Iterator = FromTypes(
            &[_][]const u8{ "a", "b" },
            &[_]type{ A, B },
            Testing.Bits.A | Testing.Bits.B,
            TestOpaqueArchetype,
        );
        var iter = A_B_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.b);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_C_Iterator = FromTypes(
            &[_][]const u8{ "a", "b", "c" },
            &[_]type{ A, B, C },
            Testing.Bits.All,
            TestOpaqueArchetype,
        );
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{&archetype_abc});

        var i: u32 = 100;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.b);
            try testing.expectEqual(Testing.Component.C{}, item.c);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }
}

test "ptr iterating works and can mutate storage data" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    {
        {
            const A_Iterator = FromTypes(
                &[_][]const u8{"a_ptr"},
                &[_]type{*A},
                Testing.Bits.A,
                TestOpaqueArchetype,
            );
            var mutate_iter = A_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{&archetype});
            var i: u32 = 0;
            while (mutate_iter.next()) |item| {
                item.a_ptr.value += 1;
                i += 1;
            }
        }

        {
            const A_Iterator = FromTypes(
                &[_][]const u8{"a"},
                &[_]type{A},
                Testing.Bits.A,
                TestOpaqueArchetype,
            );
            var iter = A_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{&archetype});
            var i: u32 = 0;
            while (iter.next()) |item| {
                try testing.expectEqual(Testing.Component.A{ .value = i + 1 }, item.a);
                i += 1;
            }
        }
    }
}

test "value at index works" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype_ab = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A | Testing.Bits.B);
    defer archetype_ab.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [2][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetype_ab.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    var archetype_abc = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype_abc.deinit();

    for (100..200) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype_abc.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    {
        const A_Iterator = FromTypes(
            &[_][]const u8{"a"},
            &[_]type{A},
            Testing.Bits.A,
            TestOpaqueArchetype,
        );
        var iter = A_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]u32{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index) },
                result.a,
            );
        }
        try testing.expectEqual(@as(?A_Iterator.Item, null), iter.at(200));
    }

    {
        const B_Iterator = FromTypes(
            &[_][]const u8{"b"},
            &[_]type{B},
            Testing.Bits.B,
            TestOpaqueArchetype,
        );
        var iter = B_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]u32{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;
            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index) },
                result.b,
            );
        }
        try testing.expectEqual(@as(?B_Iterator.Item, null), iter.at(200));
    }

    {
        const A_B_Iterator = FromTypes(
            &[_][]const u8{ "a", "b" },
            &[_]type{ A, B },
            Testing.Bits.A | Testing.Bits.B,
            TestOpaqueArchetype,
        );
        var iter = A_B_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]u32{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index) },
                result.a,
            );

            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index) },
                result.b,
            );
        }
        try testing.expectEqual(@as(?A_B_Iterator.Item, null), iter.at(200));
    }

    {
        const A_B_C_Iterator = FromTypes(
            &[_][]const u8{ "a", "b", "c" },
            &[_]type{ A, B, C },
            Testing.Bits.All,
            TestOpaqueArchetype,
        );
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{&archetype_abc});

        for (&[_]u32{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index + 100) },
                result.a,
            );

            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index + 100) },
                result.b,
            );

            try testing.expectEqual(Testing.Component.C{}, result.c);
        }
        try testing.expectEqual(@as(?A_B_C_Iterator.Item, null), iter.at(100));
    }
}

test "ptr at works and can mutate storage data" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.registerEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data, sizes);
    }

    {
        const A_B_C_Iterator = FromTypes(
            &[_][]const u8{ "a_ptr", "b_ptr", "c" },
            &[_]type{ *A, *B, C },
            Testing.Bits.All,
            TestOpaqueArchetype,
        );
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*TestOpaqueArchetype{&archetype});
        for (&[_]u32{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            result.a_ptr.value += @as(u32, 1);
            result.b_ptr.value += @as(u8, 1);
        }

        for (&[_]u32{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(index + 1, @intCast(u32, result.a_ptr.value));
            try testing.expectEqual(index + 1, @intCast(u32, result.b_ptr.value));
        }
        try testing.expectEqual(@as(?A_B_C_Iterator.Item, null), iter.at(100));
    }
}
