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
    const query_create_config = comptime CreateConfig.init(
        Storage,
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
