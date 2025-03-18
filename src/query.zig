const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const set = @import("sparse_set.zig");
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

const CompileReflect = @import("storage.zig").CompileReflect;

const CreateConfig = @import("query/CreateConfig.zig");

pub const QueryType = CreateConfig.QueryType;
pub const QueryAnyType = CreateConfig.QueryAnyType;

/// Query components which can be iterated upon.
///
/// Parameters:
///
///     - ResultItem:    All the components you would like to iterate over in a single struct.
///                      Each component in the struct will belong to the same entity.
///                      A field does not have to be a component if it is of type Entity and it's the first
///                      field.
///
///     - include_types: All the components that should be included from the query result
///
///     - exclude_types: All the components that should be excluded from the query result
///
/// Example:
/// ```
/// var living_iter = Query(struct{ entity: Entity, a: Health }, .{LivingTag} .{DeadTag}).submit(std.testing.allocator, &storage);
/// while (living_iter.next()) |item| {
///    std.debug.print("{d}", .{item.entity});
///    std.debug.print("{any}", .{item.a});
/// }
/// ```
pub fn Query(comptime ResultItem: type, comptime include_types: anytype, comptime exclude_types: anytype) type {
    const any_result_query = false;

    return @import("query.zig").Create(ResultItem, include_types, exclude_types, any_result_query);
}

/// Query for any entity with components.
///
/// This should not be used to iterate. Use normal Query instead for this use case.
/// This query type should be used when a single or few items are desired.
///
/// Parameters:
///
///     - ResultItem:    All the components you would like to iterate over in a single struct.
///                      Each component in the struct will belong to the same entity.
///                      A field does not have to be a component if it is of type Entity and it's the first
///                      field.
///
///     - include_types: All the components that should be included from the query result
///
///     - exclude_types: All the components that should be excluded from the query result
///
/// Example:
/// ```
/// var any_living = QueryAny(struct{ entity: Entity, a: Health }, .{LivingTag} .{DeadTag}).submit(std.testing.allocator, &storage);
///
/// const living = any_living.getAny();
/// std.debug.print("{d}", .{item.entity});
/// std.debug.print("{any}", .{item.a});
/// ```
pub fn QueryAny(comptime ResultItem: type, comptime include_types: anytype, comptime exclude_types: anytype) type {
    const any_result_query = true;

    return Create(ResultItem, include_types, exclude_types, any_result_query);
}

/// Create a new query
///
/// - Storage: The storage type to look for ResultItems im
/// - ResultItem: The desired result item struct, each field should be a component or a entity
/// - include_types: A tuple of types that the ResultItem entity must have to be included
/// - exclude_types: A tuple of types that the ResultItem entity must NOT have to be included
/// - any_result_query: If true, then query will not allocate, but will be a lot slower. Should be used for "give me any entity of these criterias"
fn Create(
    comptime ResultItem: type,
    comptime include_types: anytype,
    comptime exclude_types: anytype,
    comptime any_result_query: bool,
) type {
    const query_create_config = comptime CreateConfig.init(
        ResultItem,
        include_types,
        exclude_types,
        any_result_query,
    );

    return comptime switch (query_create_config.which_query) {
        .cached => @import("query/cached.zig").Create(query_create_config),
        .entity_only => @import("query/entity_only.zig").Create(query_create_config),
        .uncached => @import("query/uncached.zig").Create(query_create_config),
    };
}
