const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("../ecez_ztracy.zig");
const entity_type = @import("../entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;
const Color = @import("../misc.zig").Color;
const set = @import("../sparse_set.zig");
const CompileReflect = @import("../storage.zig").CompileReflect;
const common = @import("common.zig");
const CreateConfig = @import("CreateConfig.zig");
const SubmitConfig = @import("SubmitConfig.zig");

pub fn Create(config: CreateConfig) type {
    return struct {
        // Read by dependency_chain
        pub const _result_fields = config.result_fields[config.result_start_index..];
        // Read by dependency_chain
        pub const _include_types = config.query_components[config.result_component_count..config.exclude_type_start];
        // Read by dependency_chain
        pub const _exclude_types = config.query_components[config.exclude_type_start..];

        pub const EcezType = CreateConfig.QueryType;

        pub const ThisQuery = @This();

        sparse_cursors: EntityId,
        start_cursor: EntityId,

        full_sparse_sets: [config.full_sparse_set_count]*const set.Sparse.Full,
        dense_sets: CompileReflect.GroupDenseSetsConstPtr(config.query_components),

        tag_sparse_sets: [config.tag_sparse_set_count]*const set.Sparse.Tag,

        result_entities_bit_count: EntityId,
        result_entities_bitmap: []const EntityId,

        pub fn submit(allocator: Allocator, storage: anytype) error{OutOfMemory}!ThisQuery {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // verify that storage is a ecez.Storage type
            comptime SubmitConfig.verifyStorageType(@TypeOf(storage));

            // Atomically load the current number of entities
            const number_of_entities = storage.created_entity_count.load(.monotonic);

            const biggest_set_len, const tag_sparse_sets, const full_sparse_sets, const dense_sets = retrieve_component_sets_blk: {
                var _biggest_set_len: EntityId = 0;
                var _tag_sparse_sets: [config.tag_sparse_set_count]*const set.Sparse.Tag = undefined;
                var _full_sparse_sets: [config.full_sparse_set_count]*const set.Sparse.Full = undefined;
                var _dense_sets: CompileReflect.GroupDenseSetsConstPtr(config.query_components) = undefined;

                comptime var full_sparse_sets_index: u32 = 0;
                comptime var tag_sparse_sets_index: u32 = 0;
                inline for (config.query_components) |Component| {
                    const sparse_set_ptr = storage.getSparseSetConstPtr(Component);

                    if (@sizeOf(Component) > 0) {
                        _biggest_set_len = @max(_biggest_set_len, sparse_set_ptr.sparse_len);

                        _full_sparse_sets[full_sparse_sets_index] = sparse_set_ptr;
                        full_sparse_sets_index += 1;

                        @field(_dense_sets, @typeName(Component)) = storage.getDenseSetPtr(Component);
                    } else {
                        _biggest_set_len = @max(_biggest_set_len, sparse_set_ptr.sparse_len * @bitSizeOf(EntityId));

                        _tag_sparse_sets[tag_sparse_sets_index] = sparse_set_ptr;
                        tag_sparse_sets_index += 1;
                    }
                }

                std.debug.assert(full_sparse_sets_index == config.full_sparse_set_count);
                std.debug.assert(tag_sparse_sets_index == config.tag_sparse_set_count);

                break :retrieve_component_sets_blk .{
                    @min(_biggest_set_len, number_of_entities),
                    _tag_sparse_sets,
                    _full_sparse_sets,
                    _dense_sets,
                };
            };

            const full_set_search_order, const full_set_is_include = common.calculateSearchOrder(config, _result_fields, storage, number_of_entities);

            const worst_case_bitmap_count = std.math.divCeil(EntityId, biggest_set_len, @bitSizeOf(EntityId)) catch unreachable;
            const result_entities_bitmap = try allocator.alloc(EntityId, worst_case_bitmap_count);
            errdefer allocator.free(result_entities_bitmap);

            // initialize all bits as a query hit (1)
            // each check will reduce result if a miss
            @memset(result_entities_bitmap, std.math.maxInt(EntityId));

            // handle any tag components and store result
            if (comptime config.tag_sparse_set_count > 0) {
                inline for (tag_sparse_sets, 0..) |tag_sparse_set, sparse_index| {
                    const is_include_set = sparse_index < config.tag_exclude_start;
                    const sparse_len = tag_sparse_set.sparse_len;

                    // if out of set bound, consider remaining entities as missing component
                    if (is_include_set) {
                        for (tag_sparse_set.sparse_bits[0..sparse_len], result_entities_bitmap[0..sparse_len]) |sparse_bits, *result_bitmap| {
                            // The not (~) may seem counterintutive, but: 1 signals "not set" in the sparse set.
                            result_bitmap.* &= ~sparse_bits;
                        }

                        // For the remaining entities, they do not have this component as sparse set len < entity id
                        for (result_entities_bitmap[sparse_len..]) |*result_bitmap| {
                            result_bitmap.* = 0;
                        }
                    } else {
                        for (tag_sparse_set.sparse_bits[0..sparse_len], result_entities_bitmap[0..sparse_len]) |sparse_bits, *result_bitmap| {
                            result_bitmap.* &= sparse_bits;
                        }
                    }
                }
            }

            for (full_set_search_order, full_set_is_include) |this_search, is_include_set| {
                const sparse_set = full_sparse_sets[this_search];
                const sparse_len = @min(number_of_entities, sparse_set.sparse_len);

                for (sparse_set.sparse[0..sparse_len], 0..) |dense_index, entity| {
                    // Check if this bitmap entry has any set results, or if we can skip it
                    if (@rem(entity, @bitSizeOf(EntityId)) == 0) {
                        const bit_index = @divFloor(entity, @bitSizeOf(EntityId));
                        if (result_entities_bitmap[bit_index] == 0) {
                            continue;
                        }
                    }

                    // Check if we have query hit for entity:
                    const entry_is_set = dense_index != set.Sparse.not_set;
                    const should_be_set = entry_is_set == is_include_set;

                    if (should_be_set == false) {
                        const bit_index = @divFloor(entity, @bitSizeOf(EntityId));

                        // u5 assuming EntityId = u32
                        comptime std.debug.assert(EntityId == u32);
                        const nth_bit: u5 = @intCast(@rem(entity, @bitSizeOf(EntityId)));
                        result_entities_bitmap[bit_index] &= ~(@as(EntityId, 1) << nth_bit);
                    }
                }

                // if out of set bound, consider remaining entities as missing component
                if (is_include_set) {
                    if (sparse_len != 0) {
                        @branchHint(.likely);

                        const last_index = sparse_len - 1;
                        const bit_index = @divFloor(last_index, @bitSizeOf(EntityId));
                        if (@rem(last_index, @bitSizeOf(EntityId)) != 31) {
                            // populate partial bitmap
                            comptime std.debug.assert(EntityId == u32);
                            const partial_bitmap_offset: u5 = @intCast(@rem(sparse_len, @bitSizeOf(EntityId)));
                            const partial_bitmap_set_bits = (@as(EntityId, 1) << (partial_bitmap_offset)) - 1;
                            result_entities_bitmap[bit_index] &= partial_bitmap_set_bits;
                        }

                        if (bit_index + 1 < result_entities_bitmap.len) {
                            // fill remaining bitmaps as all entities are missing
                            for (result_entities_bitmap[bit_index + 1 ..]) |*bitmap| {
                                bitmap.* = 0;
                            }
                        }
                    } else {
                        for (result_entities_bitmap) |*bitmap| {
                            bitmap.* = 0;
                        }
                    }
                }
            }

            return ThisQuery{
                .sparse_cursors = 0,
                .start_cursor = 0,
                .full_sparse_sets = full_sparse_sets,
                .dense_sets = dense_sets,
                .tag_sparse_sets = tag_sparse_sets,
                .result_entities_bit_count = biggest_set_len,
                .result_entities_bitmap = result_entities_bitmap,
            };
        }

        pub fn deinit(self: *ThisQuery, allocator: Allocator) void {
            allocator.free(self.result_entities_bitmap);
        }

        pub fn next(self: *ThisQuery) ?config.ResultItem {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // Find next entity
            goto_next_cursor_loop: while (self.sparse_cursors < self.result_entities_bit_count) {
                const bitmap_index = @divFloor(self.sparse_cursors, @bitSizeOf(EntityId));
                comptime std.debug.assert(EntityId == u32);
                const bitmap_bit_offset: u5 = @intCast(@rem(self.sparse_cursors, @bitSizeOf(EntityId)));

                const cursor_bit = @as(EntityId, 1) << bitmap_bit_offset;
                const cursor_bitmap = self.result_entities_bitmap[bitmap_index];
                // If cursor is pointing at a query hit then exit
                if ((cursor_bitmap & cursor_bit) != 0) {
                    break :goto_next_cursor_loop;
                }

                const next_set_bit_distance = @ctz(self.result_entities_bitmap[bitmap_index] >> bitmap_bit_offset);
                const next_bitmap_distance = @bitSizeOf(EntityId) - @as(EntityId, @intCast(bitmap_bit_offset));
                self.sparse_cursors += @min(next_bitmap_distance, next_set_bit_distance);
            }
            if (self.sparse_cursors >= self.result_entities_bit_count + self.start_cursor) {
                return null;
            }
            defer self.sparse_cursors += 1;

            return common.populateResult(self, config);
        }

        pub fn skip(self: *ThisQuery, skip_count: u32) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            self.sparse_cursors = @min(self.sparse_cursors, self.result_entities_bit_count);
            const actual_skip_count = @min(skip_count, self.result_entities_bit_count - self.sparse_cursors);

            const pre_skip_cursor = self.sparse_cursors;
            while (self.sparse_cursors - pre_skip_cursor < actual_skip_count) {
                const bitmap_index = @divFloor(self.sparse_cursors, @bitSizeOf(EntityId));
                comptime std.debug.assert(EntityId == u32);
                const bitmap_bit_offset: u5 = @intCast(@rem(self.sparse_cursors, @bitSizeOf(EntityId)));

                const cursor_bit = @as(EntityId, 1) << bitmap_bit_offset;
                const cursor_bitmap = self.result_entities_bitmap[bitmap_index];
                // If cursor is pointing at a query hit then exit
                if ((cursor_bitmap & cursor_bit) != 0) {
                    self.sparse_cursors += 1;
                    continue;
                }

                const next_set_bit_distance = @ctz(self.result_entities_bitmap[bitmap_index] >> bitmap_bit_offset);
                const next_bitmap_distance = @bitSizeOf(EntityId) - @as(EntityId, @intCast(bitmap_bit_offset));
                self.sparse_cursors += @min(next_bitmap_distance, next_set_bit_distance);
            }
        }

        pub fn reset(self: *ThisQuery) void {
            self.sparse_cursors = self.start_cursor;
        }

        pub fn split(self: *ThisQuery, other_queries: []ThisQuery) void {
            std.debug.assert(other_queries.len > 0);

            const self_count: EntityId = 1;
            const split_count: EntityId = @intCast(other_queries.len + self_count);
            const total_result_entities_bit_count = self.result_entities_bit_count;
            const split_result_entities_bit_count = std.math.divFloor(EntityId, total_result_entities_bit_count, split_count) catch unreachable;

            // Update the other queries
            {
                // For all other queries
                for (other_queries, 1..) |*other_query, query_number| {
                    other_query.result_entities_bit_count = split_result_entities_bit_count;
                    other_query.sparse_cursors = other_query.result_entities_bit_count * @as(EntityId, @intCast(query_number));
                    other_query.start_cursor = other_query.sparse_cursors;

                    other_query.full_sparse_sets = self.full_sparse_sets;
                    other_query.dense_sets = self.dense_sets;
                    other_query.result_entities_bitmap = self.result_entities_bitmap;
                }

                // For last query add remaining
                other_queries[other_queries.len - 1].result_entities_bit_count += std.math.rem(EntityId, total_result_entities_bit_count, split_count) catch unreachable;
            }

            // Update this query
            self.result_entities_bit_count = split_result_entities_bit_count;
            self.sparse_cursors = 0;
            self.start_cursor = 0;
        }
    };
}
