const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const entity_type = @import("entity_type.zig");

const Color = @import("misc.zig").Color;
const Entity = entity_type.Entity;
const EntityMap = entity_type.Map;

const ecez_error = @import("error.zig");
const ArchetypeError = ecez_error.ArchetypeError;

pub fn FromComponentMask(comptime ComponentMask: type) type {
    const max_component_count = @popCount(~@as(ComponentMask.Bits, 0));

    return struct {
        const OpaqueArchetype = @This();

        allocator: Allocator,

        /// store the mapping from Entity -> index
        /// the storage has a strict requirement that values increment (0, 1, 2 ...)
        entities: EntityMap,

        component_bitmask: ComponentMask.Bits,
        component_storage: []ArrayList(u8),
        void_component: [0]u8 = [0]u8{},

        pub fn init(allocator: Allocator, component_bitmask: ComponentMask.Bits) error{OutOfMemory}!OpaqueArchetype {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype init", Color.opaque_archetype);
            defer zone.End();

            const type_count = @popCount(component_bitmask);
            var component_storage = try allocator.alloc(ArrayList(u8), type_count);
            errdefer allocator.free(component_storage);

            for (component_storage) |*component_buffer| {
                component_buffer.* = ArrayList(u8).init(allocator);
            }

            return OpaqueArchetype{
                .allocator = allocator,
                .entities = EntityMap.init(allocator),
                .component_bitmask = component_bitmask,
                .component_storage = component_storage,
            };
        }

        pub fn deinit(self: *OpaqueArchetype) void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype deinit", Color.opaque_archetype);
            defer zone.End();

            self.entities.deinit();
            for (self.component_storage) |component_buffer| {
                component_buffer.deinit();
            }
            self.allocator.free(self.component_storage);
        }

        pub fn clearRetainingCapacity(self: *OpaqueArchetype) void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype clear", Color.opaque_archetype);
            defer zone.End();
            self.entities.clearRetainingCapacity();

            for (self.component_storage) |*component_buffer| {
                component_buffer.clearRetainingCapacity();
            }
        }

        /// Given a bit mask of components, check if this archetype has all bits in bitmask
        pub inline fn hasComponents(self: OpaqueArchetype, bitmask: ComponentMask.Bits) bool {
            return (self.component_bitmask & bitmask) == bitmask;
        }

        /// Retrieve an entity's component as a pointer
        pub fn getComponent(
            self: OpaqueArchetype,
            entity: Entity,
            comptime bitmask: ComponentMask.Bits,
            comptime Component: type,
        ) ecez_error.ArchetypeError!*Component {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype getComponent", Color.opaque_archetype);
            defer zone.End();

            if (self.hasComponents(bitmask) == false) {
                return ArchetypeError.ComponentMissing;
            }
            const entity_index = self.entities.get(entity) orelse {
                return ArchetypeError.EntityMissing; // Entity not part of archetype
            };
            if (@sizeOf(Component) == 0) {
                return @constCast(@as(*const Component, @ptrCast(&self.void_component)));
            }

            const bytes = byte_retrieve_blk: {
                const storage_index = self.bitInMaskToStorageIndex(bitmask);
                const bytes_from = entity_index * @sizeOf(Component);
                const bytes_to = bytes_from + @sizeOf(Component);

                break :byte_retrieve_blk self.component_storage[storage_index].items[bytes_from..bytes_to];
            };

            return @constCast(@as(*const Component, @ptrCast(@alignCast(bytes.ptr))));
        }

        pub fn setComponent(
            self: *OpaqueArchetype,
            entity: Entity,
            component: anytype,
            comptime bitmask: ComponentMask.Bits,
        ) ArchetypeError!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype setComponent", Color.opaque_archetype);
            defer zone.End();

            const Component = @TypeOf(component);

            if (self.hasComponents(bitmask) == false) {
                return ArchetypeError.ComponentMissing;
            }
            const entity_index = self.entities.get(entity) orelse {
                return ArchetypeError.EntityMissing; // Entity not part of archetype
            };
            if (@sizeOf(Component) == 0) {
                return; // no bytes to write
            }

            const storage_index = self.bitInMaskToStorageIndex(bitmask);
            const component_bytes = std.mem.asBytes(&component);
            const bytes_from = entity_index * @sizeOf(Component);

            std.mem.copy(u8, self.component_storage[storage_index].items[bytes_from..], component_bytes);
        }

        pub fn prepareNewEntity(
            self: *OpaqueArchetype,
            entity: Entity,
            all_component_sizes: [max_component_count]u32,
        ) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype prepareNewEntity", Color.opaque_archetype);
            defer zone.End();

            const value = self.entities.count();
            try self.entities.put(entity, value);
            errdefer _ = self.entities.swapRemove(entity);

            var bitmask = self.component_bitmask;
            var cursor: u32 = 0;
            for (self.component_storage) |storage| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;
                cursor += @as(u32, @intCast(step)) + 1;

                const component_size = all_component_sizes[cursor - 1];
                try storage.ensureUnusedCapacity(component_size);
            }
        }

        pub fn registerEntity(
            self: *OpaqueArchetype,
            entity: Entity,
            data: []const []const u8,
            all_component_sizes: [max_component_count]u32,
        ) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype registerEntity", Color.opaque_archetype);
            defer zone.End();

            std.debug.assert(data.len == @popCount(self.component_bitmask));

            const value = self.entities.count();
            try self.entities.put(entity, value);
            errdefer _ = self.entities.swapRemove(entity);

            // TODO: proper error defer here if some later append fails

            var bitmask = self.component_bitmask;
            var cursor: u32 = 0;
            for (self.component_storage, data) |*storage, data_entry| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;
                cursor += @as(u32, @intCast(step)) + 1;

                const component_size = all_component_sizes[cursor - 1];
                // TODO: proper errdefer
                try storage.appendSlice(data_entry[0..component_size]);
            }
        }

        pub fn fetchEntityComponentView(
            self: *OpaqueArchetype,
            entity: Entity,
            all_component_sizes: [max_component_count]u32,
            out_buffers: [][]u8,
        ) error{EntityMissing}!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype fetchEntityComponentView", Color.opaque_archetype);
            defer zone.End();

            std.debug.assert(out_buffers.len == self.getComponentCount());

            // remove entity from entity map
            const component_index = self.entities.get(entity) orelse return error.EntityMissing;

            // move entity data to buffers
            var bitmask = self.component_bitmask;
            var cursor: u32 = 0;
            for (self.component_storage, out_buffers) |*storage, *buffer| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;

                cursor += @as(u32, @intCast(step)) + 1;

                const component_size = all_component_sizes[cursor - 1];

                if (component_size < 0) {
                    continue;
                }

                // assign buffer to storage view
                const fetch_from_bytes = component_index * component_size;
                const fetch_to_bytes = fetch_from_bytes + component_size;
                buffer.* = storage.items[fetch_from_bytes..fetch_to_bytes];
            }
        }

        pub fn swapRemoveEntity(
            self: *OpaqueArchetype,
            entity: Entity,
            all_component_sizes: [max_component_count]u32,
        ) error{EntityMissing}!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype swapRemoveEntity", Color.opaque_archetype);
            defer zone.End();

            // remove entity from entity map
            const moving_kv = self.entities.fetchSwapRemove(entity) orelse return error.EntityMissing;

            var bitmask = self.component_bitmask;
            var cursor: u32 = 0;
            for (self.component_storage) |*storage| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;

                cursor += @as(u32, @intCast(step)) + 1;

                const component_size = all_component_sizes[cursor - 1];

                if (component_size < 0) {
                    continue;
                }

                // copy data to buffer
                const remove_bytes = remove_slice_calc_blk: {
                    const remove_from_bytes = moving_kv.value * component_size;
                    const remove_to_bytes = remove_from_bytes + component_size;
                    const bytes = storage.items[remove_from_bytes..remove_to_bytes];
                    break :remove_slice_calc_blk bytes;
                };

                const entity_count = self.entities.count();
                if (entity_count > 0) {
                    // remove data from storage, by overwriting it with the swapped entity bytes
                    const moved_bytes = slice_calc_blk: {
                        const moved_from_bytes = entity_count * component_size;
                        const moved_to_bytes = moved_from_bytes + component_size;
                        break :slice_calc_blk storage.items[moved_from_bytes..moved_to_bytes];
                    };
                    @memcpy(remove_bytes, moved_bytes);
                }

                // mark extracted bytes as invalid
                const new_len = storage.items.len - component_size;
                // new_len is always less than previous len, so it can't fail
                storage.shrinkRetainingCapacity(new_len);
            }

            var values = self.entities.values();
            if (values.len > moving_kv.value) {
                // update the value of the entity that was moved from being last element to new position of the removed entity
                values[moving_kv.value] = moving_kv.value;
            }
        }

        pub fn removeEntity(
            self: *OpaqueArchetype,
            entity: Entity,
            all_component_sizes: [max_component_count]u32,
        ) error{EntityMissing}!void {
            const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype removeEntity", Color.opaque_archetype);
            defer zone.End();

            // remove entity from entity map
            const moving_kv = self.entities.fetchSwapRemove(entity) orelse return error.EntityMissing;

            // remove entity data from storage
            const component_count = self.getComponentCount();
            var bitmask = self.component_bitmask;
            var cursor: u32 = 0;
            for (0..component_count) |comp_index| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;

                cursor += @as(u32, @intCast(step)) + 1;

                const component_size = all_component_sizes[cursor - 1];

                // remove any data from storage
                if (component_size > 0) {
                    // copy data to buffer
                    const from_bytes = moving_kv.value * component_size;

                    // shift data to the left (moving 'deleted' bytes to the end of the array)
                    std.mem.rotate(u8, self.component_storage[comp_index].items[from_bytes..], component_size);

                    // mark extracted bytes as invalid
                    const new_len = self.component_storage[comp_index].items.len - component_size;
                    // new_len is always less than previous len, so it can't fail
                    self.component_storage[comp_index].shrinkRetainingCapacity(new_len);
                }
            }

            // remove entity and update entity values for all entities with component data to the right of removed entity
            // TODO: faster way of doing this?
            // https://devlog.hexops.com/2022/zig-hashmaps-explained/
            for (self.entities.values()) |*component_index| {
                // if the entity was located after removed entity, we shift it left
                // to occupy vacant memory
                if (component_index.* > moving_kv.value) {
                    component_index.* -= 1;
                }
            }
        }

        pub const StorageData = struct {
            inner_len: usize,
            outer: [][]u8,
        };
        /// Scroll the inner storage data by reordering data according to the requested type map.
        /// The index looking up the type map entry is the same index as the index the destination storage entry.
        /// The value stored in the typemap is to the data internally in the archetype.
        /// The short version is that this function performs swizzling based
        pub fn getStorageData(
            self: *OpaqueArchetype,
            storage: *StorageData,
            filter_bitmask: ComponentMask.Bits,
        ) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.opaque_archetype);
            defer zone.End();

            std.debug.assert(filter_bitmask & self.component_bitmask == filter_bitmask);

            const component_count = @popCount(filter_bitmask);
            var bitmask = filter_bitmask;
            var cursor: u32 = 0;
            for (0..component_count) |out_index| {
                const step = @as(ComponentMask.Shift, @intCast(@ctz(bitmask)));
                std.debug.assert((bitmask >> step) & 1 == 1);
                bitmask = (bitmask >> step) >> 1;

                cursor += @as(ComponentMask.Bits, @intCast(step)) + 1;

                const storage_index = storage_index_calc_blk: {
                    const current_bit_index = @as(ComponentMask.Shift, @intCast(cursor - 1));
                    const previous_bits_filter = (@as(ComponentMask.Bits, 1) << current_bit_index) - 1;
                    const previous_bits = self.component_bitmask & previous_bits_filter;
                    break :storage_index_calc_blk @popCount(previous_bits);
                };
                storage.outer[out_index] = self.component_storage[storage_index].items;
            }

            storage.inner_len = self.entities.count();
        }

        pub inline fn getComponentCount(self: OpaqueArchetype) ComponentMask.Bits {
            return @popCount(self.component_bitmask);
        }

        /// Given a single bit we can easily calculate how many bits are before the bit in the bitmask to extrapolate the index
        /// of the component tied to the assigned bit in the bitmask.
        inline fn bitInMaskToStorageIndex(self: OpaqueArchetype, comptime bitmask: ComponentMask.Bits) usize {
            comptime {
                if (@popCount(bitmask) != 1) {
                    @compileError("bitInMaskToStorageIndex got a bitmask that did not have a single bit set");
                }
            }

            const new_bitmask = bitmask - 1;
            return @popCount(self.component_bitmask & new_bitmask);
        }
    };
}

const Testing = @import("Testing.zig");
const A = Testing.Component.A;
const B = Testing.Component.B;
const C = Testing.Component.C;
const hashType = @import("query.zig").hashType;

const TestingMask = Testing.ComponentBitmask;
const TestOpaqueArchetype = FromComponentMask(TestingMask);

test "init() + deinit() is idempotent" {
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.None);
    archetype.deinit();
}

test "hasComponent returns expected values" {
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.A);
    defer archetype.deinit();

    try testing.expectEqual(true, archetype.hasComponents(Testing.Bits.A));
    try testing.expectEqual(false, archetype.hasComponents(Testing.Bits.B | Testing.Bits.C));
}

test "getComponent returns expected value ptrs" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    for (0..100) |i| {
        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.registerEntity(
            Entity{ .id = @as(entity_type.EntityId, @intCast(i)) },
            &data,
            sizes,
        );
    }

    const entity = Entity{ .id = 50 };

    try testing.expectEqual(
        A{ .value = @as(u32, @intCast(50)) },
        (try archetype.getComponent(entity, Testing.Bits.A, A)).*,
    );

    try testing.expectEqual(
        B{ .value = @as(u8, @intCast(50)) },
        (try archetype.getComponent(entity, Testing.Bits.B, B)).*,
    );
}

test "setComponent can reassign values" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    for (0..100) |i| {
        const entity = Entity{ .id = @as(entity_type.EntityId, @intCast(i)) };

        const a = A{ .value = @as(u32, @intCast(i)) };
        const b = B{ .value = @as(u8, @intCast(i)) };
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = &[0]u8{};
        try archetype.registerEntity(entity, &data, sizes);

        try archetype.setComponent(entity, A{ .value = 0 }, Testing.Bits.A);
        try archetype.setComponent(entity, B{ .value = 0 }, Testing.Bits.B);
    }

    for (0..100) |i| {
        const entity = Entity{ .id = @as(entity_type.EntityId, @intCast(i)) };

        try testing.expectEqual(
            A{ .value = 0 },
            (try archetype.getComponent(entity, Testing.Bits.A, A)).*,
        );
        try testing.expectEqual(
            B{ .value = 0 },
            (try archetype.getComponent(entity, Testing.Bits.B, B)).*,
        );
    }
}

test "fetchEntityComponentView gives correct component views" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    var buffer: [3][]u8 = undefined;
    for (0..100) |i| {
        const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
        var a = A{ .value = @as(u32, @intCast(i)) };
        buffer[0] = std.mem.asBytes(&a);
        var b = B{ .value = @as(u8, @intCast(i)) };
        buffer[1] = std.mem.asBytes(&b);
        buffer[2] = &[0]u8{};

        try archetype.registerEntity(mock_entity, &buffer, sizes);
    }

    var buf_0: [@sizeOf(A)]u8 = undefined;
    buffer[0] = &buf_0;
    var buf_1: [@sizeOf(B)]u8 = undefined;
    buffer[1] = &buf_1;
    var buf_2: [@sizeOf(C)]u8 = undefined;
    buffer[2] = &buf_2;

    {
        const mock_entity1 = Entity{ .id = 50 };
        try archetype.fetchEntityComponentView(mock_entity1, sizes, &buffer);

        const a = A{ .value = 50 };
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&a),
            buffer[0],
        );

        const b = B{ .value = 50 };
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&b),
            buffer[1],
        );
    }

    {
        const mock_entity2 = Entity{ .id = 51 };
        try archetype.fetchEntityComponentView(mock_entity2, sizes, &buffer);

        const a = A{ .value = 51 };
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&a),
            buffer[0],
        );

        const b = B{ .value = 51 };
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&b),
            buffer[1],
        );
    }
}

test "swapRemoveEntity makes entity invalid for archetype" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    var entities: [100]Entity = undefined;
    var buffer: [3][]u8 = undefined;
    for (&entities, 0..) |*entity, i| {
        entity.* = Entity{ .id = @as(u32, @intCast(i)) };
        var a = A{ .value = @as(u32, @intCast(i)) };
        buffer[0] = std.mem.asBytes(&a);
        var b = B{ .value = @as(u8, @intCast(i)) };
        buffer[1] = std.mem.asBytes(&b);
        buffer[2] = &[0]u8{};

        try archetype.registerEntity(entity.*, &buffer, sizes);
    }

    {
        try archetype.swapRemoveEntity(entities[50], sizes);
        try testing.expectError(error.EntityMissing, archetype.getComponent(
            entities[50],
            Testing.Bits.A,
            A,
        ));
        try testing.expectError(error.EntityMissing, archetype.getComponent(
            entities[50],
            Testing.Bits.B,
            B,
        ));
        try testing.expectError(error.EntityMissing, archetype.getComponent(
            entities[50],
            Testing.Bits.C,
            C,
        ));
    }

    for (entities[0..50], 0..) |entity, i| {
        try testing.expectEqual(A{ .value = @as(u32, @intCast(i)) }, (try archetype.getComponent(
            entity,
            Testing.Bits.A,
            A,
        )).*);
        try testing.expectEqual(B{ .value = @as(u8, @intCast(i)) }, (try archetype.getComponent(
            entity,
            Testing.Bits.B,
            B,
        )).*);
        try testing.expectEqual(C{}, (try archetype.getComponent(
            entity,
            Testing.Bits.C,
            C,
        )).*);
    }

    for (entities[51..], 51..) |entity, i| {
        try testing.expectEqual(A{ .value = @as(u32, @intCast(i)) }, (try archetype.getComponent(
            entity,
            Testing.Bits.A,
            A,
        )).*);
        try testing.expectEqual(B{ .value = @as(u8, @intCast(i)) }, (try archetype.getComponent(
            entity,
            Testing.Bits.B,
            B,
        )).*);
        try testing.expectEqual(C{}, (try archetype.getComponent(
            entity,
            Testing.Bits.C,
            C,
        )).*);
    }
}

test "removeEntity removes entity and components" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    var buffer: [3][]u8 = undefined;
    for (0..100) |i| {
        const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
        var a = A{ .value = @as(u32, @intCast(i)) };
        buffer[0] = std.mem.asBytes(&a);
        var b = B{ .value = @as(u8, @intCast(i)) };
        buffer[1] = std.mem.asBytes(&b);
        buffer[2] = &[0]u8{};

        try archetype.registerEntity(mock_entity, &buffer, sizes);
    }

    {
        const mock_entity1 = Entity{ .id = 50 };
        try archetype.removeEntity(mock_entity1, sizes);

        try testing.expectError(ArchetypeError.EntityMissing, archetype.getComponent(mock_entity1, Testing.Bits.A, A));
    }

    for (0..50) |i| {
        const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
        const a_comp = try archetype.getComponent(mock_entity, Testing.Bits.A, Testing.Component.A);
        try testing.expectEqual(A{ .value = @as(u32, @intCast(i)) }, a_comp.*);

        const b_comp = try archetype.getComponent(mock_entity, Testing.Bits.B, Testing.Component.B);
        try testing.expectEqual(B{ .value = @as(u8, @intCast(i)) }, b_comp.*);

        const c_comp = try archetype.getComponent(mock_entity, Testing.Bits.C, Testing.Component.C);
        try testing.expectEqual(C{}, c_comp.*);
    }

    for (51..100) |i| {
        const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
        const a_comp = try archetype.getComponent(mock_entity, Testing.Bits.A, Testing.Component.A);
        try testing.expectEqual(A{ .value = @as(u32, @intCast(i)) }, a_comp.*);

        const b_comp = try archetype.getComponent(mock_entity, Testing.Bits.B, Testing.Component.B);
        try testing.expectEqual(B{ .value = @as(u8, @intCast(i)) }, b_comp.*);

        const c_comp = try archetype.getComponent(mock_entity, Testing.Bits.C, Testing.Component.C);
        try testing.expectEqual(C{}, c_comp.*);
    }
}

test "getStorageData retrieves components view" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    {
        var buffer: [3][]u8 = undefined;
        for (0..100) |i| {
            const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
            var a = A{ .value = @as(u32, @intCast(i)) };
            buffer[0] = std.mem.asBytes(&a);
            var b = B{ .value = @as(u8, @intCast(i)) };
            buffer[1] = std.mem.asBytes(&b);
            buffer[2] = &[0]u8{};

            try archetype.registerEntity(mock_entity, &buffer, sizes);
        }
    }

    var data: [3][]u8 = undefined;
    var storage = TestOpaqueArchetype.StorageData{
        .inner_len = undefined,
        .outer = &data,
    };
    {
        archetype.getStorageData(&storage, Testing.Bits.A);

        try testing.expectEqual(@as(usize, 100), storage.inner_len);
        {
            for (0..100) |i| {
                const from = i * @sizeOf(Testing.Component.A);
                const to = from + @sizeOf(Testing.Component.A);
                const bytes = storage.outer[0][from..to];
                const a = @as(*const Testing.Component.A, @ptrCast(@alignCast(bytes))).*;
                try testing.expectEqual(Testing.Component.A{ .value = @as(u32, @intCast(i)) }, a);
            }
        }
    }

    archetype.getStorageData(&storage, Testing.Bits.A | Testing.Bits.B);
    try testing.expectEqual(@as(usize, 100), storage.inner_len);

    for (0..100) |i| {
        {
            const from = i * @sizeOf(Testing.Component.A);
            const to = from + @sizeOf(Testing.Component.A);
            const bytes = storage.outer[0][from..to];
            const a = @as(*const Testing.Component.A, @ptrCast(@alignCast(bytes))).*;
            try testing.expectEqual(Testing.Component.A{ .value = @as(u32, @intCast(i)) }, a);
        }

        {
            const from = i * @sizeOf(Testing.Component.B);
            const to = from + @sizeOf(Testing.Component.B);
            const bytes = storage.outer[1][from..to];
            const b = @as(*const Testing.Component.B, @ptrCast(@alignCast(bytes))).*;
            try testing.expectEqual(Testing.Component.B{ .value = @as(u8, @intCast(i)) }, b);
        }
    }
}

test "entity map values are increment of previous" {
    const sizes = comptime [_]u32{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try TestOpaqueArchetype.init(testing.allocator, Testing.Bits.All);
    defer archetype.deinit();

    {
        var buffer: [3][]u8 = undefined;
        for (0..100) |i| {
            const mock_entity = Entity{ .id = @as(u32, @intCast(i)) };
            var a = A{ .value = @as(u32, @intCast(i)) };
            buffer[0] = std.mem.asBytes(&a);
            var b = B{ .value = @as(u8, @intCast(i)) };
            buffer[1] = std.mem.asBytes(&b);
            buffer[2] = &[0]u8{};

            try archetype.registerEntity(mock_entity, &buffer, sizes);
        }
    }

    for (archetype.entities.values(), 0..) |value, index| {
        try testing.expectEqual(index, value);
    }
}
