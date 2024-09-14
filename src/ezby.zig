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
pub fn hashTypeName(comptime T: type) u64 {
    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " is not allowed during runtime");
    }

    const type_name = @typeName(T);
    return hashfn(type_name[0..]);
}

// TODO: option to use stack instead of heap

pub const version_major = 1;
pub const version_minor = 0;
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
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    const number_of_entities = storage.number_of_entities.load(.unordered);
    const total_byte_size = count_byte_size_blk: {
        var total_size: usize = @sizeOf(Chunk.Ezby);
        std.debug.assert(total_size == std.mem.alignForward(usize, total_size, alignment));

        inline for (Storage.component_type_array) |Component| {
            const cull_component = comptime check_if_cull_needed_blk: {
                for (comptime_config.culled_component_types) |CullComponent| {
                    if (Component == CullComponent) {
                        break :check_if_cull_needed_blk true;
                    }
                }
                break :check_if_cull_needed_blk false;
            };

            total_size += @sizeOf(Chunk.Comp);

            {
                const sparse_set = storage.getSparseSetConstPtr(Component);
                total_size += sparse_set.sparse_len * @sizeOf(EntityId);
            }

            if (cull_component == false) {
                const dense_set = storage.getDenseSetConstPtr(Component);
                total_size += dense_set.dense_len * @sizeOf(Component);
            }

            // Align comp chunk
            total_size = std.mem.alignForward(usize, total_size, alignment);
        }

        break :count_byte_size_blk total_size;
    };

    // We allocate in long words for alignment reasons (ensure 8 byte alignment)

    const bytes = try allocator.alloc(u8, total_byte_size);
    errdefer allocator.free(bytes);

    // Write to bytes
    {
        var byte_cursor: usize = 0;

        // Write ezby
        const ezby_chunk = Chunk.Ezby{
            .version_major = version_major,
            .version_minor = version_minor,
            .number_of_entities = number_of_entities,
        };
        {
            @memcpy(
                bytes[byte_cursor .. byte_cursor + @sizeOf(Chunk.Ezby)],
                mem.asBytes(&ezby_chunk),
            );
            byte_cursor += @sizeOf(Chunk.Ezby);
        }

        inline for (Storage.component_type_array, 0..) |Component, comp_index| {
            const sparse_set = storage.getSparseSetConstPtr(Component);
            const dense_set = storage.getDenseSetConstPtr(Component);

            const cull_component = comptime check_if_cull_needed_blk: {
                for (comptime_config.culled_component_types) |CullComponent| {
                    if (Component == CullComponent) {
                        break :check_if_cull_needed_blk true;
                    }
                }
                break :check_if_cull_needed_blk false;
            };

            const comp_chunk = Chunk.Comp{
                .entity_count = if (cull_component) 0 else @intCast(sparse_set.sparse_len),
                .comp_count = if (cull_component) 0 else @intCast(dense_set.dense_len),
                .type_size = @sizeOf(Component),
                .type_alignment = @alignOf(Component),
                .type_name_hash = hashfn(@typeName(Component)),
            };

            // Write base comp chunk
            {
                const comp_chunk_bytes = bytes[byte_cursor .. byte_cursor + @sizeOf(Chunk.Comp)];
                byte_cursor += @sizeOf(Chunk.Comp);
                @memcpy(
                    comp_chunk_bytes,
                    mem.asBytes(&comp_chunk),
                );
            }

            // Write EntityIds
            {
                if (comp_chunk.entity_count > 0) {
                    const size_of_entities = @sizeOf(EntityId) * comp_chunk.entity_count;
                    const sparse_bytes = bytes[byte_cursor .. byte_cursor + size_of_entities];
                    byte_cursor += size_of_entities;

                    if (cull_component) {
                        std.debug.assert(set.Sparse.not_set == std.math.maxInt(EntityId));
                        const not_set_byte = 0b1111_1111;
                        @memset(sparse_bytes, not_set_byte);
                    } else {
                        @memcpy(
                            sparse_bytes,
                            std.mem.sliceAsBytes(sparse_set.sparse[0..comp_chunk.entity_count]),
                        );
                    }
                }
            }

            // Write ComponentBytes
            {
                std.debug.assert(@sizeOf(Component) == comp_chunk.type_size);
                if (@sizeOf(Component) > 0) {
                    if (comp_chunk.comp_count > 0) {
                        const size_of_components = comp_chunk.comp_count * comp_chunk.type_size;
                        const dense_bytes = bytes[byte_cursor .. byte_cursor + size_of_components];
                        byte_cursor += size_of_components;

                        @memcpy(
                            dense_bytes,
                            std.mem.sliceAsBytes(dense_set.dense[0..comp_chunk.comp_count]),
                        );
                    }
                }
            }

            // if its not the last chunk, align cursor
            if (Storage.component_type_array.len - 1 != comp_index) {
                byte_cursor = std.mem.alignForward(usize, byte_cursor, alignment);
            }
        }
    }

    return bytes;
}

/// Deserialize the supplied bytes and insert them into a storage. This function will
/// clear the storage memory which means that **current storage will be cleared**
///
/// In the event of error, the storage will be empty
pub fn deserialize(
    comptime Storage: type,
    storage: *Storage,
    ezby_bytes: []const u8,
) DeserializeError!void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    storage.clearRetainingCapacity();
    errdefer storage.clearRetainingCapacity();

    var cursor = ezby_bytes;

    var ezby: *Chunk.Ezby = undefined;
    cursor = try Chunk.parseEzby(cursor, &ezby);

    if (ezby.version_major != version_major) {
        return error.VersionMismatch;
    }

    storage.number_of_entities.store(@intCast(ezby.number_of_entities), .seq_cst);

    while (cursor.len > @sizeOf(Chunk.Comp) and mem.eql(u8, cursor[0..4], "COMP")) {
        var comp: *Chunk.Comp = undefined;
        var component_bytes: Chunk.Comp.ComponentBytes = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        cursor = Chunk.parseComp(
            cursor,
            &comp,
            &entity_ids,
            &component_bytes,
        );

        // TODO: not good ...
        inline for (Storage.component_type_array) |Component| {
            const type_hash = comptime hashTypeName(Component);
            if (type_hash == comp.type_name_hash) {
                std.debug.assert(comp.type_size == @sizeOf(Component));
                std.debug.assert(comp.type_alignment == @alignOf(Component));

                const sparse_set = storage.getSparseSetPtr(Component);
                const dense_set = storage.getDenseSetPtr(Component);

                dense_set.dense_len = comp.comp_count;

                // Set sparse
                try sparse_set.grow(storage.allocator, comp.entity_count);
                @memcpy(sparse_set.sparse[0..entity_ids.len], entity_ids);

                if (@sizeOf(Component) > 0) {
                    const component_data = std.mem.bytesAsSlice(Component, component_bytes);
                    // set dense
                    try dense_set.grow(storage.allocator, comp.comp_count);
                    @memcpy(dense_set.dense[0..component_data.len], component_data);
                }
            }
        }
    }
}

/// ezby v1 files can only have 2 chunks. Ezby chunk is always first, then 1 or many Comp chunks
pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"),
        version_major: u16,
        version_minor: u16,
        number_of_entities: u64,
    };

    pub const Comp = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "COMP"),
        padding: u32 = 0,
        entity_count: u32,
        comp_count: u32,
        type_size: u32,
        type_alignment: u32,
        type_name_hash: u64,

        pub const EntityIds = []const EntityId;
        pub const ComponentBytes = []const u8;
    };

    /// parse EZBY chunk from bytes and return remaining bytes
    fn parseEzby(bytes: []const u8, chunk: **const Chunk.Ezby) error{UnexpectedEzbyIdentifier}![]const u8 {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
        defer zone.End();

        std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));

        if (mem.eql(u8, bytes[0..4], "EZBY") == false) {
            return error.UnexpectedEzbyIdentifier;
        }

        chunk.* = @as(*const Chunk.Ezby, @ptrCast(@alignCast(bytes.ptr)));
        return bytes[@sizeOf(Chunk.Ezby)..];
    }

    fn parseComp(
        bytes: []const u8,
        chunk: **const Chunk.Comp,
        entity_ids: *Chunk.Comp.EntityIds,
        component_bytes: *Chunk.Comp.ComponentBytes,
    ) []const u8 {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
        defer zone.End();

        std.debug.assert(mem.eql(u8, bytes[0..4], "COMP"));

        var bytes_cursor: usize = parse_comp_chunk_blk: {
            chunk.* = @as(
                *const Chunk.Comp,
                @ptrCast(@alignCast(bytes.ptr)),
            );
            break :parse_comp_chunk_blk @sizeOf(Chunk.Comp);
        };

        bytes_cursor += parse_entity_ids_blk: {
            const size_of_entity_ids = @sizeOf(EntityId) * chunk.*.entity_count;
            entity_ids.ptr = @as(
                [*]const EntityId,
                @ptrCast(@alignCast(bytes[bytes_cursor .. bytes_cursor + size_of_entity_ids].ptr)),
            );
            entity_ids.len = @intCast(chunk.*.entity_count);

            break :parse_entity_ids_blk size_of_entity_ids;
        };

        bytes_cursor += parse_component_bytes_blk: {
            const size_of_component_bytes = chunk.*.comp_count * chunk.*.type_size;
            component_bytes.* = bytes[bytes_cursor .. bytes_cursor + size_of_component_bytes];

            break :parse_component_bytes_blk size_of_component_bytes;
        };

        const aligned_cursor = std.mem.alignForward(usize, bytes_cursor, 8);
        return bytes[aligned_cursor..];
    }
};

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = @import("storage.zig").CreateStorage(Testing.AllComponentsTuple);

test "serializing then using Chunk.parseEzby produce expected EZBY chunk" {
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
    _ = try Chunk.parseEzby(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
        .number_of_entities = 0,
    }, ezby.*);
}

test "Chunk.parseComp" {
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
    cursor = try Chunk.parseEzby(cursor, &ezby);

    inline for (Testing.AllComponentsArr) |Component| {
        var comp: *Chunk.Comp = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        var component_bytes: Chunk.Comp.ComponentBytes = undefined;
        cursor = Chunk.parseComp(
            cursor,
            &comp,
            &entity_ids,
            &component_bytes,
        );

        try testing.expectEqual(Chunk.Comp{
            .entity_count = 128,
            .comp_count = 128,
            .type_size = @sizeOf(Component),
            .type_alignment = @alignOf(Component),
            .type_name_hash = comptime hashfn(@typeName(Component)),
        }, comp.*);
    }
}

test "serialize and deserialized is idempotent" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    const test_data_count = 128;

    var a_as: [test_data_count]Testing.Component.A = undefined;
    var a_entities: [test_data_count]Entity = undefined;
    for (&a_as, &a_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(.{a.*});
    }

    var ab_as: [test_data_count]Testing.Component.A = undefined;
    var ab_bs: [test_data_count]Testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, b.* });
    }

    var ac_as: [test_data_count]Testing.Component.A = undefined;
    const ac_cs: Testing.Component.C = .{};
    var ac_entities: [test_data_count]Entity = undefined;
    for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, ac_cs });
    }

    var abc_as: [test_data_count]Testing.Component.A = undefined;
    var abc_bs: [test_data_count]Testing.Component.B = undefined;
    const abc_cs: Testing.Component.C = .{};
    var abc_entities: [test_data_count]Entity = undefined;
    for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, b.*, abc_cs });
    }

    const bytes = try serialize(
        testing.allocator,
        StorageStub,
        storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    try deserialize(
        StorageStub,
        &storage,
        bytes,
    );

    for (a_as, a_entities) |a, a_entity| {
        try testing.expectEqual(a, try storage.getComponent(a_entity, Testing.Component.A));
        try testing.expectError(error.MissingComponent, storage.getComponent(a_entity, Testing.Component.B));
        try testing.expectError(error.MissingComponent, storage.getComponent(a_entity, Testing.Component.C));
    }

    for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
        const ab = try storage.getComponents(ab_entity, Testing.Structure.AB);
        try testing.expectEqual(ab_a, ab.a);
        try testing.expectEqual(ab_b, ab.b);
        try testing.expectError(error.MissingComponent, storage.getComponent(ab_entity, Testing.Component.C));
    }

    for (ac_as, ac_entities) |ac_a, ac_entity| {
        const ac = try storage.getComponents(ac_entity, Testing.Structure.AC);
        try testing.expectEqual(ac_a, ac.a);
        try testing.expectError(error.MissingComponent, storage.getComponent(ac_entity, Testing.Component.B));
        try testing.expectEqual(ac_cs, ac.c);
    }

    for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
        const abc = try storage.getComponents(abc_entity, Testing.Structure.ABC);
        try testing.expectEqual(abc_a, abc.a);
        try testing.expectEqual(abc_b, abc.b);
        try testing.expectEqual(abc_cs, abc.c);
    }
}

test "deserialized single entity works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    const a = Testing.Component.A{ .value = 42 };
    const entity = try storage.createEntity(.{a});

    const bytes = try serialize(
        testing.allocator,
        StorageStub,
        storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    storage.clearRetainingCapacity();

    try deserialize(
        StorageStub,
        &storage,
        bytes,
    );

    try testing.expectEqual(
        a,
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "serialize and deserialized with types of higher alignment works" {
    const Vector = struct { v: @Vector(8, u64) };

    const TestStorage = @import("storage.zig").CreateStorage(.{
        Testing.Component.A,
        Testing.Component.B,
        Vector,
    });

    var storage = try TestStorage.init(std.testing.allocator);
    defer storage.deinit();

    const test_data_count = 128;

    var a_as: [test_data_count]Testing.Component.A = undefined;
    var a_entities: [test_data_count]Entity = undefined;
    for (&a_as, &a_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(.{a.*});
    }

    var ab_as: [test_data_count]Testing.Component.A = undefined;
    var ab_bs: [test_data_count]Testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, b.* });
    }

    var av_as: [test_data_count]Testing.Component.A = undefined;
    var av_vs: [test_data_count]Vector = undefined;
    var av_entities: [test_data_count]Entity = undefined;
    for (&av_as, &av_vs, &av_entities, 0..) |*a, *v, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        v.* = Vector{ .v = @splat(index) };
        entity.* = try storage.createEntity(.{ a.*, v.* });
    }

    var abv_as: [test_data_count]Testing.Component.A = undefined;
    var abv_bs: [test_data_count]Testing.Component.B = undefined;
    var abv_vs: [test_data_count]Vector = undefined;
    var abv_entities: [test_data_count]Entity = undefined;
    for (&abv_as, &abv_bs, &abv_vs, &abv_entities, 0..) |*a, *b, *v, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        v.* = Vector{ .v = @splat(index) };
        entity.* = try storage.createEntity(.{ a.*, b.*, v.* });
    }

    const bytes = try serialize(
        testing.allocator,
        TestStorage,
        storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    try deserialize(
        TestStorage,
        &storage,
        bytes,
    );

    for (a_as, a_entities) |a, a_entity| {
        try testing.expectEqual(a, try storage.getComponent(a_entity, Testing.Component.A));
        try testing.expectError(error.MissingComponent, storage.getComponent(a_entity, Vector));
        try testing.expectError(error.MissingComponent, storage.getComponent(a_entity, Testing.Component.B));
    }

    for (av_as, av_vs, av_entities) |av_a, av_v, av_entity| {
        try testing.expectEqual(av_a, try storage.getComponent(av_entity, Testing.Component.A));
        try testing.expectError(error.MissingComponent, storage.getComponent(av_entity, Testing.Component.B));
        try testing.expectEqual(av_v, try storage.getComponent(av_entity, Vector));
    }

    for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
        const ab = try storage.getComponents(ab_entity, Testing.Structure.AB);
        try testing.expectEqual(ab_a, ab.a);
        try testing.expectEqual(ab_b, ab.b);
        try testing.expectError(error.MissingComponent, storage.getComponent(ab_entity, Vector));
    }

    for (abv_as, abv_bs, abv_vs, abv_entities) |abv_a, abv_b, abv_v, abv_entity| {
        try testing.expectEqual(abv_a, try storage.getComponent(abv_entity, Testing.Component.A));
        try testing.expectEqual(abv_b, try storage.getComponent(abv_entity, Testing.Component.B));
        try testing.expectEqual(abv_v, try storage.getComponent(abv_entity, Vector));
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
        entity.* = try storage.createEntity(.{a.*});
    }

    var ab_as: [test_data_count]Testing.Component.A = undefined;
    var ab_bs: [test_data_count]Testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (&ab_as, &ab_bs, &ab_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, b.* });
    }

    var ac_as: [test_data_count]Testing.Component.A = undefined;
    const ac_cs: Testing.Component.C = .{};
    var ac_entities: [test_data_count]Entity = undefined;
    for (&ac_as, &ac_entities, 0..) |*a, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, ac_cs });
    }

    var abc_as: [test_data_count]Testing.Component.A = undefined;
    var abc_bs: [test_data_count]Testing.Component.B = undefined;
    const abc_cs: Testing.Component.C = .{};
    var abc_entities: [test_data_count]Entity = undefined;
    for (&abc_as, &abc_bs, &abc_entities, 0..) |*a, *b, *entity, index| {
        a.* = Testing.Component.A{ .value = @as(u32, @intCast(index)) };
        b.* = Testing.Component.B{ .value = @as(u8, @intCast(index)) };
        entity.* = try storage.createEntity(.{ a.*, b.*, abc_cs });
    }

    // Cull A
    {
        var bc_storage = try StorageStub.init(std.testing.allocator);
        defer bc_storage.deinit();

        const bytes = try serialize(
            testing.allocator,
            StorageStub,
            storage,
            .{
                .culled_component_types = &[_]type{Testing.Component.A},
            },
        );
        defer testing.allocator.free(bytes);

        try deserialize(
            StorageStub,
            &bc_storage,
            bytes,
        );

        for (a_entities) |a_entity| {
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(a_entity, Testing.Component.C));
        }

        for (ab_bs, ab_entities) |ab_b, ab_entity| {
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectEqual(ab_b, try bc_storage.getComponent(ab_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(ab_entity, Testing.Component.C));
        }

        for (ac_entities) |ac_entity| {
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(ac_cs, try bc_storage.getComponent(ac_entity, Testing.Component.C));
        }

        for (abc_bs, abc_entities) |abc_b, abc_entity| {
            const bc = try bc_storage.getComponents(abc_entity, Testing.Structure.BC);
            try testing.expectError(error.MissingComponent, bc_storage.getComponent(abc_entity, Testing.Component.A));
            try testing.expectEqual(abc_b, bc.b);
            try testing.expectEqual(ac_cs, bc.c);
        }
    }

    // Cull B
    {
        var ac_storage = try StorageStub.init(std.testing.allocator);
        defer ac_storage.deinit();

        const bytes = try serialize(
            testing.allocator,
            StorageStub,
            storage,
            .{
                .culled_component_types = &[_]type{Testing.Component.B},
            },
        );
        defer testing.allocator.free(bytes);

        try deserialize(
            StorageStub,
            &ac_storage,
            bytes,
        );

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, try ac_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(a_entity, Testing.Component.C));
        }

        for (ab_as, ab_entities) |ab_a, ab_entity| {
            try testing.expectEqual(ab_a, try ac_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(ab_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(ab_entity, Testing.Component.C));
        }

        for (ac_as, ac_entities) |ac_a, ac_entity| {
            const ac = try ac_storage.getComponents(ac_entity, Testing.Structure.AC);
            try testing.expectEqual(ac_a, ac.a);
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(ac_cs, ac.c);
        }

        for (abc_as, abc_entities) |abc_a, abc_entity| {
            const ac = try ac_storage.getComponents(abc_entity, Testing.Structure.AC);
            try testing.expectEqual(abc_a, ac.a);
            try testing.expectError(error.MissingComponent, ac_storage.getComponent(abc_entity, Testing.Component.B));
            try testing.expectEqual(ac_cs, ac.c);
        }
    }

    // Cull C
    {
        var ab_storage = try StorageStub.init(std.testing.allocator);
        defer ab_storage.deinit();

        const bytes = try serialize(
            testing.allocator,
            StorageStub,
            storage,
            .{
                .culled_component_types = &[_]type{Testing.Component.C},
            },
        );
        defer testing.allocator.free(bytes);

        try deserialize(
            StorageStub,
            &ab_storage,
            bytes,
        );

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, try ab_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(a_entity, Testing.Component.C));
        }

        for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
            const ab = try ab_storage.getComponents(ab_entity, Testing.Structure.AB);
            try testing.expectEqual(ab_a, ab.a);
            try testing.expectEqual(ab_b, ab.b);
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(ab_entity, Testing.Component.C));
        }

        for (ac_as, ac_entities) |ac_a, ac_entity| {
            try testing.expectEqual(ac_a, ab_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(ac_entity, Testing.Component.C));
        }

        for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
            const abc = try ab_storage.getComponents(abc_entity, Testing.Structure.AB);
            try testing.expectEqual(abc_a, abc.a);
            try testing.expectEqual(abc_b, abc.b);
            try testing.expectError(error.MissingComponent, ab_storage.getComponent(abc_entity, Testing.Component.C));
        }
    }

    // Cull AC
    {
        var b_storage = try StorageStub.init(std.testing.allocator);
        defer b_storage.deinit();

        const bytes = try serialize(
            testing.allocator,
            StorageStub,
            storage,
            .{
                .culled_component_types = &[_]type{ Testing.Component.A, Testing.Component.C },
            },
        );
        defer testing.allocator.free(bytes);

        try deserialize(
            StorageStub,
            &b_storage,
            bytes,
        );

        for (a_entities) |a_entity| {
            try testing.expectError(error.MissingComponent, b_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(a_entity, Testing.Component.C));
        }

        for (ab_bs, ab_entities) |ab_b, ab_entity| {
            try testing.expectError(error.MissingComponent, b_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectEqual(ab_b, try b_storage.getComponent(ab_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(ab_entity, Testing.Component.C));
        }

        for (ac_entities) |ac_entity| {
            try testing.expectError(error.MissingComponent, b_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(ac_entity, Testing.Component.C));
        }

        for (abc_bs, abc_entities) |abc_b, abc_entity| {
            try testing.expectError(error.MissingComponent, b_storage.getComponent(abc_entity, Testing.Component.A));
            try testing.expectEqual(abc_b, try b_storage.getComponent(abc_entity, Testing.Component.B));
            try testing.expectError(error.MissingComponent, b_storage.getComponent(abc_entity, Testing.Component.C));
        }
    }
}

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
//             try testing.expectError(error.MissingComponent, ab_storage.getComponent(a_entity, Testing.Component.B));
//         }

//         for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
//             try testing.expectEqual(ab_a, try ab_storage.getComponent(ab_entity, Testing.Component.A));
//             try testing.expectEqual(ab_b, try ab_storage.getComponent(ab_entity, Testing.Component.B));
//         }

//         for (ac_entities) |ac_entity| {
//             try testing.expectError(error.MissingComponent, ab_storage.getComponent(ac_entity, Testing.Component.A));
//             try testing.expectError(error.MissingComponent, ab_storage.getComponent(ac_entity, Testing.Component.B));
//         }

//         for (abc_entities) |abc_entity| {
//             try testing.expectError(error.MissingComponent, ab_storage.getComponent(abc_entity, Testing.Component.A));
//             try testing.expectError(error.MissingComponent, ab_storage.getComponent(abc_entity, Testing.Component.B));
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
//             try testing.expectError(error.MissingComponent, ac_storage.getComponent(a_entity, Testing.Component.C));
//         }

//         for (ab_entities) |ab_entity| {
//             try testing.expectError(error.MissingComponent, ac_storage.getComponent(ab_entity, Testing.Component.A));
//             try testing.expectError(error.MissingComponent, ac_storage.getComponent(ab_entity, Testing.Component.C));
//         }

//         for (ac_as, ac_entities) |a, ac_entity| {
//             try testing.expectEqual(a, try ac_storage.getComponent(ac_entity, Testing.Component.A));
//             try testing.expectEqual(ac_cs, try ac_storage.getComponent(ac_entity, Testing.Component.C));
//         }

//         for (abc_entities) |abc_entity| {
//             try testing.expectError(error.MissingComponent, ac_storage.getComponent(abc_entity, Testing.Component.A));
//             try testing.expectError(error.MissingComponent, ac_storage.getComponent(abc_entity, Testing.Component.C));
//         }
//     }
// }
