const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("../ecez_ztracy.zig");
const entity_type = @import("../entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;
const Color = @import("../misc.zig").Color;
const set = @import("../sparse_set.zig");
const CompileReflect = @import("../storage.zig").CompileReflect;
const CreateConfig = @import("CreateConfig.zig");
const SubmitConfig = @import("SubmitConfig.zig");

pub fn Create(comptime config: CreateConfig) type {
    if (config.query_components.len == 0) {
        @compileError("Requesting an 'any result query' without components is illegal");
    }

    return struct {
        pub const Item = config.ResultItem;

        // Read by dependency_chain
        pub const _result_fields = config.result_fields[config.result_start_index..];
        // Read by dependency_chain
        pub const _include_types = config.query_components[config.result_component_count..config.exclude_type_start];
        // Read by dependency_chain
        pub const _exclude_types = config.query_components[config.exclude_type_start..];

        const search_order_count = config.full_sparse_set_count - config.full_sparse_set_optional_count;

        pub const EcezType = CreateConfig.QueryAnyType;

        pub const ThisQuery = @This();

        sparse_cursors: EntityId,
        storage_entity_count_ptr: *const std.atomic.Value(EntityId),

        full_set_search_order: [search_order_count]usize,
        full_sparse_sets: [config.full_sparse_set_count]*const set.Sparse.Full,

        tag_sparse_sets_bits: EntityId,
        tag_sparse_sets: [config.tag_sparse_set_count]*const set.Sparse.Tag,

        dense_sets: CompileReflect.GroupDenseSetsConstPtr(config.query_components),

        mutex: ?std.Thread.Mutex,

        pub fn prepare(storage: anytype) ThisQuery {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // verify that storage is a ecez.Storage type
            comptime SubmitConfig.verifyStorageType(@TypeOf(storage));

            var dense_sets: CompileReflect.GroupDenseSetsConstPtr(config.query_components) = undefined;

            var full_sparse_sets: [config.full_sparse_set_count]*const set.Sparse.Full = undefined;
            var tag_sparse_sets: [config.tag_sparse_set_count]*const set.Sparse.Tag = undefined;

            {
                comptime var full_sparse_sets_index: u32 = 0;
                comptime var tag_sparse_sets_index: u32 = 0;
                inline for (config.query_components) |Component| {
                    const sparse_set_ptr = storage.getSparseSetConstPtr(Component);

                    if (@sizeOf(Component) > 0) {
                        full_sparse_sets[full_sparse_sets_index] = sparse_set_ptr;
                        full_sparse_sets_index += 1;

                        @field(dense_sets, @typeName(Component)) = storage.getDenseSetPtr(Component);
                    } else {
                        tag_sparse_sets[tag_sparse_sets_index] = sparse_set_ptr;
                        tag_sparse_sets_index += 1;
                    }
                }

                std.debug.assert(full_sparse_sets_index == config.full_sparse_set_count);
                std.debug.assert(tag_sparse_sets_index == config.tag_sparse_set_count);
            }

            const number_of_entities = storage.created_entity_count.load(.monotonic);

            // TODO: optional should always be last
            var current_index: usize = undefined;
            var current_min_value: usize = undefined;
            var last_min_value: usize = 0;
            var full_set_search_order: [search_order_count]usize = undefined;
            inline for (&full_set_search_order, 0..) |
                *search,
                search_index,
            | {
                current_min_value = std.math.maxInt(usize);

                comptime var sized_comp_index = 0;
                inline for (config.query_components, 0..) |QueryComp, q_comp_index| {
                    if (@sizeOf(QueryComp) == 0) continue;

                    defer sized_comp_index += 1;

                    var skip_component: bool = false;
                    // Skip indices we already stored
                    already_included_loop: for (full_set_search_order[0..search_index]) |prev_found| {
                        if (prev_found == sized_comp_index) {
                            skip_component = true;
                            continue :already_included_loop;
                        }
                    }

                    if (skip_component == false) {
                        const query_candidate_len = get_candidate_len_blk: {
                            if (@sizeOf(QueryComp) > 0) {
                                const dense_set = storage.getDenseSetConstPtr(QueryComp);
                                break :get_candidate_len_blk dense_set.dense_len;
                            } else {
                                const sparse_set: *const set.Sparse.Tag = storage.getSparseSetConstPtr(QueryComp);
                                break :get_candidate_len_blk sparse_set.sparse_len;
                            }
                        };

                        const len_value = get_len_blk: {
                            const is_result_or_include_component = q_comp_index < config.result_component_count + config.include_fields.len;
                            if (is_result_or_include_component) {
                                break :get_len_blk query_candidate_len;
                            } else {
                                break :get_len_blk number_of_entities - query_candidate_len;
                            }
                        };

                        const is_optional = check_result_optional_blk: {
                            const is_result = q_comp_index < config.result_component_count;
                            if (is_result) {
                                const request = CompileReflect.compactComponentRequest(_result_fields[q_comp_index].type);
                                break :check_result_optional_blk request.isOptional();
                            }
                            break :check_result_optional_blk false;
                        };
                        if (is_optional == false and len_value <= current_min_value and len_value >= last_min_value) {
                            current_index = sized_comp_index;
                            current_min_value = len_value;
                        }
                    }
                }

                search.* = current_index;
                last_min_value = current_min_value;
            }

            return ThisQuery{
                .sparse_cursors = 0,
                .storage_entity_count_ptr = &storage.created_entity_count,
                .full_set_search_order = full_set_search_order,
                .full_sparse_sets = full_sparse_sets,
                .tag_sparse_sets_bits = 0,
                .tag_sparse_sets = tag_sparse_sets,
                .dense_sets = dense_sets,
                .mutex = null,
            };
        }

        /// Get any entity's components based on Query ResultItem.
        /// This will iterate all entities matching ResultItem if called in a while loop until return is null
        /// Keep in mind, you should not use this query time if you want to iterate all results as this is a lot slower than the default Query type.
        pub fn getAny(self: *ThisQuery) ?config.ResultItem {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            if (self.mutex) |*mutex| mutex.lock();
            defer if (self.mutex) |*mutex| mutex.unlock();

            // Find next entity
            const entity_count = self.storage_entity_count_ptr.load(.monotonic);
            self.gotoFirstEntitySet(entity_count) orelse return null;
            defer self.sparse_cursors += 1;

            var result: config.ResultItem = undefined;
            // if entity is first field
            if (config.result_start_index > 0) {
                @field(result, config.result_fields[0].name) = Entity{ .id = self.sparse_cursors };
            }

            comptime var full_sparse_index = 0;
            comptime var tag_sparse_index = 0;
            inline for (config.result_fields[config.result_start_index..]) |result_field| {
                const component_to_get = CompileReflect.compactComponentRequest(result_field.type);

                if (@sizeOf(component_to_get.type) > 0) {
                    defer full_sparse_index += 1;
                    const sparse_set = self.full_sparse_sets[full_sparse_index];
                    const dense_set = @field(self.dense_sets, @typeName(component_to_get.type));

                    switch (component_to_get.attr) {
                        .value, .ptr, .const_ptr => {
                            const component_ptr = set.get(sparse_set, dense_set, self.sparse_cursors).?;
                            @field(result, result_field.name) = switch (component_to_get.attr) {
                                .ptr, .const_ptr => component_ptr,
                                .value => component_ptr.*,
                                .optional_value, .optional_ptr, .optional_const_ptr => unreachable,
                            };
                        },
                        .optional_value, .optional_ptr, .optional_const_ptr => {
                            const component_ptr = set.get(sparse_set, dense_set, self.sparse_cursors);
                            @field(result, result_field.name) = switch (component_to_get.attr) {
                                .optional_ptr, .optional_const_ptr => component_ptr,
                                .optional_value => if (component_ptr) |ptr| ptr.* else null,
                                .ptr, .const_ptr, .value => unreachable,
                            };
                        },
                    }
                } else {
                    defer tag_sparse_index += 1;

                    const sparse_set = self.tag_sparse_sets[tag_sparse_index];
                    const is_set = sparse_set.isSet(self.sparse_cursors);

                    if (is_set) {
                        @field(result, result_field.name) = switch (component_to_get.attr) {
                            .ptr, .const_ptr, .optional_const_ptr, .optional_ptr => @ptrCast(self),
                            .value, .optional_value => component_to_get.type{},
                        };
                    } else {
                        @field(result, result_field.name) = switch (component_to_get.attr) {
                            .optional_value, .optional_ptr, .optional_const_ptr => null,
                            // This should never happen, should be excluded when caching in submit!
                            .ptr, .const_ptr, .value => unreachable,
                        };
                    }
                }
            }

            return result;
        }

        pub fn skip(self: *ThisQuery, skip_count: u32) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            if (self.mutex) |*mutex| mutex.lock();
            defer if (self.mutex) |*mutex| mutex.unlock();

            const entity_count = self.storage_entity_count_ptr.load(.monotonic);
            // TODO: this is horrible for cache, we should find the next N entities instead
            // Find next entity
            for (0..skip_count) |_| {
                self.gotoFirstEntitySet(entity_count) orelse return;
                self.sparse_cursors = self.sparse_cursors + 1;
            }
        }

        pub fn reset(self: *ThisQuery) void {
            self.sparse_cursors = 0;
        }

        fn gotoFirstEntitySet(self: *ThisQuery, entity_count: EntityId) ?void {
            search_next_loop: while (true) {
                if (self.sparse_cursors >= entity_count) {
                    return null;
                }

                // Check if we should check the tag_sparse_sets_bits
                if (comptime config.tag_sparse_set_count > 0) {
                    const bit_pos: u5 = @intCast(@rem(self.sparse_cursors, @bitSizeOf(EntityId)));

                    // If we are the 32th entry, lets re-populate tag_sparse_sets_bits
                    if (bit_pos == 0) {
                        const bit_index = @divFloor(self.sparse_cursors, @bitSizeOf(EntityId));

                        self.tag_sparse_sets_bits = 0;
                        for (self.tag_sparse_sets, 0..) |tag_sparse_set, sparse_index| {
                            const bits = if (tag_sparse_set.sparse_bits.len > bit_index)
                                tag_sparse_set.sparse_bits[bit_index]
                            else
                                set.Sparse.not_set;

                            self.tag_sparse_sets_bits |= if (sparse_index < config.tag_exclude_start) bits else ~bits;
                        }
                    }

                    // 0 is considered set for sparse sets.
                    const all_tag_requirements = (self.tag_sparse_sets_bits & (@as(EntityId, 1) << bit_pos)) == 0;
                    if (all_tag_requirements == false) {
                        self.sparse_cursors += 1;
                        continue :search_next_loop;
                    }
                }

                for (self.full_set_search_order) |this_search| {
                    const entry_is_set = self.full_sparse_sets[this_search].isSet(self.sparse_cursors);
                    const should_be_set = this_search < config.tag_include_start;

                    // Check if we should skip entry:
                    // Skip if is set is false and it's a result entry, otherwise if it's an exclude, then it should be set to skip.
                    if (entry_is_set != should_be_set) {
                        self.sparse_cursors += 1;
                        continue :search_next_loop;
                    }
                }

                return; // sparse_cursor is a valid entity!
            }
        }

        /// Alternative way of calling getAny. This simply exist to provide interchangeability with a normal query
        pub fn next(self: *ThisQuery) ?config.ResultItem {
            return self.getAny();
        }

        /// Alternative way of calling prepare. This simply exist to provide interchangeability with a normal query
        pub fn submit(allocator: Allocator, storage: anytype) error{OutOfMemory}!ThisQuery {
            _ = allocator;
            return ThisQuery.prepare(storage);
        }

        /// This simply exist to provide interchangeability with a normal query
        pub fn deinit(self: ThisQuery, allocator: Allocator) void {
            _ = self;
            _ = allocator;
        }

        pub fn split(self: *ThisQuery) void {
            self.mutex = std.Thread.Mutex{};
        }
    };
}
