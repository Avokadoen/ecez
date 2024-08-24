const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const entity_type = @import("entity_type.zig");
const EntityRef = entity_type.EntityRef;
const Entity = entity_type.Entity;

const meta = @import("meta.zig");

// TODO: option to use stack instead of heap

pub const version_major = 0;
pub const version_minor = 3;
pub const version_patch = 0;
pub const alignment = 8;

pub const SerializeError = error{
    OutOfMemory,
};

pub const DeserializeError = error{
    OutOfMemory,
    /// The intial bytes had unexpected content, probably not an ezby file
    UnexpectedEzbyIdentifier,
    /// major, or minor version was not the same
    VersionMismatch,
    /// Missing one or more component types from the serializer type
    UnknownComponentType,
};

// TODO: doc comment
pub const RuntimeSerializeConfig = struct {
    pre_allocation_size: usize = 0,
};

pub const ComptimeSerializeConfig = struct {
    /// Components to not include in the output binary stream.
    ///
    /// NOTE: Keep in mind that archetypes that contain this component will not be serialized:
    ///       All entities in this archetype, and their components will not be serialized.
    culled_component_types: []const type = &[0]type{},
};

// TODO: option to use stack instead of heap
// TODO: heavily hint that arena allocator should be used?
/// Serialize a storage instance to a byte array. The caller owns the returned memory
pub fn serialize(
    comptime Storage: type,
    storage: Storage,
    comptime comptime_config: ComptimeSerializeConfig,
) SerializeError![]const u8 {
    _ = storage; // autofix
    _ = comptime_config; // autofix
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    // unimplemented
    return &[_]u8{};
}

/// Deserialize the supplied bytes and insert them into a storage. This function will
/// clear the storage memory which means that **current storage will be cleared**
pub fn deserialize(comptime Storage: type, storage: *Storage, ezby_bytes: []const u8) DeserializeError!void {
    _ = storage; // autofix
    _ = ezby_bytes; // autofix
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    // unimplemented
    return;
}

pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"), // TODO: only serialize, do not include as runtime data
        version_major: u8,
        version_minor: u8,
        reserved: u16 = 0,
        number_of_entities: u64,
    };

    pub const Comp = packed struct {
        // TODO
    };
};

/// parse EZBY chunk from bytes and return remaining bytes
fn parseEzbyChunk(bytes: []const u8, chunk: **const Chunk.Ezby) error{UnexpectedEzbyIdentifier}![]const u8 {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));

    if (mem.eql(u8, bytes[0..4], "EZBY") == false) {
        return error.UnexpectedEzbyIdentifier;
    }

    chunk.* = @as(*const Chunk.Ezby, @ptrCast(@alignCast(bytes.ptr)));
    return bytes[@sizeOf(Chunk.Ezby)..];
}

fn pow2Align(comptime T: type, num: T, @"align": T) T {
    return (num + @"align" - 1) & ~(@"align" - 1);
}

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = @import("storage.zig").CreateStorage(Testing.AllComponentsTuple);

test "pow2Align return value aligned with 8" {
    try testing.expectEqual(@as(usize, 0), pow2Align(usize, 0, 8));
    for (1..9) |i| {
        try testing.expectEqual(@as(usize, 8), pow2Align(usize, i, 8));
    }
    for (9..17) |i| {
        try testing.expectEqual(@as(usize, 16), pow2Align(usize, i, 8));
    }
    for (17..25) |i| {
        try testing.expectEqual(@as(usize, 24), pow2Align(usize, i, 8));
    }
    for (25..33) |i| {
        try testing.expectEqual(@as(usize, 32), pow2Align(usize, i, 8));
    }
}

test "serializing then using parseEzbyChunk produce expected EZBY chunk" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{});
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = try parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
        .number_of_entities = 0,
    }, ezby.*);
}

test "serialize and deserialize is idempotent" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    const test_data_count = 128;
    var a_as: [test_data_count]Testing.Component.A = undefined;
    var a_entities: [test_data_count]Entity = undefined;

    for (&a_as, &a_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(Testing.Archetype.A{ .a = a.* });
    }

    var ab_as: [test_data_count]Testing.Component.A = undefined;
    var ab_bs: [test_data_count]Testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(
            Testing.Archetype.AB{ .a = a.*, .b = b.* },
        );
    }

    var ac_as: [test_data_count]Testing.Component.A = undefined;
    const ac_cs: Testing.Component.C = .{};
    var ac_entities: [test_data_count]Entity = undefined;
    for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(Testing.Archetype.AC{ .a = a.*, .c = ac_cs });
    }

    var abc_as: [test_data_count]Testing.Component.A = undefined;
    var abc_bs: [test_data_count]Testing.Component.B = undefined;
    const abc_cs: Testing.Component.C = .{};
    var abc_entities: [test_data_count]Entity = undefined;
    for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(
            Testing.Archetype.ABC{ .a = a.*, .b = b.*, .c = abc_cs },
        );
    }

    const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{});
    defer testing.allocator.free(bytes);

    // explicitly clear to ensure there is nothing in the storage
    storage.clearRetainingCapacity();

    try deserialize(StorageStub, &storage, bytes);

    for (a_as, a_entities) |a, a_entity| {
        try testing.expectEqual(a, try storage.getComponent(a_entity, Testing.Component.A));
        try testing.expectError(error.ComponentMissing, storage.getComponent(a_entity, Testing.Component.B));
        try testing.expectError(error.ComponentMissing, storage.getComponent(a_entity, Testing.Component.C));
    }

    for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
        try testing.expectEqual(ab_a, try storage.getComponent(ab_entity, Testing.Component.A));
        try testing.expectEqual(ab_b, try storage.getComponent(ab_entity, Testing.Component.B));
        try testing.expectError(error.ComponentMissing, storage.getComponent(ab_entity, Testing.Component.C));
    }

    for (ac_as, ac_entities) |ac_a, ac_entity| {
        try testing.expectEqual(ac_a, try storage.getComponent(ac_entity, Testing.Component.A));
        try testing.expectError(error.ComponentMissing, storage.getComponent(ac_entity, Testing.Component.B));
        try testing.expectEqual(ac_cs, try storage.getComponent(ac_entity, Testing.Component.C));
    }

    for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
        try testing.expectEqual(abc_a, try storage.getComponent(abc_entity, Testing.Component.A));
        try testing.expectEqual(abc_b, try storage.getComponent(abc_entity, Testing.Component.B));
        try testing.expectEqual(abc_cs, try storage.getComponent(abc_entity, Testing.Component.C));
    }
}

test "serialize with culled_component_types config can be deserialized by other storage type" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    const test_data_count = 128;
    var a_as: [test_data_count]Testing.Component.A = undefined;
    var a_entities: [test_data_count]Entity = undefined;

    for (&a_as, &a_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(Testing.Archetype.A{ .a = a.* });
    }

    var ab_as: [test_data_count]Testing.Component.A = undefined;
    var ab_bs: [test_data_count]Testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(
            Testing.Archetype.AB{ .a = a.*, .b = b.* },
        );
    }

    var ac_as: [test_data_count]Testing.Component.A = undefined;
    const ac_cs: Testing.Component.C = .{};
    var ac_entities: [test_data_count]Entity = undefined;
    for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(Testing.Archetype.AC{ .a = a.*, .c = ac_cs });
    }

    var abc_as: [test_data_count]Testing.Component.A = undefined;
    var abc_bs: [test_data_count]Testing.Component.B = undefined;
    const abc_cs: Testing.Component.C = .{};
    var abc_entities: [test_data_count]Entity = undefined;
    for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(
            Testing.Archetype.ABC{ .a = a.*, .b = b.*, .c = abc_cs },
        );
    }

    // Test with subset AB
    {
        const ABStorage = @import("storage.zig").CreateStorage(.{ Testing.Component.A, Testing.Component.B });

        var ab_storage = try ABStorage.init(testing.allocator);
        defer ab_storage.deinit();

        const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{ .culled_component_types = &[_]type{Testing.Component.C} });
        defer testing.allocator.free(bytes);

        try deserialize(ABStorage, &ab_storage, bytes);

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, try ab_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ab_storage.getComponent(a_entity, Testing.Component.B));
        }

        for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
            try testing.expectEqual(ab_a, try ab_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectEqual(ab_b, try ab_storage.getComponent(ab_entity, Testing.Component.B));
        }

        for (ac_entities) |ac_entity| {
            try testing.expectError(error.ComponentMissing, ab_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ab_storage.getComponent(ac_entity, Testing.Component.B));
        }

        for (abc_entities) |abc_entity| {
            try testing.expectError(error.ComponentMissing, ab_storage.getComponent(abc_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ab_storage.getComponent(abc_entity, Testing.Component.B));
        }
    }

    // Test with subset AC
    {
        const ACStorage = @import("storage.zig").CreateStorage(.{ Testing.Component.A, Testing.Component.C });

        var ac_storage = try ACStorage.init(testing.allocator);
        defer ac_storage.deinit();

        const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{ .culled_component_types = &[_]type{Testing.Component.B} });
        defer testing.allocator.free(bytes);

        try deserialize(ACStorage, &ac_storage, bytes);

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, try ac_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ac_storage.getComponent(a_entity, Testing.Component.C));
        }

        for (ab_entities) |ab_entity| {
            try testing.expectError(error.ComponentMissing, ac_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ac_storage.getComponent(ab_entity, Testing.Component.C));
        }

        for (ac_as, ac_entities) |a, ac_entity| {
            try testing.expectEqual(a, try ac_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectEqual(ac_cs, try ac_storage.getComponent(ac_entity, Testing.Component.C));
        }

        for (abc_entities) |abc_entity| {
            try testing.expectError(error.ComponentMissing, ac_storage.getComponent(abc_entity, Testing.Component.A));
            try testing.expectError(error.ComponentMissing, ac_storage.getComponent(abc_entity, Testing.Component.C));
        }
    }
}
