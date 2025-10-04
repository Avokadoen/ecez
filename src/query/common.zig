const std = @import("std");

const entity_type = @import("../entity_type.zig");
const Entity = entity_type.Entity;
const set = @import("../sparse_set.zig");
const CompileReflect = @import("../storage.zig").CompileReflect;
const CreateConfig = @import("CreateConfig.zig");

pub fn populateResult(self: anytype, comptime config: CreateConfig) config.ResultItem {
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

            const maybe_component_ptr = set.get(sparse_set, dense_set, self.sparse_cursors);
            if (component_to_get.isOptional()) {
                @field(result, result_field.name) = switch (component_to_get.attr) {
                    .optional_ptr, .optional_const_ptr => maybe_component_ptr,
                    .optional_value => if (maybe_component_ptr) |ptr| ptr.* else null,
                    .ptr, .const_ptr, .value => unreachable,
                };
            } else {
                @field(result, result_field.name) = switch (component_to_get.attr) {
                    .ptr, .const_ptr => maybe_component_ptr.?,
                    .value => maybe_component_ptr.?.*,
                    .optional_value, .optional_ptr, .optional_const_ptr => unreachable,
                };
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

/// Calculate the full set's search order.
/// As an example if query ask to include Component "A" and "B" and exclude "C":
///  - There are 1 entities of "A"
///  - There are 5 entitites of "B"
/// "A" has one member so it might be faster to check "A" first. This way we only have to check one "B" entry.
pub fn calculateSearchOrder(
    comptime config: CreateConfig,
    comptime result_fields: []const std.builtin.Type.StructField,
    storage: anytype,
    number_of_entities: entity_type.EntityId,
) rtr_type_blk: {
    const search_order_count = config.full_sparse_set_count - config.full_sparse_set_optional_count;
    const SearchOrderArray = [search_order_count]usize;
    const IsIncludeArray = [search_order_count]bool;
    break :rtr_type_blk std.meta.Tuple(&[_]type{
        SearchOrderArray,
        IsIncludeArray,
    });
} {
    const search_order_count = config.full_sparse_set_count - config.full_sparse_set_optional_count;
    var full_set_search_order: [search_order_count]usize = undefined;
    var full_set_is_include: [search_order_count]bool = undefined;
    var last_min_value: usize = 0;
    inline for (&full_set_search_order, &full_set_is_include, 0..) |
        *search,
        *is_include,
        search_index,
    | {
        var current_index: usize = undefined;
        var global_comp_index: usize = undefined;
        var current_min_value: usize = std.math.maxInt(usize);

        comptime var sized_comp_index = 0;
        inline for (config.query_components, 0..) |QueryComp, q_comp_index| {
            if (@sizeOf(QueryComp) == 0) continue;

            defer sized_comp_index += 1;

            const is_result_optional: bool = comptime check_optional_blk: {
                const is_result = q_comp_index < config.result_component_count;
                if (is_result) {
                    const request = CompileReflect.compactComponentRequest(result_fields[q_comp_index].type);
                    break :check_optional_blk request.isOptional();
                }

                break :check_optional_blk false;
            };

            if (comptime (is_result_optional == false)) {
                // Skip indices we already stored
                const already_included: bool = already_included_search: {
                    for (full_set_search_order[0..search_index]) |prev_found| {
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
                        const is_result_or_include_component = q_comp_index < config.result_component_count + config.include_fields.len;
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
        }

        is_include.* = global_comp_index < config.result_component_count + config.include_fields.len;
        search.* = current_index;
        last_min_value = current_min_value;
    }

    return .{ full_set_search_order, full_set_is_include };
}

/// Assuming only result fields can hold optional tags (zero sized components)
pub fn isQueryTypeOptionalTag(
    comptime result_fields: []const std.builtin.Type.StructField,
    comptime QueryType: type,
) bool {
    inline for (result_fields) |field| {
        const request = CompileReflect.compactComponentRequest(field.type);
        if (@sizeOf(request.type) != 0 or request.type != QueryType) {
            continue;
        }

        return request.isOptional();
    }

    return false;
}

test calculateSearchOrder {}
