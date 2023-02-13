const std = @import("std");
const Allocator = std.mem.Allocator;
const world = @import("world.zig");

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
        pub fn serialize(allocator: Allocator, initial_byte_size: usize, world_to_serialize: *const World) ![]const u8 {
            const inital_written_size = @max(@sizeOf(Chunk.Ezby), initial_byte_size);
            var written_bytes = try ByteList.initCapacity(allocator, inital_written_size);
            errdefer written_bytes.deinit();

            const ezby_chunk = Chunk.Ezby{
                .version_major = version_major,
                .version_minor = version_minor,
                .version_patch = version_patch,
                .eref_chunks = 0,
                .comp_chunks = 0,
                .arch_chunks = 0,
            };
            // append partially complete ezby chunk to ensure these bytes are used by the ezby chunk
            written_bytes.appendSliceAssumeCapacity(std.mem.asBytes(&ezby_chunk));

            var eref_chunk_count: u8 = 0;
            var comp_chunk_count: u8 = 0;
            var arch_chunk_count: u8 = 0;

            _ = world_to_serialize;

            var owned_slize = try written_bytes.toOwnedSlice();

            // write chunk counts
            owned_slize[@offsetOf(Chunk.Ezby, "eref_chunks")] = eref_chunk_count;
            owned_slize[@offsetOf(Chunk.Ezby, "comp_chunks")] = comp_chunk_count;
            owned_slize[@offsetOf(Chunk.Ezby, "arch_chunks")] = arch_chunk_count;

            return owned_slize;
        }

        // pub fn deserialize(allocator: Allocator, ezby_bytes: []const u8) !World {}

        /// parse ezby chunk from bytes and return remaining bytes
        fn parseEzbyChunk(bytes: []const u8, chunk: **const Chunk.Ezby) []const u8 {
            std.debug.assert(bytes.len >= @sizeOf(Chunk.Ezby));

            chunk.* = @ptrCast(*const Chunk.Ezby, @alignCast(@alignOf(Chunk.Ezby), bytes.ptr));
            return bytes[@sizeOf(Chunk.Ezby)..];
        }
    };
}

pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = std.mem.bytesToValue(u32, "ezby"),
        version_major: u8,
        version_minor: u8,
        version_patch: u8,
        eref_chunks: u16,
        comp_chunks: u16,
        arch_chunks: u16,
    };
    pub const Eref = packed struct {};
};

const testing = std.testing;
test "serializing then using parseEzbyChunk produce same ezby chunk" {
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
        .eref_chunks = 0,
        .comp_chunks = 0,
        .arch_chunks = 0,
    }, ezby.*);
}
