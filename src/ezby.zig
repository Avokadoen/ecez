const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const entity_type = @import("entity_type.zig");
const EntityRef = entity_type.EntityRef;
const Entity = entity_type.Entity;
const query = @import("query.zig");
const EntityMap = entity_type.Map;

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
pub const SerializeConfig = struct {
    pre_allocation_size: usize = 0,
};

// TODO: option to use stack instead of heap
// TODO: heavily hint that arena allocator should be used?
/// Serialize a storage instance to a byte array. The caller owns the returned memory
pub fn serialize(
    comptime Storage: type,
    allocator: Allocator,
    storage: Storage,
    config: SerializeConfig,
) SerializeError![]const u8 {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    var written_bytes: std.ArrayList(u8) = ezby_chunk_blk: {
        const arch_zone = ztracy.ZoneNC(@src(), "EZBY chunk", Color.serializer);
        defer arch_zone.End();

        const pre_alloc_size = pre_alloc_blk_size: {
            // TODO: replace with @max?
            if (@sizeOf(Chunk.Ezby) > config.pre_allocation_size) {
                break :pre_alloc_blk_size @sizeOf(Chunk.Ezby);
            }

            break :pre_alloc_blk_size config.pre_allocation_size;
        };

        var bytes = try std.ArrayList(u8).initCapacity(allocator, pre_alloc_size);
        // !no defer bytes.deinit in this block!

        const ezby_chunk = Chunk.Ezby{
            .version_major = version_major,
            .version_minor = version_minor,
        };

        // append partially complete ezby chunk to ensure these bytes are used by the ezby chunk
        bytes.appendSliceAssumeCapacity(mem.asBytes(&ezby_chunk));

        break :ezby_chunk_blk bytes;
    };
    defer written_bytes.deinit();

    // append component type data (COMP)
    {
        const arch_zone = ztracy.ZoneNC(@src(), "COMP chunk", Color.serializer);
        defer arch_zone.End();

        const component_hashes = comptime Storage.Container.getSortedComponentHashes();

        const comp_chunk_size = @sizeOf(Chunk.Comp) + (component_hashes.len * @sizeOf(u64)) + (storage.container.component_sizes.len * @sizeOf(u32));
        try written_bytes.ensureUnusedCapacity(comp_chunk_size);

        const comp_chunk = Chunk.Comp{
            .number_of_component_types = @intCast(component_hashes.len),
        };
        written_bytes.appendSliceAssumeCapacity(mem.asBytes(&comp_chunk));
        written_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(&component_hashes));
        written_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(&storage.container.component_sizes));
    }

    // step through the archetype tree and serialize each archetype (ARCH)
    for (storage.container.archetypes.items) |archetype| {
        const arch_zone = ztracy.ZoneNC(@src(), "ARCH chunk", Color.serializer);
        defer arch_zone.End();

        const entity_count: u64 = archetype.getEntityCount();
        const type_count: u32 = @intCast(archetype.getComponentCount());
        std.debug.assert(archetype.component_storage.len == type_count);

        // calculate arch chunk size
        const arch_chunk_size = blk1: {
            const type_index_list_size: usize = @intCast(type_count * @sizeOf(u32));
            const entity_list_size: usize = @intCast(entity_count * @sizeOf(u64));

            const component_bytes_size = blk2: {
                var size: usize = 0;
                for (archetype.component_storage) |component_bytes| {
                    size += pow2Align(usize, component_bytes.items.len, alignment);
                }
                break :blk2 size;
            };

            break :blk1 @sizeOf(Chunk.Arch) + type_index_list_size + entity_list_size + component_bytes_size;
        };

        // ensure we will have enough capacity for the ARCH chunk
        try written_bytes.ensureUnusedCapacity(arch_chunk_size);
        {
            const arch_chunk = Chunk.Arch{
                .number_of_component_types = @as(u32, @intCast(type_count)),
                .number_of_entities = @as(u64, @intCast(entity_count)),
            };
            written_bytes.appendSliceAssumeCapacity(mem.asBytes(&arch_chunk));

            // serialize Arch.RttiIndices
            {
                const rtti_indices = archetype.getComponentTypeIndices();
                written_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(rtti_indices));
            }

            // serialize Arch.EntityList
            {
                const entities = archetype.getEntities();
                written_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(entities));
            }

            // append component bytes
            for (archetype.component_storage) |component_bytes| {
                written_bytes.appendSliceAssumeCapacity(component_bytes.items);

                const aligned_len = pow2Align(usize, component_bytes.items.len, alignment);
                written_bytes.appendNTimesAssumeCapacity(0, aligned_len - component_bytes.items.len);
            }
        }
    }

    return written_bytes.toOwnedSlice();
}

pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"), // TODO: only serialize, do not include as runtime data
        version_major: u8,
        version_minor: u8,
        reserved: u16 = 0,
    };

    pub const Comp = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "COMP"), // TODO: only serialize, do not include as runtime data
        number_of_component_types: u32,

        /// Run-time type information
        pub const Rtti = u64;
        pub const HashList = [*]const u64;
        pub const SizeList = [*]const u32;
    };

    pub const Arch = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "ARCH"), // TODO: only serialize, do not include as runtime data
        /// how many component byte lists that are after this chunk
        number_of_component_types: u32,
        number_of_entities: u64,

        /// Run-time type information index
        pub const RttiIndices = [*]const u32;
        pub const EntityList = [*]const Entity;
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

/// parse COMP chunk from bytes and return remaining bytes
fn parseCompChunk(
    bytes: []const u8,
    chunk: **const Chunk.Comp,
    hash_list: *Chunk.Comp.HashList,
    size_list: *Chunk.Comp.SizeList,
) []const u8 {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Comp));
    std.debug.assert(mem.eql(u8, bytes[0..4], "COMP"));

    chunk.* = @as(
        *const Chunk.Comp,
        @ptrCast(@alignCast(bytes.ptr)),
    );

    hash_list.* = @as(
        Chunk.Comp.HashList,
        @ptrCast(@alignCast(bytes[@sizeOf(Chunk.Comp)..].ptr)),
    );
    const hash_list_size = chunk.*.number_of_component_types * @sizeOf(u64);

    size_list.* = @as(
        Chunk.Comp.SizeList,
        @ptrCast(@alignCast(bytes[@sizeOf(Chunk.Comp) + hash_list_size ..].ptr)),
    );
    const size_list_size = chunk.*.number_of_component_types * @sizeOf(u32);

    const next_byte = @sizeOf(Chunk.Comp) + hash_list_size + size_list_size;
    return bytes[next_byte..];
}

fn parseArchChunk(
    comp_size_list: []const u32,
    bytes: []const u8,
    chunk: **const Chunk.Arch,
    rtti_indices_list: *Chunk.Arch.RttiIndices,
    entity_list: *Chunk.Arch.EntityList,
    component_bytes: *[*]const u8,
) []const u8 {
    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Arch));
    std.debug.assert(mem.eql(u8, bytes[0..4], "ARCH"));

    // TODO: remove this (hitting false incorrect alignment error)
    @setRuntimeSafety(false);
    chunk.* = @as(
        *const Chunk.Arch,
        @ptrCast(@alignCast(bytes.ptr)),
    );

    rtti_indices_list.* = @as(
        Chunk.Arch.RttiIndices,
        @ptrCast(@alignCast(bytes[@sizeOf(Chunk.Arch)..].ptr)),
    );
    const rtti_list_size = chunk.*.number_of_component_types * @sizeOf(u32);

    const entity_list_offset = @sizeOf(Chunk.Arch) + rtti_list_size;
    entity_list.* = @as(
        Chunk.Arch.EntityList,
        @ptrCast(@alignCast(bytes[entity_list_offset..].ptr)),
    );
    const entity_list_size = chunk.*.number_of_entities * @sizeOf(Entity);

    const component_bytes_offset = entity_list_offset + entity_list_size;
    component_bytes.* = bytes[component_bytes_offset..].ptr;

    const remaining_bytes_offset = blk: {
        var component_byte_size: u64 = 0;
        for (rtti_indices_list.*[0..chunk.*.number_of_component_types]) |rtti_index| {
            const comp_size = comp_size_list[rtti_index];
            component_byte_size += pow2Align(usize, comp_size * chunk.*.number_of_entities, alignment);
        }
        break :blk component_bytes_offset + component_byte_size;
    };

    return bytes[remaining_bytes_offset..];
}

fn pow2Align(comptime T: type, num: T, @"align": T) T {
    return (num + @"align" - 1) & ~(@"align" - 1);
}

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = @import("storage.zig").CreateStorage(Testing.AllComponentsTuple, .{});

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
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const bytes = try serialize(StorageStub, testing.allocator, storage, .{});
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = try parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
    }, ezby.*);
}

test "serializing then using parseCompChunk produce expected COMP chunk" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const bytes = try serialize(StorageStub, testing.allocator, storage, .{});
    defer testing.allocator.free(bytes);

    // parse ezby header to get to eref bytes
    var ezby: *Chunk.Ezby = undefined;
    const eref_bytes = try parseEzbyChunk(bytes, &ezby);

    var comp: *Chunk.Comp = undefined;
    var hash_list: Chunk.Comp.HashList = undefined;
    var size_list: Chunk.Comp.SizeList = undefined;
    _ = parseCompChunk(eref_bytes, &comp, &hash_list, &size_list);

    // we initialize world with 3 component types
    try testing.expectEqual(
        @as(u32, 3),
        comp.number_of_component_types,
    );

    // check hashes
    try testing.expectEqual(
        query.hashType(Testing.Component.A),
        hash_list[0],
    );
    try testing.expectEqual(
        query.hashType(Testing.Component.B),
        hash_list[1],
    );
    try testing.expectEqual(
        query.hashType(Testing.Component.C),
        hash_list[2],
    );

    // check sizes
    try testing.expectEqual(
        @as(u64, @sizeOf(Testing.Component.A)),
        size_list[0],
    );
    try testing.expectEqual(
        @as(u64, @sizeOf(Testing.Component.B)),
        size_list[1],
    );
    try testing.expectEqual(
        @as(u64, @sizeOf(Testing.Component.C)),
        size_list[2],
    );
}

test "serializing then using parseArchChunk produce expected ARCH chunk" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var a = Testing.Component.A{};
    var b = Testing.Component.B{};

    var entities: [10]Entity = undefined;
    for (&entities) |*entity| {
        entity.* = try storage.createEntity(.{ a, b });
    }

    const bytes = try serialize(StorageStub, testing.allocator, storage, .{});
    defer testing.allocator.free(bytes);

    // parse ezby header to get to eref bytes
    var ezby: *Chunk.Ezby = undefined;
    const eref_bytes = try parseEzbyChunk(bytes, &ezby);

    var comp: *Chunk.Comp = undefined;
    var hash_list: Chunk.Comp.HashList = undefined;
    var size_list: Chunk.Comp.SizeList = undefined;
    const void_arch_bytes = parseCompChunk(eref_bytes, &comp, &hash_list, &size_list);

    const a_b_arch_bytes = blk: {
        var arch: *Chunk.Arch = undefined;
        var rtti_list: Chunk.Arch.RttiIndices = undefined;
        var entity_map_list: Chunk.Arch.EntityList = undefined;
        var component_bytes: [*]const u8 = undefined;
        const a_b_bytes = parseArchChunk(
            size_list[0..comp.number_of_component_types],
            void_arch_bytes,
            &arch,
            &rtti_list,
            &entity_map_list,
            &component_bytes,
        );

        // the first arch is always the "void" archetype
        try testing.expectEqual(Chunk.Arch{
            .number_of_component_types = 0,
            .number_of_entities = 0,
        }, arch.*);

        break :blk a_b_bytes;
    };

    var arch: *Chunk.Arch = undefined;
    var rtti_indices_list: Chunk.Arch.RttiIndices = undefined;
    var entity_list: Chunk.Arch.EntityList = undefined;
    var component_bytes: [*]const u8 = undefined;
    _ = parseArchChunk(
        size_list[0..comp.number_of_component_types],
        a_b_arch_bytes,
        &arch,
        &rtti_indices_list,
        &entity_list,
        &component_bytes,
    );

    // check if we have counted 2 types
    try testing.expectEqual(Chunk.Arch{
        .number_of_component_types = 2,
        .number_of_entities = entities.len,
    }, arch.*);

    // TODO: this depend on hashing algo, and which type is hashed to a lower value ...
    //       find a more robust way of checking this
    const expected_rtti_indices_list = [2]u32{ 0, 1 };
    try testing.expectEqualSlices(
        u32,
        &expected_rtti_indices_list,
        rtti_indices_list[0..arch.number_of_component_types],
    );

    try testing.expectEqualSlices(
        Entity,
        &entities,
        entity_list[0..arch.number_of_entities],
    );
}