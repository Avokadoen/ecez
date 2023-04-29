const std = @import("std");
const Allocator = std.mem.Allocator;

const meta = @import("meta.zig");
const query = @import("query.zig");
const OpaqueArchetype = @import("OpaqueArchetype.zig");

/// Initialize an iterator given an sorted slice of types
pub fn FromTypes(comptime sorted_types: []const type, comptime type_hashes: []const u64) type {
    return struct {
        pub const Item = meta.ComponentStruct(sorted_types);

        /// This iterator allow users to iterate results of queries without having to care about internal
        /// storage details
        const Iterator = @This();

        allocator: Allocator,
        query_result: []const *OpaqueArchetype,

        storage_buffer: OpaqueArchetype.StorageData,
        outer_storage_buffer: [sorted_types.len][]u8,

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

        pub fn next(self: *Iterator) ?Item {
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
                self.query_result[@intCast(usize, self.outer_cursor)].rawGetStorageData(
                    type_hashes,
                    &self.storage_buffer,
                ) catch unreachable;
            }

            // grab next item
            var item: Item = undefined;
            const item_fields = std.meta.fields(Item);
            inline for (item_fields, 0..) |field, index| {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .Pointer => |pointer| {
                        if (@sizeOf(pointer.child) == 0) {
                            @field(item, field.name) = &pointer.child{};
                        } else {
                            const from = self.inner_cursor * @sizeOf(pointer.child);
                            const to = from + @sizeOf(pointer.child);
                            const bytes = self.storage_buffer.outer[index][from..to];

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
                            const from = self.inner_cursor * @sizeOf(field.type);
                            const to = from + @sizeOf(field.type);
                            const bytes = self.storage_buffer.outer[index][from..to];

                            @field(item, field.name) = @ptrCast(
                                *field.type,
                                @alignCast(@alignOf(field.type), bytes.ptr),
                            ).*;
                        }
                    },
                }
            }

            self.inner_cursor += 1;
            return item;
        }

        /// Retrieve an item from a flat index, this operation is **not** 0(1)
        pub fn at(self: Iterator, index: usize) ?Item {
            var cursor: usize = 0;
            for (0..self.query_result.len) |outer_index| {
                for (0..self.query_result[outer_index].entities.count()) |inner_index| {
                    if (cursor != index) {
                        cursor += 1;
                        continue;
                    }

                    var temp_storage_data_buffer: [sorted_types.len][]u8 = undefined;
                    var temp_storage_data = OpaqueArchetype.StorageData{
                        .inner_len = 0,
                        .outer = &temp_storage_data_buffer,
                    };
                    self.query_result[outer_index].rawGetStorageData(type_hashes, &temp_storage_data) catch unreachable;
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
                                    const bytes = temp_storage_data.outer[type_index][from..to];

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
                                    const bytes = temp_storage_data.outer[type_index][from..to];

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
            }

            return null;
        }

        pub fn deinit(self: Iterator) void {
            self.allocator.free(self.query_result);
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

test "value iterating works" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype_ab = try OpaqueArchetype.init(testing.allocator, hashes[0..2], sizes[0..2]);
    defer archetype_ab.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [2][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetype_ab.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    var archetype_abc = try OpaqueArchetype.init(testing.allocator, hashes[0..3], sizes[0..3]);
    defer archetype_abc.deinit();

    for (100..200) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype_abc.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    {
        const A_Iterator = FromTypes(&[_]type{A}, hashes[0..1]);
        var iter = A_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.@"Testing.Component.A");
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const B_Iterator = FromTypes(&[_]type{B}, hashes[1..2]);
        var iter = B_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.@"Testing.Component.B");
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_Iterator = FromTypes(&[_]type{ A, B }, hashes[0..2]);
        var iter = A_B_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.@"Testing.Component.A");
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.@"Testing.Component.B");
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_C_Iterator = FromTypes(&[_]type{ A, B, C }, hashes[0..3]);
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{&archetype_abc});

        var i: u32 = 100;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.@"Testing.Component.A");
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, item.@"Testing.Component.B");
            try testing.expectEqual(Testing.Component.C{}, item.@"Testing.Component.C");
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }
}

test "ptr iterating works and can mutate storage data" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    {
        {
            const A_Iterator = FromTypes(&[_]type{*A}, hashes[0..1]);
            var mutate_iter = A_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{&archetype});
            var i: u32 = 0;
            while (mutate_iter.next()) |item| {
                item.@"Testing.Component.A".value += 1;
                i += 1;
            }
        }

        {
            const A_Iterator = FromTypes(&[_]type{A}, hashes[0..1]);
            var iter = A_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{&archetype});
            var i: u32 = 0;
            while (iter.next()) |item| {
                try testing.expectEqual(Testing.Component.A{ .value = i + 1 }, item.@"Testing.Component.A");
                i += 1;
            }
        }
    }
}

test "value at index works" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype_ab = try OpaqueArchetype.init(testing.allocator, hashes[0..2], sizes[0..2]);
    defer archetype_ab.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [2][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetype_ab.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    var archetype_abc = try OpaqueArchetype.init(testing.allocator, hashes[0..3], sizes[0..3]);
    defer archetype_abc.deinit();

    for (100..200) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype_abc.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    {
        const A_Iterator = FromTypes(&[_]type{A}, hashes[0..1]);
        var iter = A_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]usize{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index) },
                result.@"Testing.Component.A",
            );
        }
        try testing.expectEqual(@as(?A_Iterator.Item, null), iter.at(200));
    }

    {
        const B_Iterator = FromTypes(&[_]type{B}, hashes[1..2]);
        var iter = B_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]usize{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;
            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index) },
                result.@"Testing.Component.B",
            );
        }
        try testing.expectEqual(@as(?B_Iterator.Item, null), iter.at(200));
    }

    {
        const A_B_Iterator = FromTypes(&[_]type{ A, B }, hashes[0..2]);
        var iter = A_B_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{ &archetype_ab, &archetype_abc });

        for (&[_]usize{ 0, 99, 100, 199 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index) },
                result.@"Testing.Component.A",
            );

            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index) },
                result.@"Testing.Component.B",
            );
        }
        try testing.expectEqual(@as(?A_B_Iterator.Item, null), iter.at(200));
    }

    {
        const A_B_C_Iterator = FromTypes(&[_]type{ A, B, C }, hashes[0..3]);
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{&archetype_abc});

        for (&[_]usize{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(u32, index + 100) },
                result.@"Testing.Component.A",
            );

            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(u8, index + 100) },
                result.@"Testing.Component.B",
            );

            try testing.expectEqual(Testing.Component.C{}, result.@"Testing.Component.C");
        }
        try testing.expectEqual(@as(?A_B_C_Iterator.Item, null), iter.at(100));
    }
}

test "ptr at works and can mutate storage data" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    for (0..100) |i| {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    {
        const A_B_C_Iterator = FromTypes(&[_]type{ *A, *B, C }, hashes[0..3]);
        var iter = A_B_C_Iterator.init(std.testing.allocator, &[_]*OpaqueArchetype{&archetype});
        for (&[_]usize{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            result.@"Testing.Component.A".value += @as(u32, 1);
            result.@"Testing.Component.B".value += @as(u8, 1);
        }

        for (&[_]usize{ 0, 99 }) |index| {
            const result = iter.at(index).?;

            try testing.expectEqual(index + 1, @intCast(usize, result.@"Testing.Component.A".value));
            try testing.expectEqual(index + 1, @intCast(usize, result.@"Testing.Component.B".value));
        }
        try testing.expectEqual(@as(?A_B_C_Iterator.Item, null), iter.at(100));
    }
}
