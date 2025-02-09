const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const set = @import("sparse_set.zig");
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

const CompileReflect = @import("storage.zig").CompileReflect;

pub const QueryType = struct {};
pub const QueryAnyType = struct {};

/// Create a new query
///
/// - Storage: The storage type to look for ResultItems im
/// - ResultItem: The desired result item struct, each field should be a component or a entity
/// - include_types: A tuple of types that the ResultItem entity must have to be included
/// - exclude_types: A tuple of types that the ResultItem entity must NOT have to be included
/// - any_result_query: If true, then query will not allocate, but will be a lot slower. Should be used for "give me any entity of these criterias"
pub fn Create(
    comptime Storage: type,
    comptime ResultItem: type,
    comptime include_types: anytype,
    comptime exclude_types: anytype,
    comptime any_result_query: bool,
) type {
    @setEvalBranchQuota(10000);

    // Start by reflecting on ResultItem type
    const result_type_info = @typeInfo(ResultItem);
    if (result_type_info != .@"struct") {
        const error_message = std.fmt.comptimePrint("Query ResultItem '{s}' must be a struct of components", .{@typeName(ResultItem)});
        @compileError(error_message);
    }

    const fields = result_type_info.@"struct".fields;
    if (fields.len < 1) {
        const error_message = std.fmt.comptimePrint("Query ResultItem '{s}' must have atleast one field", .{@typeName(ResultItem)});
        @compileError(error_message);
    }

    const result_fields, const result_start_index, const result_end = check_for_entity_blk: {
        var _result_fields: [fields.len]std.builtin.Type.StructField = undefined;

        var has_entity = false;
        for (&_result_fields, fields, 0..) |*result_field, field, field_index| {
            result_field.* = field;

            if (result_field.type == Entity) {
                // Validate that there is only 1 entity field (Multiple Entity fields would not make sense)
                if (has_entity) {
                    const error_message = std.fmt.comptimePrint(
                        "Query ResultItem '{s}' has multiple entity fields, ResultItem can only have 0 or 1 Entity field",
                        .{@typeName(ResultItem)},
                    );
                    @compileError(error_message);
                }

                // Swap entity to index 0 for easier separation from component types.
                std.mem.swap(std.builtin.Type.StructField, &_result_fields[0], &_result_fields[field_index]);
                has_entity = true;
            }

            if (@sizeOf(result_field.type) == 0) {
                const error_message = std.fmt.comptimePrint(
                    "Query ResultItem '{s}'.{s} is illegal zero sized field. Use include parameter for tag types",
                    .{ @typeName(ResultItem), result_field.name },
                );
                @compileError(error_message);
            }
        }

        // Check if an Entity was requested as well
        // If it is, then we have our component queries from index 1
        if (has_entity) {
            break :check_for_entity_blk .{ _result_fields, 1, _result_fields.len };
        }
        break :check_for_entity_blk .{ _result_fields, 0, _result_fields.len };
    };
    const result_component_count = result_end - result_start_index;

    const include_type_info = @typeInfo(@TypeOf(include_types));
    if (include_type_info != .@"struct") {
        @compileError("query exclude types must be a tuple of types");
    }
    const include_fields = include_type_info.@"struct".fields;

    const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
    if (exclude_type_info != .@"struct") {
        @compileError("query exclude types must be a tuple of types");
    }
    const exclude_fields = exclude_type_info.@"struct".fields;
    const query_components = reflect_on_query_blk: {
        const type_count = result_component_count + include_fields.len + exclude_fields.len;
        var raw_component_types: [type_count]type = undefined;

        // Loop all result items
        {
            const from = 0;
            const to = from + result_component_count;
            inline for (
                raw_component_types[from..to],
                result_fields[result_start_index..],
            ) |
                *query_component,
                incl_field,
            | {
                const request = CompileReflect.compactComponentRequest(incl_field.type);
                query_component.* = request.type;
            }
        }

        // Loop all include items
        {
            const from = result_component_count;
            const to = from + include_fields.len;
            inline for (
                raw_component_types[from..to],
                0..,
            ) |
                *query_component,
                incl_index,
            | {
                const request = CompileReflect.compactComponentRequest(include_types[incl_index]);
                switch (request.attr) {
                    .ptr, .const_ptr => {
                        const error_message = std.fmt.comptimePrint(
                            "Query include_type {s} cant be a pointer",
                            .{@typeName(request.type)},
                        );
                        @compileError(error_message);
                    },
                    .value => {},
                }

                query_component.* = include_types[incl_index];
            }
        }

        // Loop all exclude items
        {
            const from = result_component_count + include_fields.len;
            const to = from + exclude_fields.len;
            inline for (
                raw_component_types[from..to],
                0..,
            ) |
                *query_component,
                excl_index,
            | {
                const request = CompileReflect.compactComponentRequest(exclude_types[excl_index]);
                switch (request.attr) {
                    .ptr, .const_ptr => {
                        const error_message = std.fmt.comptimePrint(
                            "Query include_type {s} cant be a pointer",
                            .{@typeName(request.type)},
                        );
                        @compileError(error_message);
                    },
                    .value => {},
                }

                query_component.* = exclude_types[excl_index];
            }
        }

        break :reflect_on_query_blk raw_component_types;
    };

    const exclude_type_start = result_component_count + include_fields.len;
    const full_sparse_set_count, const tag_sparse_set_count, const tag_exclude_start = count_sparse_sets_blk: {
        var full_sparse_count = 0;
        var tag_sparse_count = 0;
        var tag_exclude_start: ?comptime_int = null;
        for (query_components, 0..) |Component, comp_index| {
            if (@sizeOf(Component) > 0) {
                full_sparse_count += 1;
            } else {
                if (tag_exclude_start == null and comp_index >= exclude_type_start) {
                    tag_exclude_start = tag_sparse_count;
                }
                tag_sparse_count += 1;
            }
        }

        break :count_sparse_sets_blk .{
            full_sparse_count,
            tag_sparse_count,
            tag_exclude_start orelse tag_sparse_count,
        };
    };

    // If a "normal" cached query with fast iteration speed is requested
    if (any_result_query == false) {

        // If query is requesting no components
        if (query_components.len == 0) {
            if (result_start_index == 0) {
                @compileError("Empty result struct is invalid query result");
            }

            // Entity only query
            return struct {
                // Read by dependency_chain
                pub const _result_fields = &[0]std.builtin.Type.StructField{};
                // Read by dependency_chain
                pub const _include_types = &[0]type{};
                // Read by dependency_chain
                pub const _exclude_types = &[0]type{};

                pub const EcezType = QueryType;

                pub const ThisQuery = @This();

                sparse_cursors: EntityId,
                storage_entity_count_ptr: *const std.atomic.Value(EntityId),

                pub fn submit(allocator: Allocator, storage: *Storage) error{OutOfMemory}!ThisQuery {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    _ = allocator;

                    return ThisQuery{
                        .sparse_cursors = 0,
                        .storage_entity_count_ptr = &storage.number_of_entities,
                    };
                }

                pub fn deinit(self: *ThisQuery, allocator: Allocator) void {
                    _ = self;
                    _ = allocator;
                }

                pub fn next(self: *ThisQuery) ?ResultItem {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    const entity_count = self.storage_entity_count_ptr.load(.monotonic);
                    if (self.sparse_cursors >= entity_count) {
                        return null;
                    }
                    defer self.sparse_cursors += 1;

                    var result: ResultItem = undefined;
                    @field(result, result_fields[0].name) = Entity{ .id = self.sparse_cursors };
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

                    self.sparse_cursors = 0;
                }
            };
        }

        return struct {
            // Read by dependency_chain
            pub const _result_fields = result_fields[result_start_index..result_end];
            // Read by dependency_chain
            pub const _include_types = query_components[result_component_count..exclude_type_start];
            // Read by dependency_chain
            pub const _exclude_types = query_components[exclude_type_start..];

            pub const EcezType = QueryType;

            pub const ThisQuery = @This();

            sparse_cursors: EntityId,

            full_sparse_sets: [full_sparse_set_count]*const set.Sparse.Full,
            dense_sets: CompileReflect.GroupDenseSetsConstPtr(&query_components),

            result_entities_bit_count: EntityId,
            result_entities_bitmap: []const EntityId,

            pub fn submit(allocator: Allocator, storage: *Storage) error{OutOfMemory}!ThisQuery {
                const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                defer zone.End();

                const biggest_set_len, const tag_sparse_sets, const full_sparse_sets, const dense_sets = retrieve_component_sets_blk: {
                    var _biggest_set_len: EntityId = 0;
                    var _tag_sparse_sets: [tag_sparse_set_count]*const set.Sparse.Tag = undefined;
                    var _full_sparse_sets: [full_sparse_set_count]*const set.Sparse.Full = undefined;
                    var _dense_sets: CompileReflect.GroupDenseSetsConstPtr(&query_components) = undefined;

                    comptime var full_sparse_sets_index: u32 = 0;
                    comptime var tag_sparse_sets_index: u32 = 0;
                    inline for (query_components) |Component| {
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

                    std.debug.assert(full_sparse_sets_index == full_sparse_set_count);
                    std.debug.assert(tag_sparse_sets_index == tag_sparse_set_count);

                    break :retrieve_component_sets_blk .{
                        _biggest_set_len,
                        _tag_sparse_sets,
                        _full_sparse_sets,
                        _dense_sets,
                    };
                };

                // Atomically load the current number of entities
                const number_of_entities = storage.number_of_entities.load(.monotonic);

                // Calculate the full set's search order.
                // As an example if query ask for Component "A" and "B", There are 10 entities of A, and
                const full_set_search_order, const full_set_is_include = calc_search_order_blk: {
                    var _full_set_search_order: [full_sparse_set_count]usize = undefined;
                    var _full_set_is_include: [full_sparse_set_count]bool = undefined;
                    var last_min_value: usize = 0;
                    inline for (&_full_set_search_order, &_full_set_is_include, 0..) |*search, *is_include, search_index| {
                        var current_index: usize = undefined;
                        var global_comp_index: usize = undefined;

                        var current_min_value: usize = std.math.maxInt(usize);

                        comptime var sized_comp_index = 0;
                        inline for (query_components, 0..) |QueryComp, q_comp_index| {
                            if (@sizeOf(QueryComp) == 0) continue;

                            defer sized_comp_index += 1;

                            // Skip indices we already stored
                            const already_included: bool = already_included_search: {
                                for (_full_set_search_order[0..search_index]) |prev_found| {
                                    if (prev_found == sized_comp_index) {
                                        break :already_included_search true;
                                    }
                                }
                                break :already_included_search false;
                            };

                            if (already_included == false) {
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
                                    const is_result_or_include_component = q_comp_index < result_component_count + include_fields.len;
                                    if (is_result_or_include_component) {
                                        break :get_len_blk query_candidate_len;
                                    } else {
                                        break :get_len_blk number_of_entities - query_candidate_len;
                                    }
                                };

                                if (len_value <= current_min_value and len_value >= last_min_value) {
                                    current_index = sized_comp_index;
                                    current_min_value = len_value;
                                    global_comp_index = q_comp_index;
                                }
                            }
                        }

                        is_include.* = global_comp_index < result_component_count + include_fields.len;
                        search.* = current_index;
                        last_min_value = current_min_value;
                    }

                    break :calc_search_order_blk .{
                        _full_set_search_order,
                        _full_set_is_include,
                    };
                };

                const worst_case_bitmap_count = std.math.divCeil(EntityId, biggest_set_len, @bitSizeOf(EntityId)) catch unreachable;
                const result_entities_bitmap = try allocator.alloc(EntityId, worst_case_bitmap_count);
                errdefer allocator.free(result_entities_bitmap);

                // initialize all bits as a query hit (1)
                // each check will reduce result if a miss
                @memset(result_entities_bitmap, std.math.maxInt(EntityId));

                // handle any tag components and store result
                if (comptime tag_sparse_set_count > 0) {
                    inline for (tag_sparse_sets, 0..) |tag_sparse_set, sparse_index| {
                        const is_include_set = sparse_index < tag_exclude_start;
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

                for (full_set_search_order, full_set_is_include) |search_order, is_include_set| {
                    const sparse_set = full_sparse_sets[search_order];

                    for (sparse_set.sparse[0..sparse_set.sparse_len], 0..) |dense_index, entity| {
                        // Check if this bitmap entry has any set results, or if we can skip it
                        if (@rem(entity, @bitSizeOf(EntityId)) == 0) {
                            const bit_index = @divFloor(entity, @bitSizeOf(EntityId));
                            if (result_entities_bitmap[bit_index] == 0) {
                                continue;
                            }
                        }

                        // Check if we have query hit for entity:
                        const entry_is_set = dense_index != set.Sparse.not_set;
                        const query_hit = entry_is_set == is_include_set;

                        if (query_hit == false) {
                            const bit_index = @divFloor(entity, @bitSizeOf(EntityId));

                            // u5 assuming EntityId = u32
                            comptime std.debug.assert(EntityId == u32);
                            const nth_bit: u5 = @intCast(@rem(entity, @bitSizeOf(EntityId)));
                            result_entities_bitmap[bit_index] &= ~(@as(EntityId, 1) << nth_bit);
                        }
                    }

                    // TODO: unlikely branch
                    // if out of set bound, consider remaining entities as missing component
                    if (is_include_set) {
                        if (sparse_set.sparse_len != 0) {
                            const last_index = sparse_set.sparse_len - 1;
                            const bit_index = @divFloor(last_index, @bitSizeOf(EntityId));
                            if (@rem(last_index, @bitSizeOf(EntityId)) != 31) {
                                // populate partial bitmap
                                comptime std.debug.assert(EntityId == u32);
                                const partial_bitmap_offset: u5 = @intCast(@rem(sparse_set.sparse_len, @bitSizeOf(EntityId)));
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
                    .full_sparse_sets = full_sparse_sets,
                    .dense_sets = dense_sets,
                    .result_entities_bit_count = biggest_set_len,
                    .result_entities_bitmap = result_entities_bitmap,
                };
            }

            pub fn deinit(self: *ThisQuery, allocator: Allocator) void {
                allocator.free(self.result_entities_bitmap);
            }

            pub fn next(self: *ThisQuery) ?ResultItem {
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
                if (self.sparse_cursors >= self.result_entities_bit_count) {
                    return null;
                }
                defer self.sparse_cursors += 1;

                var result: ResultItem = undefined;
                // if entity is first field
                if (result_start_index > 0) {
                    @field(result, result_fields[0].name) = Entity{ .id = self.sparse_cursors };
                }

                inline for (result_fields[result_start_index..result_end], 0..) |result_field, result_field_index| {
                    const component_to_get = CompileReflect.compactComponentRequest(result_field.type);

                    const sparse_set = self.full_sparse_sets[result_field_index];
                    const dense_set = @field(self.dense_sets, @typeName(component_to_get.type));
                    const component_ptr = set.get(sparse_set, dense_set, self.sparse_cursors).?;

                    switch (component_to_get.attr) {
                        .ptr, .const_ptr => @field(result, result_field.name) = component_ptr,
                        .value => @field(result, result_field.name) = component_ptr.*,
                    }
                }

                return result;
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
                self.sparse_cursors = 0;
            }
        };
        //
    } else { // any_result_query == true
        if (query_components.len == 0) {
            @compileError("Requesting an 'any result query' without components is illegal");
        }

        return struct {
            pub const Item = ResultItem;

            // Read by dependency_chain
            pub const _result_fields = result_fields[result_start_index..result_end];
            // Read by dependency_chain
            pub const _include_types = query_components[result_component_count..exclude_type_start];
            // Read by dependency_chain
            pub const _exclude_types = query_components[exclude_type_start..];

            pub const EcezType = QueryAnyType;

            pub const ThisQuery = @This();

            sparse_cursors: EntityId,
            storage_entity_count_ptr: *const std.atomic.Value(EntityId),

            full_set_search_order: [full_sparse_set_count]usize,
            full_sparse_sets: [full_sparse_set_count]*const set.Sparse.Full,

            tag_sparse_sets_bits: EntityId,
            tag_sparse_sets: [tag_sparse_set_count]*const set.Sparse.Tag,

            dense_sets: CompileReflect.GroupDenseSetsConstPtr(&query_components),

            pub fn prepare(storage: *Storage) ThisQuery {
                const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                defer zone.End();

                var dense_sets: CompileReflect.GroupDenseSetsConstPtr(&query_components) = undefined;

                var full_sparse_sets: [full_sparse_set_count]*const set.Sparse.Full = undefined;
                var tag_sparse_sets: [tag_sparse_set_count]*const set.Sparse.Tag = undefined;

                {
                    comptime var full_sparse_sets_index: u32 = 0;
                    comptime var tag_sparse_sets_index: u32 = 0;
                    inline for (query_components) |Component| {
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

                    std.debug.assert(full_sparse_sets_index == full_sparse_set_count);
                    std.debug.assert(tag_sparse_sets_index == tag_sparse_set_count);
                }

                const number_of_entities = storage.number_of_entities.load(.monotonic);

                var current_index: usize = undefined;
                var current_min_value: usize = undefined;
                var last_min_value: usize = 0;
                var full_set_search_order: [full_sparse_set_count]usize = undefined;
                inline for (&full_set_search_order, 0..) |*search, search_index| {
                    current_min_value = std.math.maxInt(usize);

                    comptime var sized_comp_index = 0;
                    inline for (query_components, 0..) |QueryComp, q_comp_index| {
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
                                const is_result_or_include_component = q_comp_index < result_component_count + include_fields.len;
                                if (is_result_or_include_component) {
                                    break :get_len_blk query_candidate_len;
                                } else {
                                    break :get_len_blk number_of_entities - query_candidate_len;
                                }
                            };

                            if (len_value <= current_min_value and len_value >= last_min_value) {
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
                    .storage_entity_count_ptr = &storage.number_of_entities,
                    .full_set_search_order = full_set_search_order,
                    .full_sparse_sets = full_sparse_sets,
                    .tag_sparse_sets_bits = 0,
                    .tag_sparse_sets = tag_sparse_sets,
                    .dense_sets = dense_sets,
                };
            }

            /// Get any entity's components based on Query ResultItem.
            /// This will iterate all entities matching ResultItem if called in a while loop until return is null
            /// Keep in mind, you should not use this query time if you want to iterate all results as this is a lot slower than the default Query type.
            pub fn getAny(self: *ThisQuery) ?ResultItem {
                const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                defer zone.End();

                // Find next entity
                const entity_count = self.storage_entity_count_ptr.load(.monotonic);
                self.gotoFirstEntitySet(entity_count) orelse return null;
                defer self.sparse_cursors += 1;

                var result: ResultItem = undefined;
                // if entity is first field
                if (result_start_index > 0) {
                    @field(result, result_fields[0].name) = Entity{ .id = self.sparse_cursors };
                }

                inline for (result_fields[result_start_index..result_end], 0..) |result_field, result_field_index| {
                    const component_to_get = CompileReflect.compactComponentRequest(result_field.type);

                    const sparse_set = self.full_sparse_sets[result_field_index];
                    const dense_set = @field(self.dense_sets, @typeName(component_to_get.type));
                    const component_ptr = set.get(sparse_set, dense_set, self.sparse_cursors).?;

                    switch (component_to_get.attr) {
                        .ptr, .const_ptr => @field(result, result_field.name) = component_ptr,
                        .value => @field(result, result_field.name) = component_ptr.*,
                    }
                }

                return result;
            }

            pub fn skip(self: *ThisQuery, skip_count: u32) void {
                const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                defer zone.End();

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
                    if (comptime tag_sparse_set_count > 0) {
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

                                self.tag_sparse_sets_bits |= if (sparse_index < tag_exclude_start) bits else ~bits;
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
                        const should_be_set = this_search < result_component_count + include_fields.len;

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
            pub fn next(self: *ThisQuery) ?ResultItem {
                return self.getAny();
            }

            /// Alternative way of calling prepare. This simply exist to provide interchangeability with a normal query
            pub fn submit(allocator: Allocator, storage: *Storage) error{OutOfMemory}!ThisQuery {
                _ = allocator;
                return ThisQuery.prepare(storage);
            }

            /// This simply exist to provide interchangeability with a normal query
            pub fn deinit(self: ThisQuery, allocator: Allocator) void {
                _ = self;
                _ = allocator;
            }
        };
    }
}
