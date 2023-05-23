const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const world = @import("world.zig");
const entity_type = @import("entity_type.zig");
const EntityRef = entity_type.EntityRef;
const Entity = entity_type.Entity;
const query = @import("query.zig");
const OpaqueArchetype = @import("OpaqueArchetype.zig");
const EntityMap = entity_type.Map;

const testing = std.testing;
const ez_testing = @import("Testing.zig");

// TODO: option to use stack instead of heap

pub const version_major = 0;
pub const version_minor = 1;
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

/// Generate an ecby serializer. The type needs the components used which will be used to get a world type
pub fn Serializer(comptime components: anytype, comptime shared_state: anytype, comptime events: anytype) type {
    return struct {
        pub const World = world.WorldBuilder().WithComponents(components).WithSharedState(shared_state).WithEvents(events).Build();
        const ByteList = std.ArrayList(u8);

        // TODO: option to use stack instead of heap
        // TODO: heavily hint that arena allocator should be used?
        /// Serialize a world instance to a byte array. The caller owns the returned memory
        pub fn serialize(allocator: Allocator, initial_byte_size: usize, world_to_serialize: World) SerializeError![]const u8 {
            const zone = ztracy.ZoneNC(@src(), "Ezby serialize", Color.serializer);
            defer zone.End();

            // TODO: replace with @max(@sizeOf(Chunk.Ezby), initial_byte_size), related issue https://github.com/ziglang/zig/issues/15828 (not sure which issue)
            const inital_written_size = if (@sizeOf(Chunk.Ezby) > initial_byte_size) @sizeOf(Chunk.Ezby) else initial_byte_size;

            var written_bytes = try ByteList.initCapacity(allocator, inital_written_size);
            errdefer written_bytes.deinit();

            const ezby_chunk = Chunk.Ezby{
                .version_major = version_major,
                .version_minor = version_minor,
            };
            // append partially complete ezby chunk to ensure these bytes are used by the ezby chunk
            written_bytes.appendSliceAssumeCapacity(mem.asBytes(&ezby_chunk));

            // append component type data (COMP)
            {
                const comp_chunk = Chunk.Comp{
                    .number_of_components = @intCast(u32, world_to_serialize.container.component_hashes.len),
                };
                try written_bytes.appendSlice(mem.asBytes(&comp_chunk));
                try written_bytes.appendSlice(
                    @ptrCast(
                        [*]const u8,
                        &world_to_serialize.container.component_hashes,
                    )[0 .. comp_chunk.number_of_components * @sizeOf(Chunk.Comp.Rtti)],
                );
                try written_bytes.appendSlice(
                    @ptrCast(
                        [*]const u8,
                        &world_to_serialize.container.component_sizes,
                    )[0 .. comp_chunk.number_of_components * @sizeOf(Chunk.Comp.Rtti)],
                );
            }

            // step through the archetype tree and serialize each archetype (ARCH)
            path_iter: for (world_to_serialize.container.archetype_paths.items[1..]) |path| {
                const archetype: *OpaqueArchetype = blk1: {
                    // step through the path to find the current archetype
                    if (path.len > 0 and path.indices.len > 0) {
                        var current_node = &world_to_serialize.container.root_node;
                        for (path.indices[0 .. path.len - 1]) |step| {
                            current_node = &current_node.children[step].?;
                        }

                        // get the archetype index from the path
                        const index = current_node.archetype_references[path.indices[path.len - 1]].?.archetype_index;

                        break :blk1 &world_to_serialize.container.archetypes.items[index];
                    }
                    continue :path_iter;
                };

                const entity_count = archetype.entities.count();
                const type_count = archetype.type_info.count();
                std.debug.assert(archetype.component_storage.len == type_count);

                // calculate arch chunk size
                const arch_chunk_size = blk1: {
                    const entity_map_size = blk2: {
                        const kv_info = @typeInfo(EntityMap.KV).Struct;

                        const entity_map_key_size = @sizeOf(kv_info.fields[0].type);
                        const entity_map_value_size = @sizeOf(kv_info.fields[1].type);
                        const pad_size = 4;
                        break :blk2 entity_count * (entity_map_key_size + entity_map_value_size + pad_size);
                    };

                    const type_map_size = type_count * @sizeOf(u64) * 2;

                    const component_bytes_size = blk2: {
                        var size: usize = 0;
                        for (archetype.component_storage) |component_bytes| {
                            size += pow2Align(usize, component_bytes.items.len, alignment);
                        }
                        break :blk2 size;
                    };
                    break :blk1 @sizeOf(Chunk.Arch) + type_map_size + entity_map_size + component_bytes_size;
                };

                // ensure we will have enough capacity for the ARCH chunk
                try written_bytes.ensureUnusedCapacity(arch_chunk_size);
                {
                    const arch_chunk = Chunk.Arch{
                        .number_of_components = @intCast(u32, type_count),
                        .number_of_entities = @intCast(u64, entity_count),
                    };
                    written_bytes.appendSliceAssumeCapacity(mem.asBytes(&arch_chunk));

                    // serialize Arch.RttiList
                    var type_info_iter = archetype.type_info.iterator();
                    while (type_info_iter.next()) |type_info| {
                        written_bytes.appendSliceAssumeCapacity(mem.asBytes(type_info.key_ptr));
                        const type_size = @intCast(u64, type_info.value_ptr.size);
                        written_bytes.appendSliceAssumeCapacity(mem.asBytes(&type_size));
                    }

                    // serialize Arch.EntityMapList
                    const padding: u32 = 0;
                    var entity_iter = archetype.entities.iterator();
                    while (entity_iter.next()) |entry| {
                        // entity key
                        written_bytes.appendSliceAssumeCapacity(mem.asBytes(entry.key_ptr));
                        written_bytes.appendSliceAssumeCapacity(mem.asBytes(&padding));
                        // component index
                        written_bytes.appendSliceAssumeCapacity(mem.asBytes(entry.value_ptr));
                    }

                    // append component bytes
                    for (archetype.component_storage) |component_bytes| {
                        written_bytes.appendSliceAssumeCapacity(component_bytes.items);

                        const align_padding = pow2Align(usize, component_bytes.items.len, alignment) - component_bytes.items.len;
                        written_bytes.appendNTimesAssumeCapacity(0, align_padding);
                    }
                }
            }

            return written_bytes.toOwnedSlice();
        }

        /// Deserialize the supplied bytes and insert them into the world. This function will
        /// clear the world memory which means that all that currently in the world will be
        /// wiped.
        pub fn deserialize(dest_world: *World, ezby_bytes: []const u8) DeserializeError!void {
            var bytes_pos = ezby_bytes;

            // parse and validate ezby header
            var ezby_chunk: *Chunk.Ezby = undefined;
            bytes_pos = try parseEzbyChunk(ezby_bytes, &ezby_chunk);

            if (ezby_chunk.version_major != version_major or ezby_chunk.version_minor > version_minor) {
                return DeserializeError.VersionMismatch;
            }

            // parse and validate component RTTI
            {
                var comp: *Chunk.Comp = undefined;
                var hash_list: Chunk.Comp.HashList = undefined;
                var size_list: Chunk.Comp.SizeList = undefined;
                bytes_pos = parseCompChunk(bytes_pos, &comp, &hash_list, &size_list);
                for (hash_list[0..comp.number_of_components]) |type_hash| {
                    var hash_found = false;
                    search: inline for (components) |Component| {
                        if (query.hashType(Component) == type_hash) {
                            hash_found = true;
                            break :search;
                        }
                    }

                    if (hash_found == false) {
                        // this content contain invalid component type(s) and the serializer is
                        // therefore missing static information needed to utilize the component
                        // data related to this/these types.
                        return DeserializeError.UnknownComponentType;
                    }
                }
            }

            // clear the world before inserting the byte content into the world
            dest_world.clearRetainingCapacity();

            // loop all archetype chunks and insert them into the world
            while (bytes_pos.len > 0) {
                var arch: *Chunk.Arch = undefined;
                var rtti_list: Chunk.Arch.RttiList = undefined;
                var entity_map_list: Chunk.Arch.EntityMapList = undefined;
                var component_bytes: [*]const u8 = undefined;
                const new_bytes_pos = parseArchChunk(bytes_pos, &arch, &rtti_list, &entity_map_list, &component_bytes);
                defer bytes_pos = new_bytes_pos;

                // TODO: This is the worst case use of the ecez api where we add one and one component
                //       which forces a lot of moves of data. We must find an alternative way of loading
                //       this data. Also this code is just hot garbage :/
                for (0..arch.number_of_entities) |nth_entity| {
                    const entity = try dest_world.createEntity(.{});

                    for (rtti_list[0..arch.number_of_components], 0..) |rtti, rtti_index| {
                        inline for (components) |Component| {
                            if (query.hashType(Component) == rtti.hash) {
                                std.debug.assert(rtti.size == @sizeOf(Component));

                                // offset bytes by how many bytes in current component type offset we are
                                var byte_offset: u64 = rtti.size * nth_entity;
                                for (rtti_list[0..rtti_index]) |prev_rtti| {
                                    // offset bytes by how many bytes were in the previous types
                                    byte_offset += pow2Align(usize, prev_rtti.size * arch.number_of_entities, alignment);
                                }

                                const component = switch (@alignOf(Component)) {
                                    0 => @ptrCast(*const Component, &[0]u8{}),
                                    1...alignment => @ptrCast(*const Component, @alignCast(
                                        @alignOf(Component),
                                        component_bytes[byte_offset .. byte_offset + rtti.size].ptr,
                                    )),
                                    else => blk: {
                                        // We work around potential issues caused by increased alignment by moving
                                        // the byte slice to a static array (which moves the memory on the stack),
                                        // and then converting the array data to a Component pointer
                                        var arr_bytes: [@sizeOf(Component)]u8 = undefined;
                                        std.mem.copy(u8, &arr_bytes, component_bytes[byte_offset .. byte_offset + rtti.size]);
                                        break :blk std.mem.bytesAsValue(Component, &arr_bytes);
                                    },
                                };

                                dest_world.setComponent(entity, component.*) catch |err| switch (err) {
                                    error.EntityMissing => unreachable,
                                    error.OutOfMemory => |oom_err| return oom_err,
                                };
                            }
                        }
                    }
                }
            }
        }
    };
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
        number_of_components: u32,

        /// Run-time type information
        pub const Rtti = u64;
        pub const HashList = [*]const u64;
        pub const SizeList = [*]const u64;
    };

    pub const Arch = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "ARCH"), // TODO: only serialize, do not include as runtime data
        // TODO: rename to component_types
        /// how many component byte lists that are after this chunk
        number_of_components: u32,
        number_of_entities: u64,

        /// Run-time type information
        pub const Rtti = packed struct {
            hash: u64,
            size: u64,
        };
        pub const RttiList = [*]const Rtti;

        pub const EntityMap = packed struct {
            entity: Entity,
            padding: u32,
            index: u64,
        };
        pub const EntityMapList = [*]const Arch.EntityMap;
    };
};

/// parse EZBY chunk from bytes and return remaining bytes
fn parseEzbyChunk(bytes: []const u8, chunk: **const Chunk.Ezby) error{UnexpectedEzbyIdentifier}![]const u8 {
    const zone = ztracy.ZoneNC(@src(), "Parse EZBY chunk", Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));

    if (mem.eql(u8, bytes[0..4], "EZBY") == false) {
        return error.UnexpectedEzbyIdentifier;
    }

    chunk.* = @ptrCast(*const Chunk.Ezby, @alignCast(@alignOf(Chunk.Ezby), bytes.ptr));
    return bytes[@sizeOf(Chunk.Ezby)..];
}

/// parse COMP chunk from bytes and return remaining bytes
fn parseCompChunk(
    bytes: []const u8,
    chunk: **const Chunk.Comp,
    hash_list: *Chunk.Comp.HashList,
    size_list: *Chunk.Comp.SizeList,
) []const u8 {
    const zone = ztracy.ZoneNC(@src(), "Parse COMP chunk", Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Comp));
    std.debug.assert(mem.eql(u8, bytes[0..4], "COMP"));

    chunk.* = @ptrCast(
        *const Chunk.Comp,
        @alignCast(@alignOf(Chunk.Comp), bytes.ptr),
    );
    hash_list.* = @ptrCast(
        Chunk.Comp.HashList,
        @alignCast(@alignOf(Chunk.Comp.HashList), bytes[@sizeOf(Chunk.Comp)..].ptr),
    );

    const list_size = chunk.*.number_of_components * @sizeOf(Chunk.Comp.Rtti);
    size_list.* = @ptrCast(
        Chunk.Comp.SizeList,
        @alignCast(@alignOf(Chunk.Comp.SizeList), bytes[@sizeOf(Chunk.Comp) + list_size ..].ptr),
    );

    // TODO: verify that components we used to initialize world with are in one of these chunks
    const next_byte = @sizeOf(Chunk.Comp) + list_size * 2;
    return bytes[next_byte..];
}

fn parseArchChunk(
    bytes: []const u8,
    chunk: **const Chunk.Arch,
    rtti_list: *Chunk.Arch.RttiList,
    entity_map_list: *Chunk.Arch.EntityMapList,
    component_bytes: *[*]const u8,
) []const u8 {
    const zone = ztracy.ZoneNC(@src(), "Parse ARCH chunk", Color.serializer);
    defer zone.End();

    std.debug.assert(bytes.len >= @sizeOf(Chunk.Arch));
    std.debug.assert(mem.eql(u8, bytes[0..4], "ARCH"));

    chunk.* = @ptrCast(
        *const Chunk.Arch,
        @alignCast(@alignOf(Chunk.Arch), bytes.ptr),
    );

    rtti_list.* = @ptrCast(
        Chunk.Arch.RttiList,
        @alignCast(@alignOf(Chunk.Arch.RttiList), bytes[@sizeOf(Chunk.Arch)..].ptr),
    );
    const rtti_list_size = chunk.*.number_of_components * @sizeOf(Chunk.Arch.Rtti);

    const entity_map_list_offset = @sizeOf(Chunk.Arch) + rtti_list_size;
    entity_map_list.* = @ptrCast(
        Chunk.Arch.EntityMapList,
        @alignCast(@alignOf(Chunk.Arch.EntityMapList), bytes[entity_map_list_offset..].ptr),
    );
    const entity_map_size = chunk.*.number_of_entities * @sizeOf(Chunk.Arch.EntityMap);

    const component_bytes_offset = entity_map_list_offset + entity_map_size;
    component_bytes.* = bytes[component_bytes_offset..].ptr;

    const remaining_bytes_offset = blk: {
        var component_byte_size: u64 = 0;
        for (rtti_list.*[0..chunk.*.number_of_components]) |component_rtti| {
            component_byte_size += pow2Align(usize, component_rtti.size * chunk.*.number_of_entities, alignment);
        }
        break :blk component_bytes_offset + component_byte_size;
    };

    return bytes[remaining_bytes_offset..];
}

// TODO: share with src\device_memory.zig
fn pow2Align(comptime T: type, num: T, @"align": T) T {
    return (num + @"align" - 1) & ~(@"align" - 1);
}

test "serializing then using parseEzbyChunk produce expected EZBY chunk" {
    const Serialize = Serializer(.{}, .{}, .{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    const bytes = try Serialize.serialize(testing.allocator, 516, dummy_world);
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = try parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = version_major,
        .version_minor = version_minor,
    }, ezby.*);
}

test "serializing then using parseCompChunk produce expected COMP chunk" {
    const Serialize = Serializer(.{
        ez_testing.Component.A,
        ez_testing.Component.B,
    }, .{}, .{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    var a = ez_testing.Component.A{};
    var b = ez_testing.Component.B{};
    _ = try dummy_world.createEntity(.{ a, b });

    const bytes = try Serialize.serialize(testing.allocator, 516, dummy_world);
    defer testing.allocator.free(bytes);

    // parse ezby header to get to eref bytes
    var ezby: *Chunk.Ezby = undefined;
    const eref_bytes = try parseEzbyChunk(bytes, &ezby);

    var comp: *Chunk.Comp = undefined;
    var hash_list: Chunk.Comp.HashList = undefined;
    var size_list: Chunk.Comp.SizeList = undefined;
    _ = parseCompChunk(eref_bytes, &comp, &hash_list, &size_list);

    // we initialize world with 2 components
    try testing.expectEqual(
        @as(u32, 2),
        comp.number_of_components,
    );

    // check hashes
    try testing.expectEqual(
        query.hashType(ez_testing.Component.A),
        hash_list[0],
    );
    try testing.expectEqual(
        query.hashType(ez_testing.Component.B),
        hash_list[1],
    );

    // check sizes
    try testing.expectEqual(
        @as(u64, @sizeOf(ez_testing.Component.A)),
        size_list[0],
    );
    try testing.expectEqual(
        @as(u64, @sizeOf(ez_testing.Component.B)),
        size_list[1],
    );
}

test "serializing then using parseArchChunk produce expected ARCH chunk" {
    const Serialize = Serializer(.{
        ez_testing.Component.A,
        ez_testing.Component.B,
    }, .{}, .{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    var a = ez_testing.Component.A{};
    var b = ez_testing.Component.B{};

    const entities_to_create = 10;
    for (0..entities_to_create) |_| {
        _ = try dummy_world.createEntity(.{ a, b });
    }

    const bytes = try Serialize.serialize(testing.allocator, 516, dummy_world);
    defer testing.allocator.free(bytes);

    const arch_bytes = blk: {
        // parse ezby header to get to eref bytes
        var ezby: *Chunk.Ezby = undefined;
        const eref_bytes = try parseEzbyChunk(bytes, &ezby);

        var comp: *Chunk.Comp = undefined;
        var hash_list: Chunk.Comp.HashList = undefined;
        var size_list: Chunk.Comp.SizeList = undefined;
        break :blk parseCompChunk(eref_bytes, &comp, &hash_list, &size_list);
    };

    var arch: *Chunk.Arch = undefined;
    var rtti_list: Chunk.Arch.RttiList = undefined;
    var entity_map_list: Chunk.Arch.EntityMapList = undefined;
    var component_bytes: [*]const u8 = undefined;
    _ = parseArchChunk(arch_bytes, &arch, &rtti_list, &entity_map_list, &component_bytes);

    try testing.expectEqual(Chunk.Arch{
        .number_of_components = 2,
        .number_of_entities = entities_to_create,
    }, arch.*);

    // TODO: this depend on hashing algo, and which type is hashed to a lower value ...
    //       find a more robust way of checking this
    const expected_rtti_list = [2]Chunk.Arch.Rtti{
        .{ .hash = query.hashType(ez_testing.Component.A), .size = @sizeOf(ez_testing.Component.A) },
        .{ .hash = query.hashType(ez_testing.Component.B), .size = @sizeOf(ez_testing.Component.B) },
    };
    try testing.expectEqualSlices(
        Chunk.Arch.Rtti,
        &expected_rtti_list,
        rtti_list[0..arch.*.number_of_components],
    );
}

test "serialize and deserialize is idempotent" {
    const Serialize = Serializer(.{
        ez_testing.Component.A,
        ez_testing.Component.B,
        ez_testing.Component.C,
    }, .{}, .{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    const test_data_count = 128;
    var a_as: [test_data_count]ez_testing.Component.A = undefined;
    var a_entities: [test_data_count]Entity = undefined;

    for (0..test_data_count) |index| {
        a_as[index] = ez_testing.Component.A{ .value = @intCast(u32, index) };
        a_entities[index] = try dummy_world.createEntity(.{a_as[index]});
    }

    var ab_as: [test_data_count]ez_testing.Component.A = undefined;
    var ab_bs: [test_data_count]ez_testing.Component.B = undefined;
    var ab_entities: [test_data_count]Entity = undefined;
    for (0..test_data_count) |index| {
        ab_as[index] = ez_testing.Component.A{ .value = @intCast(u32, index) };
        ab_bs[index] = ez_testing.Component.B{ .value = @intCast(u8, index) };
        ab_entities[index] = try dummy_world.createEntity(.{ ab_as[index], ab_bs[index] });
    }

    var abc_as: [test_data_count]ez_testing.Component.A = undefined;
    var abc_bs: [test_data_count]ez_testing.Component.B = undefined;
    var abc_cs: ez_testing.Component.C = .{};
    var abc_entities: [test_data_count]Entity = undefined;
    for (0..test_data_count) |index| {
        abc_as[index] = ez_testing.Component.A{ .value = @intCast(u32, index) };
        abc_bs[index] = ez_testing.Component.B{ .value = @intCast(u8, index) };
        abc_entities[index] = try dummy_world.createEntity(.{ abc_as[index], abc_bs[index], abc_cs });
    }

    const bytes = try Serialize.serialize(testing.allocator, 2048, dummy_world);
    defer testing.allocator.free(bytes);

    // explicitly clear to ensure
    dummy_world.clearRetainingCapacity();
    try Serialize.deserialize(&dummy_world, bytes);

    for (0..test_data_count) |index| {
        try testing.expectEqual(a_as[index], try dummy_world.getComponent(a_entities[index], ez_testing.Component.A));
        try testing.expectError(error.ComponentMissing, dummy_world.getComponent(a_entities[index], ez_testing.Component.B));
        try testing.expectError(error.ComponentMissing, dummy_world.getComponent(a_entities[index], ez_testing.Component.C));

        try testing.expectEqual(ab_as[index], try dummy_world.getComponent(ab_entities[index], ez_testing.Component.A));
        try testing.expectEqual(ab_bs[index], try dummy_world.getComponent(ab_entities[index], ez_testing.Component.B));
        try testing.expectError(error.ComponentMissing, dummy_world.getComponent(ab_entities[index], ez_testing.Component.C));

        try testing.expectEqual(abc_as[index], try dummy_world.getComponent(abc_entities[index], ez_testing.Component.A));
        try testing.expectEqual(abc_bs[index], try dummy_world.getComponent(abc_entities[index], ez_testing.Component.B));
        try testing.expectEqual(abc_cs, try dummy_world.getComponent(abc_entities[index], ez_testing.Component.C));
    }
}

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
