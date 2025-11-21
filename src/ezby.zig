const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const hashfn: fn (str: []const u8) u64 = std.hash.Fnv1a_64.hash;
const testing = std.testing;

const Color = @import("misc.zig").Color;
const CreateStorage = @import("storage.zig").CreateStorage;
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;
const set = @import("sparse_set.zig");
const Testing = @import("Testing.zig");
const ztracy = @import("ecez_ztracy.zig");

pub fn hashTypeName(comptime T: type) u64 {
    if (@inComptime() == false) {
        @compileError(@src().fn_name ++ " is not allowed during runtime");
    }

    const type_name = @typeName(T);
    return hashfn(type_name[0..]);
}

// TODO: option to use stack instead of heap

pub const version_major = 2;
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
    /// Incomatible component size
    IncompatibleCompSize,
    /// Incomatible component alignment
    IncompatibleCompAlign,
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

    const number_of_entities = storage.created_entity_count.load(.unordered);
    const total_byte_size = count_byte_size_blk: {
        var total_size: usize = @sizeOf(Chunk.Ezby);
        std.debug.assert(total_size == std.mem.alignForward(usize, total_size, alignment));

        if (storage.inactive_entities.items.len > 0) {
            total_size += @sizeOf(Chunk.Dele);
            total_size += storage.inactive_entities.items.len * @sizeOf(EntityId);
        }

        inline for (Storage.component_type_slice) |Component| {
            const cull_component = comptime check_if_cull_needed_blk: {
                for (comptime_config.culled_component_types) |CullComponent| {
                    if (Component == CullComponent) {
                        break :check_if_cull_needed_blk true;
                    }
                }
                break :check_if_cull_needed_blk false;
            };

            total_size += @sizeOf(Chunk.Comp);

            if (@sizeOf(Component) > 0) {
                {
                    const sparse_set: *const set.Sparse.Full = storage.getSparseSetConstPtr(Component);
                    total_size += calcAlignedEntityIdSize(sparse_set.sparse_len);
                }

                if (cull_component == false) {
                    const dense_set = storage.getDenseSetConstPtr(Component);
                    total_size += dense_set.dense_len * @sizeOf(Component);
                }
            } else {
                const sparse_set: *const set.Sparse.Tag = storage.getSparseSetConstPtr(Component);
                total_size += calcAlignedEntityIdSize(sparse_set.sparse_bits.len);
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

        // Write ezby (header)
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

        // Write dele
        if (storage.inactive_entities.items.len > 0) {
            const dele_chunk = Chunk.Dele{
                .entity_count = @intCast(storage.inactive_entities.items.len),
            };
            {
                @memcpy(
                    bytes[byte_cursor .. byte_cursor + @sizeOf(Chunk.Dele)],
                    mem.asBytes(&dele_chunk),
                );
                byte_cursor += @sizeOf(Chunk.Dele);
            }

            // Write entity ids
            {
                // Ignore alignment when doing the write (padding bytes are undefined)
                const size_of_entities = storage.inactive_entities.items.len * @sizeOf(EntityId);
                const deleted_entities_bytes = bytes[byte_cursor .. byte_cursor + size_of_entities];

                // Ensure alignment is respected for byte cursor
                byte_cursor += calcAlignedEntityIdSize(storage.inactive_entities.items.len);
                @memcpy(
                    deleted_entities_bytes,
                    std.mem.sliceAsBytes(storage.inactive_entities.items),
                );
            }
        }

        inline for (Storage.component_type_slice, 0..) |Component, comp_index| {
            const sparse_set = storage.getSparseSetConstPtr(Component);

            const cull_component = comptime check_if_cull_needed_blk: {
                for (comptime_config.culled_component_types) |CullComponent| {
                    if (Component == CullComponent) {
                        break :check_if_cull_needed_blk true;
                    }
                }
                break :check_if_cull_needed_blk false;
            };

            const sparse_count: u32, const dense_count: u32 = get_entity_dense_count_blk: {
                if (cull_component) {
                    break :get_entity_dense_count_blk .{ 0, 0 };
                }

                var result: std.meta.Tuple(&[_]type{ u32, u32 }) = .{
                    @intCast(sparse_set.sparse_len),
                    0,
                };

                if (@sizeOf(Component) > 0) {
                    const dense_set = storage.getDenseSetConstPtr(Component);
                    result[1] = @intCast(dense_set.dense_len);
                }

                break :get_entity_dense_count_blk result;
            };

            const comp_chunk = Chunk.Comp{
                .sparse_count = sparse_count,
                .dense_count = dense_count,
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
                if (comp_chunk.sparse_count > 0) {
                    // Ignore alignment when doing the write (padding bytes are undefined)
                    const size_of_entities = sparse_set.sparse_len * @sizeOf(EntityId);

                    const sparse_bytes = bytes[byte_cursor .. byte_cursor + size_of_entities];

                    // Ensure alignment is respected for byte cursor
                    byte_cursor += calcAlignedEntityIdSize(sparse_set.sparse_len);

                    if (cull_component) {
                        std.debug.assert(set.Sparse.not_set == std.math.maxInt(EntityId));
                        const not_set_byte = 0b1111_1111;
                        @memset(sparse_bytes, not_set_byte);
                    } else {
                        const sparse_slice = if (@sizeOf(Component) > 0)
                            sparse_set.sparse[0..comp_chunk.sparse_count]
                        else
                            sparse_set.sparse_bits[0..comp_chunk.sparse_count];

                        @memcpy(
                            sparse_bytes,
                            std.mem.sliceAsBytes(sparse_slice),
                        );
                    }
                }
            }

            // Write ComponentBytes
            {
                std.debug.assert(@sizeOf(Component) == comp_chunk.type_size);
                if (@sizeOf(Component) > 0) {
                    if (comp_chunk.dense_count > 0) {
                        const dense_set = storage.getDenseSetConstPtr(Component);

                        const size_of_components = comp_chunk.dense_count * comp_chunk.type_size;
                        const dense_bytes = bytes[byte_cursor .. byte_cursor + size_of_components];
                        byte_cursor += size_of_components;

                        @memcpy(
                            dense_bytes,
                            std.mem.sliceAsBytes(dense_set.dense[0..comp_chunk.dense_count]),
                        );
                    }
                }
            }

            // if its not the last chunk, align cursor
            if (Storage.component_type_slice.len - 1 != comp_index) {
                byte_cursor = std.mem.alignForward(usize, byte_cursor, alignment);
            }
        }
    }

    return bytes;
}

pub const DeserializeOp = enum {
    /// Deserialize the ezby stream and overwrite the submitted storage data.
    /// This *will clear the storage* of any pre-existing data.
    /// Any entity handles will remain the same as when the source storage was serialized
    overwrite,
    /// Append the ezby stream to the storage.
    /// Entity handles from the source storage that was serialized will not survive and should not be used
    /// To interact with the deserialized storage
    append,
};

pub const DeserializeConfig = struct {
    op: DeserializeOp,
};

/// Deserialize the supplied bytes and insert them into a storage. This function will
/// clear the storage memory which means that **current storage will be cleared**
///
/// In the event of error, the storage will be empty
pub fn deserialize(
    comptime Storage: type,
    storage: *Storage,
    ezby_bytes: []const u8,
    comptime config: DeserializeConfig,
) DeserializeError!void {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    switch (config.op) {
        .overwrite => {
            storage.clearRetainingCapacity();
            errdefer storage.clearRetainingCapacity();
        },
        .append => {},
    }

    var cursor = ezby_bytes;

    var ezby: Chunk.Ezby = undefined;
    cursor = try Chunk.parseEzby(cursor, &ezby);

    if (ezby.version_major != version_major) {
        return error.VersionMismatch;
    }

    // Parse DELE chunk if present
    if (mem.eql(u8, cursor[0..4], "DELE")) {
        var dele: Chunk.Dele = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        cursor = Chunk.parseDele(cursor, &dele, &entity_ids);
        try storage.inactive_entities.appendSlice(storage.allocator, entity_ids);
    }

    const beginning = storage.created_entity_count.fetchAdd(@intCast(ezby.number_of_entities), .seq_cst);
    while (cursor.len > @sizeOf(Chunk.Comp) and mem.eql(u8, cursor[0..4], "COMP")) {
        var comp: Chunk.Comp = undefined;
        var component_bytes: Chunk.Comp.ComponentBytes = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        cursor = Chunk.parseComp(
            cursor,
            &comp,
            &entity_ids,
            &component_bytes,
        );

        inline for (Storage.component_type_slice) |Component| {
            const type_hash = comptime hashTypeName(Component);
            if (type_hash == comp.type_name_hash) {
                if (comp.type_size != @sizeOf(Component)) {
                    return error.IncompatibleCompSize;
                }
                if (comp.type_alignment != @alignOf(Component)) {
                    return error.IncompatibleCompAlign;
                }

                if (entity_ids.len > 0) {
                    const extra_grow = if (config.op == .append) beginning else 0;
                    const sparse_set = storage.getSparseSetPtr(Component);
                    const grow_by = if (@sizeOf(Component) > 0)
                        comp.sparse_count
                    else
                        comp.sparse_count * @bitSizeOf(EntityId);
                    try sparse_set.grow(storage.allocator, extra_grow + grow_by);

                    switch (config.op) {
                        .append => {
                            if (@sizeOf(Component) > 0) {
                                const dense_set = storage.getDenseSetPtr(Component);

                                // Set full sparse
                                {
                                    const sparse_begin = beginning;
                                    const sparse_end = sparse_begin + entity_ids.len;
                                    @memcpy(sparse_set.sparse[sparse_begin..sparse_end], entity_ids);

                                    // Offset each entry by pre-existing dense entries
                                    for (sparse_set.sparse[sparse_begin..sparse_end]) |*sparse| {
                                        if (sparse.* != set.Sparse.not_set) {
                                            sparse.* += dense_set.dense_len;
                                        }
                                    }
                                }

                                // set dense
                                const component_data = std.mem.bytesAsSlice(Component, component_bytes);
                                try dense_set.grow(storage.allocator, dense_set.dense_len + component_data.len);
                                const dense_begin = dense_set.dense_len;
                                const dense_end = dense_begin + component_data.len;
                                @memcpy(dense_set.dense[dense_begin..dense_end], component_data);
                                dense_set.dense_len += comp.dense_count;

                                // restore internal sparse_index slice in the dense set
                                for (sparse_set.sparse[0..sparse_set.sparse_len], 0..) |dense_index, sparse_index| {
                                    if (dense_index != set.Sparse.not_set) {
                                        dense_set.sparse_index[dense_index] = @intCast(sparse_index);
                                    }
                                }
                            } else {
                                // Set tag sparse bits

                                // If the bits align
                                const unaligned_bits = beginning % @bitSizeOf(EntityId);
                                if (unaligned_bits == 0) {
                                    @memcpy(sparse_set.sparse_bits[0..entity_ids.len], entity_ids);
                                } else {
                                    const sparse_begin = beginning / @bitSizeOf(EntityId);
                                    const sparse_end = sparse_begin + entity_ids.len;
                                    const shift = @as(std.math.Log2Int(EntityId), @intCast(unaligned_bits));
                                    sparse_set.sparse_bits[sparse_begin] &= (entity_ids[0] << shift) | (@as(EntityId, 1) << shift) - 1;
                                    @memcpy(sparse_set.sparse_bits[sparse_begin + 1 .. sparse_end], entity_ids[1..]);
                                }
                            }
                        },
                        .overwrite => {
                            if (@sizeOf(Component) > 0) {
                                // Set full sparse
                                const sparse_begin = beginning;
                                const sparse_end = sparse_begin + entity_ids.len;
                                @memcpy(sparse_set.sparse[sparse_begin..sparse_end], entity_ids);

                                // set dense
                                const dense_set = storage.getDenseSetPtr(Component);
                                dense_set.dense_len = comp.dense_count;
                                const component_data = std.mem.bytesAsSlice(Component, component_bytes);
                                try dense_set.grow(storage.allocator, component_bytes.len);
                                @memcpy(dense_set.dense[0..component_data.len], component_data);

                                // restore internal sparse_index slice in the dense set
                                for (sparse_set.sparse[0..sparse_set.sparse_len], 0..) |dense_index, sparse_index| {
                                    if (dense_index != set.Sparse.not_set) {
                                        dense_set.sparse_index[dense_index] = @intCast(sparse_index);
                                    }
                                }
                            } else {
                                // Set tag sparse bits
                                @memcpy(sparse_set.sparse_bits[0..entity_ids.len], entity_ids);
                            }
                        },
                    }
                }
            }
        }
    }
}

inline fn calcAlignedEntityIdSize(sparse_len: usize) usize {
    return std.mem.alignForward(usize, sparse_len * @sizeOf(EntityId), 8);
}

/// ezby v1 files can only have 2 chunks. Ezby chunk is always first, then 1 or many Comp chunks
pub const Chunk = struct {
    /// Header chunk
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"),
        version_major: u16,
        version_minor: u16,
        number_of_entities: u64,
    };

    /// Component chunk contains component data for a single component type
    pub const Comp = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "COMP"),
        padding: u32 = 0,
        sparse_count: u32,
        dense_count: u32,
        type_size: u32,
        type_alignment: u32,
        type_name_hash: u64,

        pub const EntityIds = []const EntityId;
        pub const ComponentBytes = []const u8;
    };

    /// Deleted entitites
    pub const Dele = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "DELE"),
        entity_count: u32,
        pub const EntityIds = []const EntityId;
    };

    /// parse EZBY chunk from bytes and return remaining bytes
    fn parseEzby(bytes: []const u8, chunk: *Chunk.Ezby) error{UnexpectedEzbyIdentifier}![]const u8 {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
        defer zone.End();

        std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));

        if (mem.eql(u8, bytes[0..4], "EZBY") == false) {
            return error.UnexpectedEzbyIdentifier;
        }

        @memcpy(std.mem.asBytes(chunk), bytes[0..@sizeOf(Chunk.Ezby)]);
        return bytes[@sizeOf(Chunk.Ezby)..];
    }

    /// parse DELE chunk from bytes and return remaining bytes
    fn parseDele(
        bytes: []const u8,
        chunk: *Chunk.Dele,
        entity_ids: *Chunk.Comp.EntityIds,
    ) []const u8 {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
        defer zone.End();

        std.debug.assert(mem.eql(u8, bytes[0..4], "DELE"));
        std.debug.assert(bytes.len >= @sizeOf(Chunk.Dele));

        var bytes_cursor: usize = parse_comp_chunk_blk: {
            @memcpy(std.mem.asBytes(chunk), bytes[0..@sizeOf(Chunk.Dele)]);
            break :parse_comp_chunk_blk @sizeOf(Chunk.Dele);
        };

        bytes_cursor += parse_entity_ids_blk: {
            // Point at actual entities, ignoring any written alignment padding
            entity_ids.ptr = @as(
                [*]const EntityId,
                @ptrCast(@alignCast(bytes[bytes_cursor..].ptr)),
            );
            entity_ids.len = @intCast(chunk.*.entity_count);

            // Report new offset by respecting alignment padding
            break :parse_entity_ids_blk calcAlignedEntityIdSize(@intCast(chunk.*.entity_count));
        };

        return bytes[bytes_cursor..];
    }

    fn parseComp(
        bytes: []const u8,
        chunk: *Chunk.Comp,
        entity_ids: *Chunk.Comp.EntityIds,
        component_bytes: *Chunk.Comp.ComponentBytes,
    ) []const u8 {
        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
        defer zone.End();

        std.debug.assert(mem.eql(u8, bytes[0..4], "COMP"));

        var bytes_cursor: usize = parse_comp_chunk_blk: {
            @memcpy(std.mem.asBytes(chunk), bytes[0..@sizeOf(Chunk.Comp)]);
            break :parse_comp_chunk_blk @sizeOf(Chunk.Comp);
        };

        bytes_cursor += parse_entity_ids_blk: {
            // Point at actual entities, ignoring any written alignment padding
            entity_ids.ptr = @as(
                [*]const EntityId,
                @ptrCast(@alignCast(bytes[bytes_cursor..].ptr)),
            );
            entity_ids.len = @intCast(chunk.*.sparse_count);

            // Report new offset by respecting alignment padding
            break :parse_entity_ids_blk calcAlignedEntityIdSize(@intCast(chunk.*.sparse_count));
        };

        bytes_cursor += parse_component_bytes_blk: {
            const size_of_component_bytes = chunk.*.dense_count * chunk.*.type_size;
            component_bytes.* = bytes[bytes_cursor .. bytes_cursor + size_of_component_bytes];

            break :parse_component_bytes_blk size_of_component_bytes;
        };

        const aligned_cursor = std.mem.alignForward(usize, bytes_cursor, alignment);
        return bytes[aligned_cursor..];
    }
};

const StorageStub = Testing.StorageStub;

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

    var ezby: Chunk.Ezby = undefined;
    _ = try Chunk.parseEzby(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
        .number_of_entities = 0,
    }, ezby);
}

test "Chunk.parseComp" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..128) |_| {
        _ = try storage.createEntity(.{
            Testing.Component.A{},
            Testing.Component.B{},
            Testing.Component.C{},
            Testing.Component.D.one,
            Testing.Component.E{ .one = 1 },
            Testing.Component.F{},
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

    var ezby: Chunk.Ezby = undefined;
    cursor = try Chunk.parseEzby(bytes, &ezby);

    inline for (Testing.AllComponentsArr) |Component| {
        var comp: Chunk.Comp = undefined;
        var entity_ids: Chunk.Comp.EntityIds = undefined;
        var component_bytes: Chunk.Comp.ComponentBytes = undefined;
        cursor = Chunk.parseComp(
            cursor,
            &comp,
            &entity_ids,
            &component_bytes,
        );

        if (@sizeOf(Component) > 0) {
            try testing.expectEqual(Chunk.Comp{
                .sparse_count = 128,
                .dense_count = 128,
                .type_size = @sizeOf(Component),
                .type_alignment = @alignOf(Component),
                .type_name_hash = comptime hashfn(@typeName(Component)),
            }, comp);
        } else {
            try testing.expectEqual(Chunk.Comp{
                .sparse_count = 128 / 32,
                .dense_count = 0,
                .type_size = @sizeOf(Component),
                .type_alignment = @alignOf(Component),
                .type_name_hash = comptime hashfn(@typeName(Component)),
            }, comp);
        }
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
        .{ .op = .overwrite },
    );

    for (a_as, a_entities) |a, a_entity| {
        try testing.expectEqual(a, storage.getComponent(a_entity, Testing.Component.A).?);
        try testing.expectEqual(null, storage.getComponent(a_entity, Testing.Component.B));
        try testing.expectEqual(false, storage.hasComponents(a_entity, .{Testing.Component.C}));
    }

    for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
        const ab = storage.getComponents(ab_entity, Testing.Structure.AB).?;
        try testing.expectEqual(ab_a, ab.a);
        try testing.expectEqual(ab_b, ab.b);
        try testing.expectEqual(false, storage.hasComponents(ab_entity, .{Testing.Component.C}));
    }

    for (ac_as, ac_entities) |ac_a, ac_entity| {
        const ac = storage.getComponents(ac_entity, Testing.Structure.AC).?;
        try testing.expectEqual(ac_a, ac.a);
        try testing.expectEqual(null, storage.getComponent(ac_entity, Testing.Component.B));
        try testing.expectEqual(ac_cs, ac.c);
    }

    for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
        const abc = storage.getComponents(abc_entity, Testing.Structure.ABC).?;
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
        .{ .op = .overwrite },
    );

    try testing.expectEqual(
        a,
        storage.getComponent(entity, Testing.Component.A).?,
    );
}

test "serialize and deserialized with types of higher alignment works" {
    const Vector = struct { v: @Vector(8, u64) };

    const TestStorage = @import("storage.zig").CreateStorage(&[_]type{
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
        .{ .op = .overwrite },
    );

    for (a_as, a_entities) |a, a_entity| {
        try testing.expectEqual(a, storage.getComponent(a_entity, Testing.Component.A).?);
        try testing.expectEqual(null, storage.getComponent(a_entity, Vector));
        try testing.expectEqual(null, storage.getComponent(a_entity, Testing.Component.B));
    }

    for (av_as, av_vs, av_entities) |av_a, av_v, av_entity| {
        try testing.expectEqual(av_a, storage.getComponent(av_entity, Testing.Component.A).?);
        try testing.expectEqual(null, storage.getComponent(av_entity, Testing.Component.B));
        try testing.expectEqual(av_v, storage.getComponent(av_entity, Vector).?);
    }

    for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
        const ab = storage.getComponents(ab_entity, Testing.Structure.AB).?;
        try testing.expectEqual(ab_a, ab.a);
        try testing.expectEqual(ab_b, ab.b);
        try testing.expectEqual(null, storage.getComponent(ab_entity, Vector));
    }

    for (abv_as, abv_bs, abv_vs, abv_entities) |abv_a, abv_b, abv_v, abv_entity| {
        try testing.expectEqual(abv_a, storage.getComponent(abv_entity, Testing.Component.A).?);
        try testing.expectEqual(abv_b, storage.getComponent(abv_entity, Testing.Component.B).?);
        try testing.expectEqual(abv_v, storage.getComponent(abv_entity, Vector).?);
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
            .{ .op = .overwrite },
        );

        for (a_entities) |a_entity| {
            try testing.expectEqual(null, bc_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectEqual(null, bc_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectEqual(false, bc_storage.hasComponents(a_entity, .{Testing.Component.C}));
        }

        for (ab_bs, ab_entities) |ab_b, ab_entity| {
            try testing.expectEqual(null, bc_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectEqual(ab_b, bc_storage.getComponent(ab_entity, Testing.Component.B).?);
            try testing.expectEqual(false, bc_storage.hasComponents(ab_entity, .{Testing.Component.C}));
        }

        for (ac_entities) |ac_entity| {
            try testing.expectEqual(null, bc_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectEqual(null, bc_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(true, bc_storage.hasComponents(ac_entity, .{Testing.Component.C}));
        }

        for (abc_bs, abc_entities) |abc_b, abc_entity| {
            const bc = bc_storage.getComponents(abc_entity, Testing.Structure.BC).?;
            try testing.expectEqual(null, bc_storage.getComponent(abc_entity, Testing.Component.A));
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
            .{ .op = .overwrite },
        );

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, ac_storage.getComponent(a_entity, Testing.Component.A).?);
            try testing.expectEqual(null, ac_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectEqual(false, ac_storage.hasComponents(a_entity, .{Testing.Component.C}));
        }

        for (ab_as, ab_entities) |ab_a, ab_entity| {
            try testing.expectEqual(ab_a, ac_storage.getComponent(ab_entity, Testing.Component.A).?);
            try testing.expectEqual(null, ac_storage.getComponent(ab_entity, Testing.Component.B));
            try testing.expectEqual(false, ac_storage.hasComponents(ab_entity, .{Testing.Component.C}));
        }

        for (ac_as, ac_entities) |ac_a, ac_entity| {
            const ac = ac_storage.getComponents(ac_entity, Testing.Structure.AC).?;
            try testing.expectEqual(ac_a, ac.a);
            try testing.expectEqual(null, ac_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(ac_cs, ac.c);
        }

        for (abc_as, abc_entities) |abc_a, abc_entity| {
            const ac = ac_storage.getComponents(abc_entity, Testing.Structure.AC).?;
            try testing.expectEqual(abc_a, ac.a);
            try testing.expectEqual(null, ac_storage.getComponent(abc_entity, Testing.Component.B));
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
            .{ .op = .overwrite },
        );

        for (a_as, a_entities) |a, a_entity| {
            try testing.expectEqual(a, ab_storage.getComponent(a_entity, Testing.Component.A).?);
            try testing.expectEqual(null, ab_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectEqual(false, ab_storage.hasComponents(a_entity, .{Testing.Component.C}));
        }

        for (ab_as, ab_bs, ab_entities) |ab_a, ab_b, ab_entity| {
            const ab = ab_storage.getComponents(ab_entity, Testing.Structure.AB).?;
            try testing.expectEqual(ab_a, ab.a);
            try testing.expectEqual(ab_b, ab.b);
            try testing.expectEqual(false, ab_storage.hasComponents(ab_entity, .{Testing.Component.C}));
        }

        for (ac_as, ac_entities) |ac_a, ac_entity| {
            try testing.expectEqual(ac_a, ab_storage.getComponent(ac_entity, Testing.Component.A).?);
            try testing.expectEqual(null, ab_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(false, ab_storage.hasComponents(ac_entity, .{Testing.Component.C}));
        }

        for (abc_as, abc_bs, abc_entities) |abc_a, abc_b, abc_entity| {
            const abc = ab_storage.getComponents(abc_entity, Testing.Structure.AB).?;
            try testing.expectEqual(abc_a, abc.a);
            try testing.expectEqual(abc_b, abc.b);
            try testing.expectEqual(false, ab_storage.hasComponents(abc_entity, .{Testing.Component.C}));
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
            .{ .op = .overwrite },
        );

        for (a_entities) |a_entity| {
            try testing.expectEqual(null, b_storage.getComponent(a_entity, Testing.Component.A));
            try testing.expectEqual(null, b_storage.getComponent(a_entity, Testing.Component.B));
            try testing.expectEqual(false, b_storage.hasComponents(a_entity, .{Testing.Component.C}));
        }

        for (ab_bs, ab_entities) |ab_b, ab_entity| {
            try testing.expectEqual(null, b_storage.getComponent(ab_entity, Testing.Component.A));
            try testing.expectEqual(ab_b, b_storage.getComponent(ab_entity, Testing.Component.B).?);
            try testing.expectEqual(false, b_storage.hasComponents(ab_entity, .{Testing.Component.C}));
        }

        for (ac_entities) |ac_entity| {
            try testing.expectEqual(null, b_storage.getComponent(ac_entity, Testing.Component.A));
            try testing.expectEqual(null, b_storage.getComponent(ac_entity, Testing.Component.B));
            try testing.expectEqual(false, b_storage.hasComponents(ac_entity, .{Testing.Component.C}));
        }

        for (abc_bs, abc_entities) |abc_b, abc_entity| {
            try testing.expectEqual(null, b_storage.getComponent(abc_entity, Testing.Component.A));
            try testing.expectEqual(abc_b, b_storage.getComponent(abc_entity, Testing.Component.B).?);
            try testing.expectEqual(false, b_storage.hasComponents(abc_entity, .{Testing.Component.C}));
        }
    }
}

test "serialize Storage A into Storage AB works" {
    const StorageB = CreateStorage(&[_]type{
        Testing.Component.A,
    });
    var from_storage = try StorageB.init(std.testing.allocator);
    defer from_storage.deinit();

    var a_entities_0: [100]Entity = undefined;
    for (&a_entities_0, 0..) |*entity, index| {
        entity.* = try from_storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(index) },
        });
    }

    var empty_entities: [50]Entity = undefined;
    for (&empty_entities) |*entity| {
        entity.* = try from_storage.createEntity(.{});
    }

    var a_entities_1: [100]Entity = undefined;
    for (&a_entities_1, (a_entities_0.len + empty_entities.len)..) |*entity, index| {
        entity.* = try from_storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(index) },
        });
    }

    const bytes = try serialize(std.testing.allocator, StorageB, from_storage, .{});
    defer std.testing.allocator.free(bytes);

    const StorageAB = CreateStorage(&[_]type{
        Testing.Component.A,
        Testing.Component.B,
    });
    var to_storage = try StorageAB.init(std.testing.allocator);
    defer to_storage.deinit();

    try deserialize(StorageAB, &to_storage, bytes, .{ .op = .overwrite });

    for (&a_entities_0, 0..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);

        const b = to_storage.getComponent(entity, Testing.Component.A).?;
        try testing.expectEqual(Testing.Component.A{ .value = @intCast(entity_id) }, b);
    }
    for (&empty_entities, a_entities_0.len..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);
    }
    for (&a_entities_1, (a_entities_0.len + empty_entities.len)..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);

        const b = to_storage.getComponent(entity, Testing.Component.A).?;
        try testing.expectEqual(Testing.Component.A{ .value = @intCast(entity_id) }, b);
    }
}

test "serialize Storage B into Storage AB works" {
    const StorageB = CreateStorage(&[_]type{
        Testing.Component.B,
    });
    var from_storage = try StorageB.init(std.testing.allocator);
    defer from_storage.deinit();

    var b_entities_0: [100]Entity = undefined;
    for (&b_entities_0, 0..) |*entity, index| {
        entity.* = try from_storage.createEntity(.{
            Testing.Component.B{ .value = @intCast(index) },
        });
    }

    var empty_entities: [50]Entity = undefined;
    for (&empty_entities) |*entity| {
        entity.* = try from_storage.createEntity(.{});
    }

    var b_entities_1: [100]Entity = undefined;
    for (&b_entities_1, (b_entities_0.len + empty_entities.len)..) |*entity, index| {
        entity.* = try from_storage.createEntity(.{
            Testing.Component.B{ .value = @intCast(index) },
        });
    }

    const bytes = try serialize(std.testing.allocator, StorageB, from_storage, .{});
    defer std.testing.allocator.free(bytes);

    const StorageAB = CreateStorage(&[_]type{
        Testing.Component.A,
        Testing.Component.B,
    });
    var to_storage = try StorageAB.init(std.testing.allocator);
    defer to_storage.deinit();

    try deserialize(StorageAB, &to_storage, bytes, .{ .op = .overwrite });

    for (&b_entities_0, 0..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);

        const b = to_storage.getComponent(entity, Testing.Component.B).?;
        try testing.expectEqual(Testing.Component.B{ .value = @intCast(entity_id) }, b);
    }
    for (&empty_entities, b_entities_0.len..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);
    }
    for (&b_entities_1, (b_entities_0.len + empty_entities.len)..) |entity, entity_id| {
        try testing.expectEqual(entity_id, entity.id);

        const b = to_storage.getComponent(entity, Testing.Component.B).?;
        try testing.expectEqual(Testing.Component.B{ .value = @intCast(entity_id) }, b);
    }
}

test "serialize and deserialize deleted entities works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (&entities, 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(index) },
            Testing.Component.B{ .value = @intCast(index) },
            Testing.Component.E{ .two = @intCast(index) },
        });
    }

    for (entities[100..150]) |entity| {
        try storage.destroyEntity(entity);
    }

    for (&entities, 0..) |entity, entity_id| {
        if (entity_id < 100 or entity_id >= 150) {
            const abe = storage.getComponents(entity, struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
                e: Testing.Component.E,
            }).?;
            try testing.expectEqual(Testing.Component.A{ .value = @intCast(entity_id) }, abe.a);
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(entity_id) }, abe.b);
            try testing.expectEqual(Testing.Component.E{ .two = @intCast(entity_id) }, abe.e);
        } else {
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.A}) == false);
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.B}) == false);
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.E}) == false);
        }
    }

    const bytes = try serialize(std.testing.allocator, StorageStub, storage, .{});
    defer std.testing.allocator.free(bytes);

    try deserialize(StorageStub, &storage, bytes, .{ .op = .overwrite });

    for (&entities, 0..) |entity, entity_id| {
        if (entity_id < 100 or entity_id >= 150) {
            const abe = storage.getComponents(entity, struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
                e: Testing.Component.E,
            }).?;
            try testing.expectEqual(Testing.Component.A{ .value = @intCast(entity_id) }, abe.a);
            try testing.expectEqual(Testing.Component.B{ .value = @intCast(entity_id) }, abe.b);
            try testing.expectEqual(Testing.Component.E{ .two = @intCast(entity_id) }, abe.e);
        } else {
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.A}) == false);
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.B}) == false);
            try testing.expect(storage.hasComponents(entity, .{Testing.Component.E}) == false);
        }
    }
}

test "append works" {
    var main_storage = try StorageStub.init(std.testing.allocator);
    defer main_storage.deinit();

    var entities: [200]Entity = undefined;
    for (&entities, 0..) |*entity, index| {
        entity.* = try main_storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(index) },
            Testing.Component.B{ .value = @intCast(index) },
            Testing.Component.E{ .two = @intCast(index) },
        });
    }

    var src_storage = try StorageStub.init(std.testing.allocator);
    defer src_storage.deinit();

    const append_a_value = 0xBEEFBEEF;
    _ = try src_storage.createEntity(.{
        Testing.Component.A{ .value = append_a_value },
    });

    const bytes = try serialize(std.testing.allocator, StorageStub, src_storage, .{});
    defer std.testing.allocator.free(bytes);

    const append_count = 200;
    for (0..append_count) |_| {
        try deserialize(StorageStub, &main_storage, bytes, .{ .op = .append });
    }

    for (&entities, 0..) |entity, entity_id| {
        const abe = main_storage.getComponents(entity, struct {
            a: Testing.Component.A,
            b: Testing.Component.B,
            e: Testing.Component.E,
        }).?;
        try testing.expectEqual(Testing.Component.A{ .value = @intCast(entity_id) }, abe.a);
        try testing.expectEqual(Testing.Component.B{ .value = @intCast(entity_id) }, abe.b);
        try testing.expectEqual(Testing.Component.E{ .two = @intCast(entity_id) }, abe.e);
    }

    // Assumption: entity ids are incremental
    const last_entity_id = entities[entities.len - 1].id + 1;
    for (last_entity_id..last_entity_id + append_count) |appended_entity_id| {
        const entity_a = main_storage.getComponents(Entity{ .id = @intCast(appended_entity_id) }, struct {
            a: Testing.Component.A,
        }).?;
        try testing.expectEqual(Testing.Component.A{ .value = append_a_value }, entity_a.a);
    }
}

test "reproducer: dense state remain intact" {
    var src_storage = try StorageStub.init(std.testing.allocator);
    defer src_storage.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, index| {
        entity.* = try src_storage.createEntity(.{Testing.Component.A{ .value = @intCast(index) }});
    }

    const bytes = try serialize(
        testing.allocator,
        StorageStub,
        src_storage,
        .{},
    );
    defer testing.allocator.free(bytes);

    var dst_storage = try StorageStub.init(std.testing.allocator);
    defer dst_storage.deinit();

    try deserialize(
        StorageStub,
        &dst_storage,
        bytes,
        .{ .op = .overwrite },
    );

    dst_storage.unsetComponents(entities[50], .{
        Testing.Component.A,
    });

    try dst_storage.setComponents(
        entities[50],
        .{Testing.Component.A{ .value = 50 }},
    );

    for (entities[0..50], 0..) |entity, index| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @intCast(index) },
            dst_storage.getComponent(entity, Testing.Component.A).?,
        );
    }

    for (entities[51..100], 51..) |entity, index| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @intCast(index) },
            dst_storage.getComponent(entity, Testing.Component.A).?,
        );
    }
}

test "append unaligned tag components works" {
    var src_storage = try StorageStub.init(std.testing.allocator);
    defer src_storage.deinit();

    const data_0 = Testing.Structure.ABC{
        .a = .{ .value = 0 },
        .b = .{ .value = 0 },
        .c = .{},
    };
    const data_1 = Testing.Structure.ABC{
        .a = .{ .value = 1 },
        .b = .{ .value = 1 },
        .c = .{},
    };
    const e_0 = try src_storage.createEntity(data_0);
    const e_1 = try src_storage.createEntity(data_1);

    const ezby_bytes = try serialize(testing.allocator, StorageStub, src_storage, .{});
    defer testing.allocator.free(ezby_bytes);

    try deserialize(StorageStub, &src_storage, ezby_bytes, .{ .op = .append });

    try testing.expectEqual(
        src_storage.getComponents(e_0, Testing.Structure.ABC).?,
        data_0,
    );
    try testing.expectEqual(
        src_storage.getComponents(e_1, Testing.Structure.ABC).?,
        data_1,
    );
    try testing.expectEqual(
        src_storage.getComponents(Entity{ .id = 2 }, Testing.Structure.ABC).?,
        data_0,
    );
    try testing.expectEqual(
        src_storage.getComponents(Entity{ .id = 3 }, Testing.Structure.ABC).?,
        data_1,
    );
}
