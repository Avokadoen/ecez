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
        const no_optionals_tag_sparse_sets_len = config.tag_sparse_set_count - config.tag_sparse_set_optional_count;

        pub const EcezType = CreateConfig.QueryAnyType;

        pub const ThisQuery = @This();

        sparse_cursors: EntityId,
        storage_entity_count_ptr: *const std.atomic.Value(EntityId),

        full_set_search_order: [search_order_count]usize,
        full_set_is_include: [search_order_count]bool,
        full_sparse_sets: [config.full_sparse_set_count]*const set.Sparse.Full,

        tag_sparse_sets_bits: EntityId,
        tag_sparse_sets: [config.tag_sparse_set_count]*const set.Sparse.Tag,

        no_optionals_tag_sparse_sets: [no_optionals_tag_sparse_sets_len]*const set.Sparse.Tag,

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
            var no_optionals_tag_sparse_sets: [no_optionals_tag_sparse_sets_len]*const set.Sparse.Tag = undefined;

            {
                comptime var full_sparse_sets_index: u32 = 0;
                comptime var tag_sparse_sets_index: u32 = 0;
                comptime var no_optionals_tag_sparse_sets_index: u32 = 0;
                inline for (config.query_components) |Component| {
                    const sparse_set_ptr = storage.getSparseSetConstPtr(Component);

                    if (@sizeOf(Component) > 0) {
                        full_sparse_sets[full_sparse_sets_index] = sparse_set_ptr;
                        full_sparse_sets_index += 1;

                        @field(dense_sets, @typeName(Component)) = storage.getDenseSetPtr(Component);
                    } else {
                        tag_sparse_sets[tag_sparse_sets_index] = sparse_set_ptr;
                        tag_sparse_sets_index += 1;

                        if (comptime common.isQueryTypeOptionalTag(_result_fields, Component) == false) {
                            no_optionals_tag_sparse_sets[no_optionals_tag_sparse_sets_index] = sparse_set_ptr;
                            no_optionals_tag_sparse_sets_index += 1;
                        }
                    }
                }

                std.debug.assert(full_sparse_sets_index == config.full_sparse_set_count);
                std.debug.assert(tag_sparse_sets_index == config.tag_sparse_set_count);
            }

            const number_of_entities = storage.created_entity_count.load(.monotonic);
            const full_set_search_order, const full_set_is_include = common.calculateSearchOrder(config, _result_fields, storage, number_of_entities);

            return ThisQuery{
                .sparse_cursors = 0,
                .storage_entity_count_ptr = &storage.created_entity_count,
                .full_set_search_order = full_set_search_order,
                .full_sparse_sets = full_sparse_sets,
                .full_set_is_include = full_set_is_include,
                .tag_sparse_sets_bits = 0,
                .tag_sparse_sets = tag_sparse_sets,
                .no_optionals_tag_sparse_sets = no_optionals_tag_sparse_sets,
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

            return common.populateResult(self, config);
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
                        for (self.no_optionals_tag_sparse_sets, 0..) |tag_sparse_set, sparse_index| {
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

                for (self.full_set_search_order, self.full_set_is_include) |this_search, is_include_set| {
                    const entry_is_set = self.full_sparse_sets[this_search].isSet(self.sparse_cursors);
                    const should_be_set = entry_is_set == is_include_set;

                    // Check if we should skip entry:
                    // Skip if is set is false and it's a result entry, otherwise if it's an exclude, then it should be set to skip.
                    if (should_be_set == false) {
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
