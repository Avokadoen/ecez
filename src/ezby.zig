const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const world = @import("world.zig");
const entity_type = @import("entity_type.zig");
const EntityRef = entity_type.EntityRef;
const query = @import("query.zig");

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

        /// parse EZBY chunk from bytes and return remaining bytes
        fn parseEzbyChunk(bytes: []const u8, chunk: **const Chunk.Ezby) []const u8 {
            std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));
            std.debug.assert(mem.eql(u8, bytes[0..4], "EZBY"));

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
};

const testing = std.testing;
const ez_testing = @import("Testing.zig");

test "serializing then using parseEzbyChunk produce expected EZBY chunk" {
    const Serialize = Serializer(.{});
    var dummy_world = try Serialize.World.init(std.testing.allocator, .{});
    defer dummy_world.deinit();

    const bytes = try Serialize.serialize(testing.allocator, 516, &dummy_world);
    defer testing.allocator.free(bytes);

    var ezby: *Chunk.Ezby = undefined;
    _ = Serialize.parseEzbyChunk(bytes, &ezby);

    try testing.expectEqual(Chunk.Ezby{
        .version_major = Serialize.version_major,
        .version_minor = Serialize.version_minor,
        .version_patch = Serialize.version_patch,
        .comp_chunks = 0,
        .arch_chunks = 0,
    }, ezby.*);
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
    const eref_bytes = Serialize.parseEzbyChunk(bytes, &ezby);

    var comp: *Chunk.Comp = undefined;
    var hash_list: Chunk.Comp.HashList = undefined;
    var size_list: Chunk.Comp.SizeList = undefined;
    _ = Serialize.parseCompChunk(eref_bytes, &comp, &hash_list, &size_list);

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
