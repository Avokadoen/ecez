const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const entity_type = @import("entity_type.zig");

const IArchetype = @import("IArchetype.zig");
const Color = @import("misc.zig").Color;
const Entity = entity_type.Entity;
const EntityMap = entity_type.Map;

const TypeInfo = struct {
    storage_index: usize,
    size: usize,
};
const TypeContext = struct {
    pub fn hash(self: TypeContext, k: u64) u32 {
        _ = self;
        // id is already unique
        return @intCast(u32, k);
    }
    pub fn eql(self: TypeContext, e1: u64, e2: u64, index: usize) bool {
        _ = self;
        _ = index;
        return e1 == e2;
    }
};
const TypeMap = std.ArrayHashMap(u64, TypeInfo, TypeContext, false);

const OpaqueArchetype = @This();

allocator: Allocator,

entities: EntityMap,

type_info: TypeMap,
component_storage: []ArrayList(u8),

pub fn init(allocator: Allocator, type_hashes: []const u64, type_sizes: []const usize) !OpaqueArchetype {
    std.debug.assert(type_hashes.len == type_sizes.len);

    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype init", Color.opaque_archetype);
    defer zone.End();

    var type_info = TypeMap.init(allocator);
    errdefer type_info.deinit();

    try type_info.ensureTotalCapacity(type_hashes.len);
    for (type_hashes) |hash, i| {
        type_info.putAssumeCapacity(hash, TypeInfo{
            .storage_index = i,
            .size = type_sizes[i],
        });
    }

    var component_storage = try allocator.alloc(ArrayList(u8), type_hashes.len);
    errdefer allocator.free(component_storage);

    for (component_storage) |*component_buffer| {
        component_buffer.* = ArrayList(u8).init(allocator);
    }

    return OpaqueArchetype{
        .allocator = allocator,
        .entities = EntityMap.init(allocator),
        .type_info = type_info,
        .component_storage = component_storage,
    };
}

pub fn deinit(self: *OpaqueArchetype) void {
    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype deinit", Color.opaque_archetype);
    defer zone.End();

    self.entities.deinit();
    self.type_info.deinit();
    for (self.component_storage) |component_buffer| {
        component_buffer.deinit();
    }
    self.allocator.free(self.component_storage);
}

/// get the archetype dynamic dispatch interface
pub fn archetypeInterface(self: *OpaqueArchetype) IArchetype {
    return IArchetype.init(
        self,
        rawHasComponent,
        rawGetComponent,
        rawSetComponent,
        rawRegisterEntity,
        rawSwapRemoveEntity,
        rawGetStorageData,
        deinit,
    );
}

/// Implementation of IArchetype hasComponent
pub fn rawHasComponent(self: *OpaqueArchetype, type_hash: u64) bool {
    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype rawHasComponent", Color.opaque_archetype);
    defer zone.End();

    _ = self.type_info.get(type_hash) orelse {
        return false;
    };
    return true;
}

/// Retrieve a component value as bytes from a given entity
pub fn rawGetComponent(self: *OpaqueArchetype, entity: Entity, type_hash: u64) IArchetype.Error![]const u8 {
    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype rawGetComponent", Color.opaque_archetype);
    defer zone.End();

    const component_info = self.type_info.get(type_hash) orelse {
        return IArchetype.Error.ComponentMissing; // Component type not part of archetype
    };

    const entity_index = self.entities.get(entity) orelse {
        return IArchetype.Error.EntityMissing; // Entity not part of archetype
    };

    const bytes_from = entity_index * component_info.size;
    const bytes_to = bytes_from + component_info.size;

    return self.component_storage[component_info.storage_index].items[bytes_from..bytes_to];
}

pub fn rawSetComponent(self: *OpaqueArchetype, entity: Entity, type_hash: u64, component: []const u8) IArchetype.Error!void {
    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype rawSetComponent", Color.opaque_archetype);
    defer zone.End();

    const component_info = self.type_info.get(type_hash) orelse {
        return IArchetype.Error.ComponentMissing; // Component type not part of archetype
    };
    std.debug.assert(component_info.size == component.len);

    const entity_index = self.entities.get(entity) orelse {
        return IArchetype.Error.EntityMissing; // Entity not part of archetype
    };

    const bytes_from = entity_index * component_info.size;

    std.mem.copy(u8, self.component_storage[component_info.storage_index].items[bytes_from..], component);
}

pub fn rawRegisterEntity(self: *OpaqueArchetype, entity: Entity, data: []const []const u8) IArchetype.Error!void {
    std.debug.assert(data.len == self.component_storage.len);

    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype rawRegisterEntity", Color.opaque_archetype);
    defer zone.End();

    const value = self.entities.count();
    try self.entities.put(entity, value);
    errdefer _ = self.entities.swapRemove(entity);

    var appended_component: usize = 0;
    errdefer {
        var iter = self.type_info.iterator();
        while (iter.next()) |info| {
            if (appended_component == 0) break;

            const new_len = self.component_storage[appended_component - 1].items.len - info.value_ptr.size;
            self.component_storage[appended_component - 1].resize(new_len) catch unreachable;

            appended_component -= 1;
        }
    }

    for (data) |component_bytes, i| {
        try self.component_storage[i].appendSlice(component_bytes);
        appended_component = i;
    }
}

pub fn rawSwapRemoveEntity(self: *OpaqueArchetype, entity: Entity, buffer: [][]u8) IArchetype.Error!void {
    std.debug.assert(buffer.len == self.component_storage.len);

    const zone = ztracy.ZoneNC(@src(), "OpaqueArchetype rawSwapRemoveEntity", Color.opaque_archetype);
    defer zone.End();

    // remove entity from
    const moving_kv = self.entities.fetchSwapRemove(entity) orelse return IArchetype.Error.EntityMissing;

    // move entity data to buffers
    {
        var i: usize = 0;
        var iter = self.type_info.iterator();
        while (iter.next()) |info| {
            if (info.value_ptr.size == 0) {
                const Empty = struct {};
                const component = Empty{};
                std.mem.copy(u8, buffer[i], std.mem.asBytes(&component));
            } else {
                // copy data to buffer
                const from_bytes = moving_kv.value * info.value_ptr.size;
                const to_bytes = from_bytes + info.value_ptr.size;
                const component = self.component_storage[i].items[from_bytes..to_bytes];
                std.mem.copy(u8, buffer[i], component);

                // remove data from storage
                {
                    // shift data to the left (moving extracted bytes to the end of the array)
                    std.mem.rotate(u8, self.component_storage[i].items[from_bytes..], info.value_ptr.size);

                    // mark extracted bytes as invalid
                    const new_len = self.component_storage[i].items.len - info.value_ptr.size;
                    // new_len is always less than previous len, so it can't fail
                    self.component_storage[i].resize(new_len) catch unreachable;
                }
            }
            i += 1;
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

pub fn rawGetStorageData(self: *OpaqueArchetype, component_hashes: []u64, storage: *IArchetype.StorageData) IArchetype.Error!void {
    std.debug.assert(component_hashes.len <= storage.outer.len);

    var stored_hashes: usize = 0;
    var iter = self.type_info.iterator();
    while (iter.next()) |info| {
        const iter_hash = info.key_ptr.*;
        const iter_size = info.value_ptr.size;
        for (component_hashes[0..]) |hash, hash_index| {
            if (iter_hash == hash) {
                if (iter_size > 0) {
                    storage.outer[hash_index] = self.component_storage[hash_index].items;
                }
                stored_hashes += 1;
            }
        }
    }
    storage.inner_len = self.entities.count();

    if (stored_hashes != component_hashes.len) {
        return IArchetype.Error.ComponentMissing;
    }
}

const Testing = @import("Testing.zig");
const A = Testing.Component.A;
const B = Testing.Component.B;
const C = Testing.Component.C;
const hashType = @import("query.zig").hashType;

test "init() + deinit() is idempotent" {
    var archetype = try OpaqueArchetype.init(testing.allocator, &[_]u64{ 0, 1, 2 }, &[_]usize{ 0, 1, 2 });
    archetype.deinit();
}

test "rawHasComponent identify existing components" {
    var archetype = try OpaqueArchetype.init(testing.allocator, &[_]u64{ 0, 1 }, &[_]usize{ 0, 1 });
    defer archetype.deinit();
    try testing.expectEqual(true, archetype.rawHasComponent(0));
    try testing.expectEqual(true, archetype.rawHasComponent(1));
    try testing.expectEqual(false, archetype.rawHasComponent(2));
}

test "rawGetComponent retrieves correct component" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const a = A{ .value = @intCast(u32, i) };
        const b = B{ .value = @intCast(u8, i) };
        const c = C{};
        var data: [3][]const u8 = undefined;
        data[0] = std.mem.asBytes(&a);
        data[1] = std.mem.asBytes(&b);
        data[2] = std.mem.asBytes(&c);
        try archetype.rawRegisterEntity(Entity{ .id = @intCast(entity_type.EntityId, i) }, &data);
    }

    const entity = Entity{ .id = 50 };

    const a = A{ .value = @intCast(u32, 50) };
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&a),
        try archetype.rawGetComponent(entity, comptime hashType(A)),
    );

    const b = B{ .value = @intCast(u8, 50) };
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&b),
        try archetype.rawGetComponent(entity, comptime hashType(B)),
    );

    const c = C{};
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&c),
        try archetype.rawGetComponent(entity, comptime hashType(C)),
    );
}

test "rawGetComponent fails on invalid request" {
    const hashes = comptime [_]u64{hashType(C)};
    const sizes = comptime [_]usize{@sizeOf(C)};

    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    const entity = Entity{ .id = 0 };
    const c = C{};
    var data: [1][]const u8 = undefined;
    data[0] = std.mem.asBytes(&c);
    try archetype.rawRegisterEntity(entity, &data);

    try testing.expectError(IArchetype.Error.ComponentMissing, archetype.rawGetComponent(entity, comptime hashType(Testing.Component.A)));
    try testing.expectError(IArchetype.Error.EntityMissing, archetype.rawGetComponent(Entity{ .id = 1 }, comptime hashType(C)));
}

test "rawSwapRemoveEntity removes entity and components" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };

    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    var buffer: [3][]u8 = undefined;
    {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            const mock_entity = Entity{ .id = i };
            var a = A{ .value = i };
            buffer[0] = std.mem.asBytes(&a);
            var b = B{ .value = @intCast(u8, i) };
            buffer[1] = std.mem.asBytes(&b);
            var c = C{};
            buffer[2] = std.mem.asBytes(&c);

            try archetype.rawRegisterEntity(mock_entity, &buffer);
        }
    }

    var buf_0: [@sizeOf(A)]u8 = undefined;
    buffer[0] = &buf_0;
    var buf_1: [@sizeOf(B)]u8 = undefined;
    buffer[1] = &buf_1;
    var buf_2: [@sizeOf(C)]u8 = undefined;
    buffer[2] = &buf_2;

    {
        const mock_entity1 = Entity{ .id = 50 };
        try archetype.rawSwapRemoveEntity(mock_entity1, &buffer);

        try testing.expectError(IArchetype.Error.EntityMissing, archetype.rawGetComponent(
            mock_entity1,
            comptime hashType(A),
        ));

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

        const c = C{};
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&c),
            buffer[2],
        );
    }

    {
        const mock_entity2 = Entity{ .id = 51 };
        try archetype.rawSwapRemoveEntity(mock_entity2, &buffer);

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

        const c = C{};
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&c),
            buffer[2],
        );
    }
}

test "rawGetStorageData retrieves components view" {
    const hashes = comptime [_]u64{ hashType(A), hashType(B), hashType(C) };
    const sizes = comptime [_]usize{ @sizeOf(A), @sizeOf(B), @sizeOf(C) };
    var archetype = try OpaqueArchetype.init(testing.allocator, &hashes, &sizes);
    defer archetype.deinit();

    {
        var i: u32 = 0;
        var buffer: [3][]u8 = undefined;
        while (i < 100) : (i += 1) {
            const mock_entity = Entity{ .id = i };
            var a = A{ .value = i };
            buffer[0] = std.mem.asBytes(&a);
            var b = B{ .value = @intCast(u8, i) };
            buffer[1] = std.mem.asBytes(&b);
            var c = C{};
            buffer[2] = std.mem.asBytes(&c);

            try archetype.rawRegisterEntity(mock_entity, &buffer);
        }
    }

    var data: [3][]u8 = undefined;
    var storage = IArchetype.StorageData{
        .inner_len = undefined,
        .outer = &data,
    };
    {
        try archetype.rawGetStorageData(&[_]u64{hashType(Testing.Component.A)}, &storage);

        try testing.expectEqual(@as(usize, 100), storage.inner_len);
        {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                const from = i * @sizeOf(Testing.Component.A);
                const to = from + @sizeOf(Testing.Component.A);
                const bytes = storage.outer[0][from..to];
                const a = @ptrCast(*const Testing.Component.A, @alignCast(@alignOf(Testing.Component.A), bytes)).*;
                try testing.expectEqual(Testing.Component.A{ .value = i }, a);
            }
        }
    }

    try archetype.rawGetStorageData(&[_]u64{ hashType(Testing.Component.A), hashType(Testing.Component.B) }, &storage);
    try testing.expectEqual(@as(usize, 100), storage.inner_len);
    {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            {
                const from = i * @sizeOf(Testing.Component.A);
                const to = from + @sizeOf(Testing.Component.A);
                const bytes = storage.outer[0][from..to];
                const a = @ptrCast(*const Testing.Component.A, @alignCast(@alignOf(Testing.Component.A), bytes)).*;
                try testing.expectEqual(Testing.Component.A{ .value = i }, a);
            }

            {
                const from = i * @sizeOf(Testing.Component.B);
                const to = from + @sizeOf(Testing.Component.B);
                const bytes = storage.outer[1][from..to];
                const b = @ptrCast(*const Testing.Component.B, @alignCast(@alignOf(Testing.Component.B), bytes)).*;
                try testing.expectEqual(Testing.Component.B{ .value = @intCast(u8, i) }, b);
            }
        }
    }
}
