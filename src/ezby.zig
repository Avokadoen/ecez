const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

const set = @import("sparse_set.zig");

const hashfn: fn (str: []const u8) u64 = std.hash.Fnv1a_64.hash;
pub fn hashType(comptime T: type) u64 {
    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " is not allowed during runtime");
    }

    const type_name = @typeName(T);
    return hashfn(type_name[0..]);
}

// TODO: option to use stack instead of heap

pub const version_major = 1;
pub const version_minor = 4;
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
    allocator: std.mem.Allocator,
    comptime Storage: type,
    storage: Storage,
    comptime comptime_config: ComptimeSerializeConfig,
) SerializeError![]const u8 {
    _ = comptime_config; // autofix
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    const total_byte_size = count_byte_size_blk: {
        var total_size: usize = @sizeOf(Chunk.Ezby);

        inline for (Storage.component_type_array) |Component| {
            const sparse_set: set.SparseSet(EntityId, Component) = @field(
                storage.sparse_sets,
                @typeName(Component),
            );

            total_size += @sizeOf(Chunk.Comp);
            total_size += sparse_set.sparse.len * @sizeOf(EntityId);
            total_size += sparse_set.dense.len * @sizeOf(Component);
        }

        break :count_byte_size_blk total_size;
    };

    var bytes = try allocator.alloc(u8, total_byte_size);
    errdefer allocator.free(bytes);

    // Write to bytes
    {
        var byte_cursor: usize = 0;

        // Write ezby
        const ezby_chunk = Chunk.Ezby{
            .version_major = version_major,
            .version_minor = version_minor,
            .number_of_entities = storage.number_of_entities,
        };
        {
            @memcpy(
                bytes[byte_cursor .. byte_cursor + @sizeOf(Chunk.Ezby)],
                mem.asBytes(&ezby_chunk),
            );
            byte_cursor += @sizeOf(Chunk.Ezby);
        }

        inline for (Storage.component_type_array) |Component| {
            const sparse_set: set.SparseSet(EntityId, Component) = @field(
                storage.sparse_sets,
                @typeName(Component),
            );

            const comp_chunk = Chunk.Comp{
                .comp_count = @intCast(sparse_set.len),
                .type_size = @sizeOf(Component),
                .type_alignment = @alignOf(Component),
                .type_name_hash = hashfn(@typeName(Component)),
            };
            @memcpy(
                bytes[byte_cursor .. byte_cursor + @sizeOf(Chunk.Comp)],
                mem.asBytes(&comp_chunk),
            );
            byte_cursor += @sizeOf(Chunk.Comp);

            std.debug.assert(@sizeOf(Component) == comp_chunk.type_size);
            if (@sizeOf(Component) > 0) {
                const size_of_components = comp_chunk.comp_count * comp_chunk.type_size;
                @memcpy(
                    bytes[byte_cursor .. byte_cursor + size_of_components],
                    std.mem.sliceAsBytes(sparse_set.dense[0..ezby_chunk.number_of_entities]),
                );
                byte_cursor += size_of_components;
            }

            std.debug.assert(ezby_chunk.number_of_entities <= sparse_set.sparse.len);
            const size_of_entities = @sizeOf(EntityId) * ezby_chunk.number_of_entities;
            @memcpy(
                bytes[byte_cursor .. byte_cursor + size_of_entities],
                std.mem.sliceAsBytes(sparse_set.sparse[0..ezby_chunk.number_of_entities]),
            );
            byte_cursor += size_of_entities;
        }
    }

    return bytes;
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

/// ezby v1 files can only have 2 chunks. Ezby chunk is always first, then 1 or many Comp chunks
pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"), // TODO: only serialize, do not include as runtime data
        version_major: u8,
        version_minor: u8,
        padding: u16 = 0,
        number_of_entities: u64,
    };

    pub const Comp = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "COMP"), // TODO: only serialize, do not include as runtime data
        comp_count: u32,
        type_size: u32,
        type_alignment: u32,
        type_name_hash: u64,

        pub const ComponentBytes = []const u8;
        pub const EntityIds = []const EntityId;
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

fn parseCompChunk(
    bytes: []const u8,
    number_of_entities: u64,
    chunk: **const Chunk.Comp,
    component_bytes: *Chunk.Comp.ComponentBytes,
    entity_ids: *Chunk.Comp.EntityIds,
) []const u8 {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Comp));
    std.debug.assert(mem.eql(u8, bytes[0..4], "COMP"));

    chunk.* = @as(
        *const Chunk.Comp,
        @ptrCast(@alignCast(bytes.ptr)),
    );

    var bytes_cursor: usize = @sizeOf(Chunk.Comp);
    const size_of_component_bytes = chunk.*.comp_count * chunk.*.type_size;
    component_bytes.* = bytes[bytes_cursor .. bytes_cursor + size_of_component_bytes];

    bytes_cursor += size_of_component_bytes;
    const size_of_entities = @sizeOf(EntityId) * number_of_entities;
    entity_ids.ptr = @as(
        [*]const EntityId,
        @ptrCast(@alignCast(bytes[bytes_cursor .. bytes_cursor + size_of_entities].ptr)),
    );
    entity_ids.len = @intCast(number_of_entities);

    bytes_cursor += size_of_entities;
    return bytes[bytes_cursor..];
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

    const bytes = try serialize(
        testing.allocator,
        StorageStub,
        storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = try parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
        .number_of_entities = 0,
    }, ezby.*);
}

test parseCompChunk {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..128) |_| {
        _ = try storage.createEntity(.{
            Testing.Component.A{},
            Testing.Component.B{},
            Testing.Component.C{},
        });
    }

    const bytes = try serialize(
        testing.allocator,
        StorageStub,
        storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    var cursor = bytes;

    var ezby: *Chunk.Ezby = undefined;
    cursor = try parseEzbyChunk(cursor, &ezby);

    inline for (Testing.AllComponentsArr) |Component| {
        var comp: *Chunk.Comp = undefined;
        var component_bytes: Chunk.Comp.ComponentBytes = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        cursor = parseCompChunk(
            cursor,
            ezby.number_of_entities,
            &comp,
            &component_bytes,
            &entity_ids,
        );

        try testing.expectEqual(Chunk.Comp{
            .comp_count = 128,
            .type_size = @sizeOf(Component),
            .type_alignment = @alignOf(Component),
            .type_name_hash = comptime hashfn(@typeName(Component)),
        }, comp.*);
    }
}

// test "serialize and deserialize is idempotent" {
//     var storage = try StorageStub.init(std.testing.allocator);
//     defer storage.deinit();

//     const test_data_count = 128;
//     var a_as: [test_data_count]Testing.Component.A = undefined;
//     var a_entities: [test_data_count]Entity = undefined;

//     for (&a_as, &a_entities, 0..) |*a, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         entity.* = try storage.createEntity(Testing.Archetype.A{ .a = a.* });
//     }

//     var ab_as: [test_data_count]Testing.Component.A = undefined;
//     var ab_bs: [test_data_count]Testing.Component.B = undefined;
//     var ab_entities: [test_data_count]Entity = undefined;
//     for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
//         entity.* = try storage.createEntity(
//             Testing.Archetype.AB{ .a = a.*, .b = b.* },
//         );
//     }

//     var ac_as: [test_data_count]Testing.Component.A = undefined;
//     const ac_cs: Testing.Component.C = .{};
//     var ac_entities: [test_data_count]Entity = undefined;
//     for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         entity.* = try storage.createEntity(Testing.Archetype.AC{ .a = a.*, .c = ac_cs });
//     }

//     var abc_as: [test_data_count]Testing.Component.A = undefined;
//     var abc_bs: [test_data_count]Testing.Component.B = undefined;
//     const abc_cs: Testing.Component.C = .{};
//     var abc_entities: [test_data_count]Entity = undefined;
//     for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
//         entity.* = try storage.createEntity(
//             Testing.Archetype.ABC{ .a = a.*, .b = b.*, .c = abc_cs },
//         );
//     }

//     const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{});
//     defer testing.allocator.free(bytes);

//     // explicitly clear to ensure there is nothing in the storage
//     storage.clearRetainingCapacity();

//     try deserialize(StorageStub, &storage, bytes);

//     for (a_as, a_entities) |a, a_entity| {
//         try testing.expectEqual(a, try storage.getComponent(a_entity, Testing.Component.A));
//         try testing.expectError(error.ComponentMissing, storage.getComponent(a_entity, Testing.Component.B));
//         try testing.expectError(error.ComponentMissing, storage.getComponent(a_entity, Testing.Component.C));
//     }

//     for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
//         try testing.expectEqual(ab_a, try storage.getComponent(ab_entity, Testing.Component.A));
//         try testing.expectEqual(ab_b, try storage.getComponent(ab_entity, Testing.Component.B));
//         try testing.expectError(error.ComponentMissing, storage.getComponent(ab_entity, Testing.Component.C));
//     }

//     for (ac_as, ac_entities) |ac_a, ac_entity| {
//         try testing.expectEqual(ac_a, try storage.getComponent(ac_entity, Testing.Component.A));
//         try testing.expectError(error.ComponentMissing, storage.getComponent(ac_entity, Testing.Component.B));
//         try testing.expectEqual(ac_cs, try storage.getComponent(ac_entity, Testing.Component.C));
//     }

//     for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
//         try testing.expectEqual(abc_a, try storage.getComponent(abc_entity, Testing.Component.A));
//         try testing.expectEqual(abc_b, try storage.getComponent(abc_entity, Testing.Component.B));
//         try testing.expectEqual(abc_cs, try storage.getComponent(abc_entity, Testing.Component.C));
//     }
// }

// test "serialize with culled_component_types config can be deserialized by other storage type" {
//     var storage = try StorageStub.init(std.testing.allocator);
//     defer storage.deinit();

//     const test_data_count = 128;
//     var a_as: [test_data_count]Testing.Component.A = undefined;
//     var a_entities: [test_data_count]Entity = undefined;

//     for (&a_as, &a_entities, 0..) |*a, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         entity.* = try storage.createEntity(Testing.Archetype.A{ .a = a.* });
//     }

//     var ab_as: [test_data_count]Testing.Component.A = undefined;
//     var ab_bs: [test_data_count]Testing.Component.B = undefined;
//     var ab_entities: [test_data_count]Entity = undefined;
//     for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
//         entity.* = try storage.createEntity(
//             Testing.Archetype.AB{ .a = a.*, .b = b.* },
//         );
//     }

//     var ac_as: [test_data_count]Testing.Component.A = undefined;
//     const ac_cs: Testing.Component.C = .{};
//     var ac_entities: [test_data_count]Entity = undefined;
//     for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         entity.* = try storage.createEntity(Testing.Archetype.AC{ .a = a.*, .c = ac_cs });
//     }

//     var abc_as: [test_data_count]Testing.Component.A = undefined;
//     var abc_bs: [test_data_count]Testing.Component.B = undefined;
//     const abc_cs: Testing.Component.C = .{};
//     var abc_entities: [test_data_count]Entity = undefined;
//     for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
//         a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
//         b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
//         entity.* = try storage.createEntity(
//             Testing.Archetype.ABC{ .a = a.*, .b = b.*, .c = abc_cs },
//         );
//     }

//     // Test with subset AB
//     {
//         const ABStorage = @import("storage.zig").CreateStorage(.{ Testing.Component.A, Testing.Component.B });

//         var ab_storage = try ABStorage.init(testing.allocator);
//         defer ab_storage.deinit();

//         const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{ .culled_component_types = &[_]type{Testing.Component.C} });
//         defer testing.allocator.free(bytes);

//         try deserialize(ABStorage, &ab_storage, bytes);

//         for (a_as, a_entities) |a, a_entity| {
//             try testing.expectEqual(a, try ab_storage.getComponent(a_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ab_storage.getComponent(a_entity, Testing.Component.B));
//         }

//         for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
//             try testing.expectEqual(ab_a, try ab_storage.getComponent(ab_entity, Testing.Component.A));
//             try testing.expectEqual(ab_b, try ab_storage.getComponent(ab_entity, Testing.Component.B));
//         }

//         for (ac_entities) |ac_entity| {
//             try testing.expectError(error.ComponentMissing, ab_storage.getComponent(ac_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ab_storage.getComponent(ac_entity, Testing.Component.B));
//         }

//         for (abc_entities) |abc_entity| {
//             try testing.expectError(error.ComponentMissing, ab_storage.getComponent(abc_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ab_storage.getComponent(abc_entity, Testing.Component.B));
//         }
//     }

//     // Test with subset AC
//     {
//         const ACStorage = @import("storage.zig").CreateStorage(.{ Testing.Component.A, Testing.Component.C });

//         var ac_storage = try ACStorage.init(testing.allocator);
//         defer ac_storage.deinit();

//         const bytes = try serialize(StorageStub, testing.allocator, storage, .{}, .{ .culled_component_types = &[_]type{Testing.Component.B} });
//         defer testing.allocator.free(bytes);

//         try deserialize(ACStorage, &ac_storage, bytes);

//         for (a_as, a_entities) |a, a_entity| {
//             try testing.expectEqual(a, try ac_storage.getComponent(a_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ac_storage.getComponent(a_entity, Testing.Component.C));
//         }

//         for (ab_entities) |ab_entity| {
//             try testing.expectError(error.ComponentMissing, ac_storage.getComponent(ab_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ac_storage.getComponent(ab_entity, Testing.Component.C));
//         }

//         for (ac_as, ac_entities) |a, ac_entity| {
//             try testing.expectEqual(a, try ac_storage.getComponent(ac_entity, Testing.Component.A));
//             try testing.expectEqual(ac_cs, try ac_storage.getComponent(ac_entity, Testing.Component.C));
//         }

//         for (abc_entities) |abc_entity| {
//             try testing.expectError(error.ComponentMissing, ac_storage.getComponent(abc_entity, Testing.Component.A));
//             try testing.expectError(error.ComponentMissing, ac_storage.getComponent(abc_entity, Testing.Component.C));
//         }
//     }
// }
