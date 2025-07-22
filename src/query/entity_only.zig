const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("../ecez_ztracy.zig");
const Color = @import("../misc.zig").Color;

const CreateConfig = @import("CreateConfig.zig");
const SubmitConfig = @import("SubmitConfig.zig");

const entity_type = @import("../entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

pub fn Create(comptime config: CreateConfig) type {
    return struct {
        // Read by dependency_chain
        pub const _result_fields = &[0]std.builtin.Type.StructField{};
        // Read by dependency_chain
        pub const _include_types = &[0]type{};
        // Read by dependency_chain
        pub const _exclude_types = &[0]type{};

        pub const EcezType = CreateConfig.QueryType;

        pub const ThisQuery = @This();

        sparse_cursors: EntityId,
        start_cursor: EntityId,
        entity_count: EntityId,

        pub fn submit(allocator: Allocator, storage: anytype) error{OutOfMemory}!ThisQuery {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // verify that storage is a ecez.Storage type
            comptime SubmitConfig.verifyStorageType(@TypeOf(storage));

            _ = allocator;

            return ThisQuery{
                .sparse_cursors = 0,
                .start_cursor = 0,
                .entity_count = storage.created_entity_count.load(.monotonic),
            };
        }

        pub fn deinit(self: *ThisQuery, allocator: Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn next(self: *ThisQuery) ?config.ResultItem {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            if (self.sparse_cursors >= self.entity_count + self.start_cursor) {
                return null;
            }
            defer self.sparse_cursors += 1;

            var result: config.ResultItem = undefined;
            @field(result, config.result_fields[0].name) = Entity{ .id = self.sparse_cursors };
            return result;
        }

        pub fn skip(self: *ThisQuery, skip_count: u32) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            self.sparse_cursors += skip_count;
        }

        pub fn reset(self: *ThisQuery) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            self.sparse_cursors = self.start_cursor;
        }

        pub fn split(self: *ThisQuery, other_queries: []ThisQuery) void {
            std.debug.assert(other_queries.len > 0);

            const self_count: EntityId = 1;
            const split_count: EntityId = @as(EntityId, @intCast(other_queries.len)) + self_count;
            const total_entity_count = self.entity_count;
            const split_entity_count = std.math.divFloor(EntityId, total_entity_count, split_count) catch unreachable;

            // Update the other queries
            {
                // For all other queries
                for (other_queries, 1..) |*other_query, query_number| {
                    other_query.entity_count = split_entity_count;
                    other_query.sparse_cursors = other_query.entity_count * @as(EntityId, @intCast(query_number));
                    other_query.start_cursor = other_query.sparse_cursors;
                }

                // For last query add remaining
                other_queries[other_queries.len - 1].entity_count += std.math.rem(EntityId, total_entity_count, split_count) catch unreachable;
            }

            // Update this query
            self.entity_count = split_entity_count;
            self.sparse_cursors = 0;
            self.start_cursor = 0;
        }
    };
}
