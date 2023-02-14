const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const world = @import("world.zig");
const entity_type = @import("entity_type.zig");
const EntityRef = entity_type.EntityRef;

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
                    .eref_chunks = 1, // currently this should always we one
                    .comp_chunks = 0,
                    .arch_chunks = 0,
                };
                // append partially complete ezby chunk to ensure these bytes are used by the ezby chunk
                written_bytes.appendSliceAssumeCapacity(mem.asBytes(&ezby_chunk));

                // TODO: does this make the code easier to read, or should it just be removed?
                const eref_chunk = Chunk.Eref{
                    .number_of_references = @intCast(u64, world_to_serialize.container.entity_references.items.len),
                };
                // append eref data
                try written_bytes.appendSlice(mem.asBytes(&eref_chunk));

                try written_bytes.appendSlice(
                    @ptrCast([*]u8, world_to_serialize.container.entity_references.items.ptr)[0 .. eref_chunk.number_of_references * @sizeOf(EntityRef)],
                );

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

        /// parse EREF chunk from bytes and return remaining bytes
        fn parseErefChunk(bytes: []const u8, chunk: **const Chunk.Eref, references: *Chunk.ErefRef) []const u8 {
            std.debug.assert(bytes.len >= @sizeOf(Chunk.Eref));
            std.debug.assert(mem.eql(u8, bytes[0..4], "EREF"));

            chunk.* = @ptrCast(
                *const Chunk.Eref,
                @alignCast(@alignOf(Chunk.Eref), bytes.ptr),
            );
            references.* = @ptrCast(
                Chunk.ErefRef,
                @alignCast(@alignOf(Chunk.ErefRef), bytes[@sizeOf(Chunk.Eref)..].ptr),
            );

            const next_byte = @sizeOf(Chunk.Eref) + chunk.*.number_of_references * @sizeOf(EntityRef);
            return bytes[next_byte..];
        }
    };
}

pub const Chunk = struct {
    pub const Ezby = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EZBY"),
        version_major: u8,
        version_minor: u8,
        version_patch: u8,
        reserved_1: u8 = 0,
        eref_chunks: u16,
        comp_chunks: u16,
        arch_chunks: u16,
        reserved_2: u16 = 0,
    };
    pub const Eref = packed struct {
        identifier: u32 = mem.bytesToValue(u32, "EREF"),
        reserved_1: u32 = 0,
        number_of_references: u64,
        // references: ErefRef,
    };
    pub const ErefRef = [*]const EntityRef;
};

const testing = std.testing;
const ez_testing = @import("Testing.zig");

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
        .eref_chunks = 1,
        .comp_chunks = 0,
        .arch_chunks = 0,
    }, ezby.*);
}

test "serializing then using parseErefChunk produce same eref chunk" {
    const Serialize = Serializer(ez_testing.AllComponentsTuple);
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

    var eref: *Chunk.Eref = undefined;
    var eref_ref: Chunk.ErefRef = undefined;
    _ = Serialize.parseErefChunk(eref_bytes, &eref, &eref_ref);

    // assert that we see some (sadly very implementation specific) state
    // we expect from the entity reference. We skip index 0 since this is
    // undefined and represent a "void" reference which we serialize for simplicity
    try testing.expectEqual(@as(u32, 0), eref.reserved_1);
    try testing.expectEqual(@as(u64, 2), eref.number_of_references);
    try testing.expectEqual(@as(entity_type.EntityRef, 2), eref_ref[1]);
}
