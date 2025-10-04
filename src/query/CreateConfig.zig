const std = @import("std");
const Type = std.builtin.Type;

const entity_type = @import("../entity_type.zig");
const Entity = entity_type.Entity;
const CompileReflect = @import("../storage.zig").CompileReflect;

pub const QueryType = struct {};
pub const QueryAnyType = struct {};

pub const WhichQuery = enum {
    entity_only,
    cached,
    uncached,
};

const CreateConfig = @This();

which_query: WhichQuery,
ResultItem: type,

query_components: []const type,

result_fields: []const Type.StructField,
result_start_index: comptime_int,
result_component_count: comptime_int,

include_fields: []const Type.StructField,
exclude_type_start: comptime_int,

full_sparse_set_count: comptime_int,
full_sparse_set_optional_count: comptime_int,

tag_sparse_set_count: comptime_int,
tag_sparse_set_optional_count: comptime_int,
tag_include_start: comptime_int,
tag_exclude_start: comptime_int,

pub fn init(
    comptime ResultItem: type,
    comptime include_types: anytype,
    comptime exclude_types: anytype,
    comptime any_result_query: bool,
) CreateConfig {
    @setEvalBranchQuota(10000);

    // Start by reflecting on ResultItem type
    const result_type_info = @typeInfo(ResultItem);
    if (result_type_info != .@"struct") {
        const error_message = std.fmt.comptimePrint("Query ResultItem '{s}' must be a struct of components", .{@typeName(ResultItem)});
        @compileError(error_message);
    }

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

    const fields = result_type_info.@"struct".fields;
    if (fields.len == 0 and include_fields.len == 0 and exclude_fields.len == 0) {
        const error_message = std.fmt.comptimePrint("Query ResultItem '{s}' must have atleast one field, include or exclude component", .{@typeName(ResultItem)});
        @compileError(error_message);
    }

    var tag_sparse_set_optional_count: usize = 0;
    var full_sparse_set_optional_count: usize = 0;

    var has_entity = false;
    const result_fields = reflect_result_fields_blk: {
        var _result_fields: [fields.len]std.builtin.Type.StructField = undefined;
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
            } else {
                const request = CompileReflect.compactComponentRequest(result_field.type);
                if (@sizeOf(request.type) == 0) {
                    tag_sparse_set_optional_count += if (request.isOptional()) 1 else 0;
                } else {
                    full_sparse_set_optional_count += if (request.isOptional()) 1 else 0;
                }
            }
        }

        break :reflect_result_fields_blk _result_fields;
    };

    // Check if an Entity was requested as well
    // If it is, then we have our component queries from index 1
    const result_start_index = if (has_entity) 1 else 0;

    const result_component_count = result_fields.len - result_start_index;

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
                            "Query include_type {s} cant be pointer",
                            .{@typeName(request.type)},
                        );
                        @compileError(error_message);
                    },
                    .optional_value, .optional_ptr, .optional_const_ptr => {
                        const error_message = std.fmt.comptimePrint(
                            "Query include_type {s} cant be optional",
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
                            "Query exclude_type {s} cant be pointer",
                            .{@typeName(request.type)},
                        );
                        @compileError(error_message);
                    },
                    .optional_value, .optional_ptr, .optional_const_ptr => {
                        const error_message = std.fmt.comptimePrint(
                            "Query exclude_type {s} cant be optional",
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
    const full_sparse_set_count, const tag_sparse_set_count, const tag_include_start, const tag_exclude_start = count_sparse_sets_blk: {
        var full_sparse_count = 0;
        var tag_sparse_count = 0;
        var tag_include_start: ?comptime_int = null;
        var tag_exclude_start: ?comptime_int = null;
        for (query_components, 0..) |Component, comp_index| {
            if (@sizeOf(Component) > 0) {
                if (tag_include_start == null and comp_index >= exclude_type_start) {
                    tag_include_start = full_sparse_count;
                }

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
            tag_include_start orelse full_sparse_count,
            tag_exclude_start orelse tag_sparse_count,
        };
    };

    const which_query = comptime which_query_blk: {
        if (any_result_query == false) {
            if (query_components.len > 0) {
                break :which_query_blk WhichQuery.cached;
            } else {
                if (result_start_index == 0) {
                    @compileError("Empty result struct is invalid query result");
                }

                break :which_query_blk WhichQuery.entity_only;
            }
        } else {
            break :which_query_blk WhichQuery.uncached;
        }
        unreachable;
    };

    return CreateConfig{
        .which_query = which_query,
        .ResultItem = ResultItem,
        .result_fields = &result_fields,
        .include_fields = include_fields,
        .query_components = &query_components,
        .result_start_index = result_start_index,
        .result_component_count = result_component_count,
        .exclude_type_start = exclude_type_start,
        .full_sparse_set_count = full_sparse_set_count,
        .full_sparse_set_optional_count = full_sparse_set_optional_count,
        .tag_sparse_set_count = tag_sparse_set_count,
        .tag_sparse_set_optional_count = tag_sparse_set_optional_count,
        .tag_include_start = tag_include_start,
        .tag_exclude_start = tag_exclude_start,
    };
}
