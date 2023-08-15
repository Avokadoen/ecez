const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const Entity = @import("entity_type.zig").Entity;
const meta = @import("meta.zig");

/// Initialize an iterator given an sorted slice of types
pub fn FromTypes(
    comptime ItemType: type,
    comptime query_has_entity: bool,
    comptime include_bitmap: anytype,
    comptime exclude_bitmap: anytype,
    comptime OpaqueArchetype: type,
    comptime BinaryTree: type,
) type {
    const field_len = std.meta.fields(ItemType).len;

    return struct {
        /// This iterator allow users to iterate results of queries without having to care about internal
        /// storage details
        const Iterator = @This();

        comptime secret_field: meta.ArgType = .query_iter,
        entities: []Entity,
        all_archetypes: []OpaqueArchetype,
        tree: BinaryTree,
        tree_cursor: BinaryTree.IterCursor,

        storage_buffer: OpaqueArchetype.StorageData,
        outer_storage_buffer: [field_len][]u8,

        inner_cursor: usize = 0,

        /// **This is called by ecez automically**
        ///  Initialize an ``iterator``,
        pub fn init(all_archetypes: []OpaqueArchetype, tree: BinaryTree) Iterator {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.iterator);
            defer zone.End();

            return Iterator{
                .entities = undefined,
                .all_archetypes = all_archetypes,
                .tree = tree,
                .tree_cursor = BinaryTree.IterCursor.fromRoot(),
                .storage_buffer = OpaqueArchetype.StorageData{
                    .inner_len = 0,
                    .outer = undefined,
                },
                .outer_storage_buffer = undefined,
            };
        }

        pub fn next(self: *Iterator) ?ItemType {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.iterator);
            defer zone.End();

            // check if inner iteration is complete
            while (self.inner_cursor >= self.storage_buffer.inner_len) {
                if (self.tree.iterate(include_bitmap, exclude_bitmap, &self.tree_cursor)) |next_archetype_index| {
                    self.inner_cursor = 0;
                    self.storage_buffer.outer = &self.outer_storage_buffer;
                    self.all_archetypes[next_archetype_index].getStorageData(&self.storage_buffer, include_bitmap);

                    if (query_has_entity) {
                        self.entities = self.all_archetypes[next_archetype_index].entities.keys();
                    }
                } else {
                    return null;
                }
            }

            var item: ItemType = undefined;
            const fields = @typeInfo(ItemType).Struct.fields;

            if (query_has_entity) {
                @field(item, fields[0].name) = self.entities[self.inner_cursor];
            }

            const fields_start_index = if (query_has_entity) 1 else 0;

            const byte_storage = self.storage_buffer.outer[0..fields[fields_start_index..].len];
            inline for (fields[fields_start_index..], byte_storage) |field, byte_storage_field| {
                const field_type_info = @typeInfo(field.type);
                switch (field_type_info) {
                    .Pointer => |pointer| {
                        if (@sizeOf(pointer.child) == 0) {
                            @field(item, field.name) = &pointer.child{};
                        } else {
                            const from = self.inner_cursor * @sizeOf(pointer.child);
                            const to = from + @sizeOf(pointer.child);
                            const bytes = byte_storage_field[from..to];

                            @field(item, field.name) = @ptrCast(@alignCast(bytes));
                        }
                    },
                    else => {
                        if (@sizeOf(field.type) == 0) {
                            @field(item, field.name) = field.type{};
                        } else {
                            const from = self.inner_cursor * @sizeOf(field.type);
                            const to = from + @sizeOf(field.type);
                            const bytes = byte_storage_field[from..to];

                            @field(item, field.name) = @as(*field.type, @ptrCast(@alignCast(bytes))).*;
                        }
                    },
                }
            }

            self.inner_cursor += 1;
            return item;
        }

        pub fn skip(self: *Iterator, skip_items: usize) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.iterator);
            defer zone.End();

            self.inner_cursor += skip_items;

            // check if inner iteration is complete
            while (self.inner_cursor >= self.storage_buffer.inner_len) {
                const rem = self.inner_cursor - self.storage_buffer.inner_len;
                if (self.tree.iterate(include_bitmap, exclude_bitmap, &self.tree_cursor)) |next_archetype_index| {
                    self.inner_cursor = rem;
                    self.storage_buffer.outer = &self.outer_storage_buffer;
                    self.all_archetypes[next_archetype_index].getStorageData(&self.storage_buffer, include_bitmap);

                    if (query_has_entity) {
                        self.entities = self.all_archetypes[next_archetype_index].entities.keys();
                    }
                } else {
                    return;
                }
            }
        }

        pub fn reset(self: *Iterator) void {
            self.storage_buffer.inner_len = 0;
            self.inner_cursor = 0;
            self.tree_cursor = BinaryTree.IterCursor.fromRoot();
        }
    };
}

const testing = std.testing;
const Testing = @import("Testing.zig");
const A = Testing.Component.A;
const B = Testing.Component.B;
const C = Testing.Component.C;

const entity_type = @import("entity_type.zig");

const TestOpaqueArchetype = @import("opaque_archetype.zig").FromComponentMask(Testing.ComponentBitmask);
const TestTree = @import("binary_tree.zig").FromConfig(Testing.AllComponentsArr.len + 1, Testing.ComponentBitmask);

const sizes = [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
const alignments = [_]u8{
    std.math.log2(@alignOf(A)),
    std.math.log2(@alignOf(B)),
    std.math.log2(@alignOf(C)),
};

test "value iterating works" {
    var tree = try TestTree.init(testing.allocator, 12);
    defer tree.deinit();

    tree.appendChain(@as(u32, 0), Testing.Bits.A | Testing.Bits.B) catch unreachable;
    tree.appendChain(@as(u32, 1), Testing.Bits.All) catch unreachable;

    var archetypes: [2]TestOpaqueArchetype = .{
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A | Testing.Bits.B) catch unreachable,
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All) catch unreachable,
    };
    defer {
        for (&archetypes) |*archetype| {
            archetype.deinit(alignments);
        }
    }

    var data: [3][]const u8 = undefined;
    for (0..100) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetypes[0].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..2],
            sizes,
            alignments,
        );
    }

    for (100..200) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetypes[1].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..3],
            sizes,
            alignments,
        );
    }

    {
        const A_Iterator = FromTypes(
            struct { a: A },
            false,
            Testing.Bits.A,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = A_Iterator.init(&archetypes, tree);

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const B_Iterator = FromTypes(
            struct { b: B },
            false,
            Testing.Bits.B,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = B_Iterator.init(&archetypes, tree);

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.B{ .value = @as(u8, @intCast(i)) }, item.b);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_Iterator = FromTypes(
            struct { a: A, b: B },
            false,
            Testing.Bits.A | Testing.Bits.B,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = A_B_Iterator.init(&archetypes, tree);

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            try testing.expectEqual(Testing.Component.B{ .value = @as(u8, @intCast(i)) }, item.b);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }

    {
        const A_B_C_Iterator = FromTypes(
            struct { a: A, b: B, c: C },
            false,
            Testing.Bits.All,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = A_B_C_Iterator.init(&archetypes, tree);

        var i: u32 = 100;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            try testing.expectEqual(Testing.Component.B{ .value = @as(u8, @intCast(i)) }, item.b);
            try testing.expectEqual(Testing.Component.C{}, item.c);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }
}

test "ptr iterating works and can mutate storage data" {
    var tree = try TestTree.init(testing.allocator, 5);
    defer tree.deinit();
    tree.appendChain(@as(u32, 0), Testing.Bits.All) catch unreachable;

    var archetypes = [_]TestOpaqueArchetype{
        try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All),
    };
    defer archetypes[0].deinit(alignments);

    for (0..100) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetypes[0].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            &data,
            sizes,
            alignments,
        );
    }

    {
        {
            const A_Iterator = FromTypes(
                struct { a_ptr: *A },
                false,
                Testing.Bits.A,
                Testing.Bits.None,
                TestOpaqueArchetype,
                TestTree,
            );
            var mutate_iter = A_Iterator.init(&archetypes, tree);
            var i: u32 = 0;
            while (mutate_iter.next()) |item| {
                item.a_ptr.value += 1;
                i += 1;
            }
        }

        {
            const A_Iterator = FromTypes(
                struct { a: A },
                false,
                Testing.Bits.A,
                Testing.Bits.None,
                TestOpaqueArchetype,
                TestTree,
            );
            var iter = A_Iterator.init(&archetypes, tree);
            var i: u32 = 0;
            while (iter.next()) |item| {
                try testing.expectEqual(Testing.Component.A{ .value = i + 1 }, item.a);
                i += 1;
            }
        }
    }
}

test "reset moves iterator to start" {
    var tree = try TestTree.init(testing.allocator, 12);
    defer tree.deinit();

    tree.appendChain(@as(u32, 0), Testing.Bits.A | Testing.Bits.B) catch unreachable;
    tree.appendChain(@as(u32, 1), Testing.Bits.All) catch unreachable;

    var archetypes: [2]TestOpaqueArchetype = .{
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A | Testing.Bits.B) catch unreachable,
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All) catch unreachable,
    };
    defer {
        for (&archetypes) |*archetype| {
            archetype.deinit(alignments);
        }
    }

    var data: [3][]const u8 = undefined;
    for (0..100) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetypes[0].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..2],
            sizes,
            alignments,
        );
    }

    for (100..200) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetypes[1].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..3],
            sizes,
            alignments,
        );
    }

    {
        const A_Iterator = FromTypes(
            struct { a: A },
            false,
            Testing.Bits.A,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = A_Iterator.init(&archetypes, tree);

        var i: u32 = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);

        iter.reset();
        i = 0;
        while (iter.next()) |item| {
            try testing.expectEqual(Testing.Component.A{ .value = i }, item.a);
            i += 1;
        }
        try testing.expectEqual(iter.next(), null);
    }
}

test "skip moves iterator to requested entry" {
    var tree = try TestTree.init(testing.allocator, 12);
    defer tree.deinit();

    tree.appendChain(@as(u32, 0), Testing.Bits.A | Testing.Bits.B) catch unreachable;
    tree.appendChain(@as(u32, 1), Testing.Bits.All) catch unreachable;

    var archetypes: [2]TestOpaqueArchetype = .{
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A | Testing.Bits.B) catch unreachable,
        TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All) catch unreachable,
    };
    defer {
        for (&archetypes) |*archetype| {
            archetype.deinit(alignments);
        }
    }

    var data: [3][]const u8 = undefined;
    for (0..100) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        try archetypes[0].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..2],
            sizes,
            alignments,
        );
    }

    for (100..200) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetypes[1].registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            data[0..3],
            sizes,
            alignments,
        );
    }

    {
        const A_Iterator = FromTypes(
            struct { a: A },
            false,
            Testing.Bits.A,
            Testing.Bits.None,
            TestOpaqueArchetype,
            TestTree,
        );
        var iter = A_Iterator.init(&archetypes, tree);

        iter.skip(50);

        {
            const item_50th = iter.next().?;
            try testing.expectEqual(Testing.Component.A{ .value = 50 }, item_50th.a);
        }

        iter.skip(100);
        {
            const item_151th = iter.next().?;
            // 50 + 1 (call to next) + 100 = 151
            try testing.expectEqual(Testing.Component.A{ .value = 151 }, item_151th.a);
        }
    }
}
