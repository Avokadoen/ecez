const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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

/// Generate an ecby serializer. The type needs the components used which will be used to get a world type
pub fn Serializer(comptime components: anytype) type {
    return struct {
        const version_major = 0;
        const version_minor = 1;
        const version_patch = 0;

        const World = world.WorldBuilder().WithComponents(components).Build();
        const ByteList = std.ArrayList(u8);

        // TODO: option to use stack instead of heap
        // TODO: heavily hint that arena allocator should be used?
        /// Serialize a world instance to a byte array. The caller owns the returned memory
        pub fn serialize(allocator: Allocator, initial_byte_size: usize, world_to_serialize: *const World) ![]const u8 {
            const inital_written_size = @max(@sizeOf(Chunk.Ezby), initial_byte_size);
            var written_bytes = try ByteList.initCapacity(allocator, inital_written_size);

            var comp_chunk_count: u8 = 0;
            var arch_chunk_count: u8 = 0;

            var owned_slize = blk: {
                errdefer written_bytes.deinit();

                const ezby_chunk = Chunk.Ezby{
                    .version_major = version_major,
                    .version_minor = version_minor,
                    .version_patch = version_patch,
                    .comp_chunks = 0,
                    .arch_chunks = 0,
                };
                // append partially complete ezby chunk to ensure these bytes are used by the ezby chunk
                written_bytes.appendSliceAssumeCapacity(mem.asBytes(&ezby_chunk));

                // append comp data
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

                    comp_chunk_count += 1;
                }

                // step through the archetype tree and serialize each archetype
                path_iter: for (world_to_serialize.container.archetype_paths.items[1..]) |path| {
                    const archetype: *OpaqueArchetype = blk1: {
                        // step through the path to find the current archetype
                        if (path.len > 0 and path.indices.len > 0) {
                            var current_node = &world_to_serialize.container.root_node;
                            for (path.indices[0 .. path.len - 1]) |step| {
                                current_node = &current_node.children[step].?;
                            }

                            // get the archetype of the path
                            break :blk1 &current_node.archetypes[path.indices[path.len - 1]].?.archetype;
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

                            break :blk2 entity_count * (entity_map_key_size + entity_map_value_size);
                        };

                        const type_map_size = type_count * @sizeOf(u64) * 2;

                        const component_bytes_size = blk2: {
                            var type_info_iter = archetype.type_info.iterator();

                            var size: usize = 0;
                            for (archetype.component_storage) |component_bytes| {
                                const type_info = type_info_iter.next() orelse unreachable;
                                size = component_bytes.items.len * type_info.value_ptr.size;
                            }
                            break :blk2 @intCast(u64, size);
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
                        }
                    }
                }

                break :blk try written_bytes.toOwnedSlice();
            };
            errdefer allocator.free(owned_slize);

            // write chunk counts, when we finally know how many chunks we have
            owned_slize[@offsetOf(Chunk.Ezby, "comp_chunks")] = comp_chunk_count;
            owned_slize[@offsetOf(Chunk.Ezby, "arch_chunks")] = arch_chunk_count;

            return owned_slize;
        }

        // pub fn deserialize(allocator: Allocator, ezby_bytes: []const u8) !World {}
    };
}

pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"), // TODO: only serialize, do not include as runtime data
        version_major: u8,
        version_minor: u8,
        version_patch: u8,
        reserved_1: u8 = 0,
        comp_chunks: u16,
        arch_chunks: u16,
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
fn parseEzbyChunk(bytes: []const u8, chunk: **const Chunk.Ezby) []const u8 {
    std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));
    std.debug.assert(mem.eql(u8, bytes[0..4], "EZBY"));

    chunk.* = @ptrCast(*const Chunk.Ezby, @alignCast(@alignOf(Chunk.Ezby), bytes.ptr));
    return bytes[@sizeOf(Chunk.Ezby)..];
}

test "serializing then using parseEzbyChunk produce expected EZBY chunk" {
    const Serialize = Serializer(.{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    const bytes = try Serialize.serialize(testing.allocator, 516, &dummy_world);
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = Serialize.version_major,
        .version_minor = Serialize.version_minor,
        .version_patch = Serialize.version_patch,
        .comp_chunks = 1,
        .arch_chunks = 0,
    }, ezby.*);
}

/// parse COMP chunk from bytes and return remaining bytes
fn parseCompChunk(
    bytes: []const u8,
    chunk: **const Chunk.Comp,
    hash_list: *Chunk.Comp.HashList,
    size_list: *Chunk.Comp.SizeList,
) []const u8 {
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

test "serializing then using parseCompChunk produce expected COMP chunk" {
    const Serialize = Serializer(.{
        ez_testing.Component.A,
        ez_testing.Component.B,
    });
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    var a = ez_testing.Component.A{};
    var b = ez_testing.Component.B{};
    _ = try dummy_world.createEntity(.{ a, b });

    const bytes = try Serialize.serialize(testing.allocator, 516, &dummy_world);
    defer testing.allocator.free(bytes);

    // parse ezby header to get to eref bytes
    var ezby: *Chunk.Ezby = undefined;
    const eref_bytes = parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(
        @as(u16, 1),
        ezby.comp_chunks,
    );

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

fn parseArchChunk(
    bytes: []const u8,
    chunk: **const Chunk.Arch,
    rtti_list: *Chunk.Arch.RttiList,
    entity_map_list: *Chunk.Arch.EntityMapList,
    component_bytes: *[*]const u8,
) []const u8 {
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

    const component_bytes_offset = entity_map_list_offset + chunk.*.number_of_components * @sizeOf(Chunk.Arch.EntityMap);
    component_bytes.* = bytes[component_bytes_offset..].ptr;

    const remaining_bytes_offset = blk: {
        var component_byte_size: u64 = 0;
        for (rtti_list.*[0..chunk.*.number_of_components]) |component_rtti| {
            component_byte_size += component_rtti.size * chunk.*.number_of_entities;
        }
        break :blk component_bytes_offset + component_byte_size;
    };

    return bytes[remaining_bytes_offset..];
}

test "serializing then using parseArchChunk produce expected ARCH chunk" {
    const Serialize = Serializer(.{
        ez_testing.Component.A,
        ez_testing.Component.B,
    });
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    var a = ez_testing.Component.A{};
    var b = ez_testing.Component.B{};

    const entities_to_create = 10;
    {
        var i: usize = 0;
        while (i < entities_to_create) : (i += 1) {
            _ = try dummy_world.createEntity(.{ a, b });
        }
    }

    const bytes = try Serialize.serialize(testing.allocator, 516, &dummy_world);
    defer testing.allocator.free(bytes);

    const arch_bytes = blk: {
        // parse ezby header to get to eref bytes
        var ezby: *Chunk.Ezby = undefined;
        const eref_bytes = parseEzbyChunk(bytes, &ezby);

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
}
