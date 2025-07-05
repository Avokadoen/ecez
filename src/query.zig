const std = @import("std");
const Allocator = std.mem.Allocator;

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

const Testing = @import("Testing.zig");
const testing = std.testing;

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;

const StorageStub = Testing.StorageStub;
const Queries = Testing.Queries;

test "query with single result component type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    inline for (Queries.ReadA) |QueryReadA| {
        var index: usize = 0;
        var a_iter = try QueryReadA.submit(std.testing.allocator, &storage);
        defer a_iter.deinit(std.testing.allocator);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query skip works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    inline for (Queries.ReadA) |ReadA| {
        var a_iter = try ReadA.submit(std.testing.allocator, &storage);
        defer a_iter.deinit(std.testing.allocator);

        var index: usize = 50;
        a_iter.skip(50);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query reset works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    inline for (Queries.ReadA) |ReadA| {
        var a_iter = try ReadA.submit(std.testing.allocator, &storage);
        defer a_iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }

        a_iter.reset();
        index = 0;
        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with multiple result component types works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    inline for (Queries.ReadAReadB) |ReadAReadB| {
        var a_b_iter = try ReadAReadB.submit(std.testing.allocator, &storage);
        defer a_b_iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (a_b_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            try std.testing.expectEqual(Testing.Component.B{
                .value = @as(u8, @intCast(index)),
            }, item.b);

            index += 1;
        }
    }
}

test "query with single result component ptr type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    inline for (Queries.WriteA, Queries.ReadA) |WriteA, ReadA| {
        storage.clearRetainingCapacity();

        for (0..100) |index| {
            _ = try storage.createEntity(AbEntityType{
                .a = .{ .value = @as(u32, @intCast(index)) },
                .b = .{ .value = @as(u8, @intCast(index)) },
            });
        }

        {
            var index: usize = 0;
            var a_iter = try WriteA.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                item.a.value += 1;
                index += 1;
            }
        }

        {
            var index: usize = 1;
            var a_iter = try ReadA.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a);

                index += 1;
            }
        }
    }
}

test "query with single const ptr result component ptr type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    inline for (Queries.WriteA, Queries.ReadAConstPtr) |WriteA, ReadAConstPtr| {
        storage.clearRetainingCapacity();

        for (0..100) |index| {
            _ = try storage.createEntity(AbEntityType{
                .a = .{ .value = @as(u32, @intCast(index)) },
                .b = .{ .value = @as(u8, @intCast(index)) },
            });
        }

        {
            var index: usize = 0;
            var a_iter = try WriteA.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                item.a.value += 1;
                index += 1;
            }
        }

        {
            var index: usize = 1;
            var a_iter = try ReadAConstPtr.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a.*);

                index += 1;
            }
        }
    }
}

test "query with interleaved AB A results works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var rem_5_index: usize = 0;
    var else_index: usize = 0;
    {
        for (0..300) |index| {
            if (@rem(index, 5) == 0) {
                _ = try storage.createEntity(AbEntityType{
                    .a = .{ .value = @as(u32, @intCast(rem_5_index)) },
                    .b = .{ .value = @as(u8, @intCast(rem_5_index)) },
                });

                rem_5_index += 1;
            } else {
                _ = try storage.createEntity(.{
                    Testing.Component.A{ .value = @as(u32, @intCast(else_index)) },
                });

                else_index += 1;
            }
        }
    }

    inline for (Queries.ReadAReadB, Queries.ReadAExclB) |ReadAReadB, ReadANotB| {
        {
            var index: usize = 0;
            var a_b_iter = try ReadAReadB.submit(std.testing.allocator, &storage);
            defer a_b_iter.deinit(std.testing.allocator);

            while (a_b_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a);
                try std.testing.expectEqual(Testing.Component.B{
                    .value = @as(u8, @intCast(index)),
                }, item.b);

                index += 1;
            }

            try std.testing.expectEqual(rem_5_index, index);
        }

        {
            var index: usize = 0;
            var a_iter = try ReadANotB.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a);

                index += 1;
            }

            try std.testing.expectEqual(else_index, index);
        }
    }
}

test "query with interleaved ABC AB results works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var rem_5_index: usize = 0;
    var else_index: usize = 0;
    {
        for (0..300) |index| {
            if (@rem(index, 5) == 0) {
                _ = try storage.createEntity(AbcEntityType{
                    .a = .{ .value = @as(u32, @intCast(rem_5_index)) },
                    .b = .{ .value = @as(u8, @intCast(rem_5_index)) },
                });

                rem_5_index += 1;
            } else {
                _ = try storage.createEntity(AbEntityType{
                    .a = .{ .value = @as(u32, @intCast(else_index)) },
                    .b = .{ .value = @as(u8, @intCast(else_index)) },
                });

                else_index += 1;
            }
        }
    }

    inline for (Queries.ReadAReadBIncC, Queries.ReadAReadBExclC) |ReadAReadBIncC, ReadAReadBExclC| {
        {
            var index: usize = 0;
            var a_b_c_iter = try ReadAReadBIncC.submit(std.testing.allocator, &storage);
            defer a_b_c_iter.deinit(std.testing.allocator);

            while (a_b_c_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a);
                try std.testing.expectEqual(Testing.Component.B{
                    .value = @as(u8, @intCast(index)),
                }, item.b);

                index += 1;
            }

            try std.testing.expectEqual(rem_5_index, index);
        }

        {
            var index: usize = 0;
            var a_iter = try ReadAReadBExclC.submit(std.testing.allocator, &storage);
            defer a_iter.deinit(std.testing.allocator);

            while (a_iter.next()) |item| {
                try std.testing.expectEqual(Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                }, item.a);

                try std.testing.expectEqual(Testing.Component.B{
                    .value = @as(u8, @intCast(index)),
                }, item.b);

                index += 1;
            }

            try std.testing.expectEqual(else_index, index);
        }
    }
}

test "query with single result component and single exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct { a: Testing.Component.A },
        .{},
        .{Testing.Component.B},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);

        defer iter.deinit(std.testing.allocator);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with result of single component type and multiple exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (200..300) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct { a: Testing.Component.A },
        .{},
        .{ Testing.Component.B, Testing.Component.C },
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);

        defer iter.deinit(std.testing.allocator);

        var index: usize = 200;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with result of single component, one zero sized exclude and one sized exclude" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (200..300) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct { a: Testing.Component.A },
        .{},
        .{ Testing.Component.C, Testing.Component.B },
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);

        defer iter.deinit(std.testing.allocator);

        var index: usize = 200;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query no result component, single include and no exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    for (0..100) |_| {
        _ = try storage.createEntity(AbcEntityType{
            .c = .{},
        });
    }

    const BQueries = Testing.QueryAndQueryAny(
        struct {},
        .{Testing.Component.B},
        .{},
    );

    inline for (BQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (iter.next()) |_| {
            index += 1;
        }

        try std.testing.expectEqual(200, index);
    }

    const CQueries = Testing.QueryAndQueryAny(
        struct {},
        .{Testing.Component.C},
        .{},
    );

    inline for (CQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (iter.next()) |_| {
            index += 1;
        }

        try std.testing.expectEqual(200, index);
    }
}

test "query no result component, no include and single exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    for (0..100) |_| {
        _ = try storage.createEntity(AbcEntityType{
            .c = .{},
        });
    }

    const BQueries = Testing.QueryAndQueryAny(
        struct {},
        .{},
        .{Testing.Component.B},
    );

    inline for (BQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (iter.next()) |_| {
            index += 1;
        }

        try std.testing.expectEqual(100, index);
    }

    const CQueries = Testing.QueryAndQueryAny(
        struct {},
        .{},
        .{Testing.Component.C},
    );

    inline for (CQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (iter.next()) |_| {
            index += 1;
        }

        try std.testing.expectEqual(100, index);
    }
}

test "query with single result component, single include and single (tag component) exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct { a: Testing.Component.A },
        .{Testing.Component.B},
        .{Testing.Component.C},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with entity only works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct {
            entity: Entity,
            a: Testing.Component.A,
        },
        .{},
        .{},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);

        defer iter.deinit(std.testing.allocator);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            index += 1;
        }
    }
}

test "query with result entity, components and exclude only works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        const TQueries = Testing.QueryAndQueryAny(
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{},
            .{Testing.Component.B},
        );

        inline for (TQueries) |TQuery| {
            // Test with entity as first argument
            var iter = try TQuery.submit(std.testing.allocator, &storage);

            defer iter.deinit(std.testing.allocator);

            var index: usize = 0;
            while (iter.next()) |item| {
                try std.testing.expectEqual(
                    entities[index],
                    item.entity,
                );

                try std.testing.expectEqual(
                    Testing.Component.A{
                        .value = @as(u32, @intCast(index)),
                    },
                    item.a,
                );
                index += 1;
            }
        }
    }

    {
        const TQueries = Testing.QueryAndQueryAny(
            struct {
                a: Testing.Component.A,
                entity: Entity,
            },
            .{},
            .{Testing.Component.B},
        );

        inline for (TQueries) |TQuery| {
            // Test with entity as second argument
            var iter = try TQuery.submit(std.testing.allocator, &storage);

            defer iter.deinit(std.testing.allocator);

            var index: usize = 0;
            while (iter.next()) |item| {
                try std.testing.expectEqual(
                    entities[index],
                    item.entity,
                );

                try std.testing.expectEqual(
                    Testing.Component.A{
                        .value = @as(u32, @intCast(index)),
                    },
                    item.a,
                );
                index += 1;
            }
        }
    }

    {
        const TQueries = Testing.QueryAndQueryAny(
            struct {
                a: Testing.Component.A,
                entity: Entity,
                b: Testing.Component.B,
            },
            .{},
            .{},
        );

        inline for (TQueries) |TQuery| {
            // Test with entity as "sandwiched" between A and B
            var iter = try TQuery.submit(std.testing.allocator, &storage);

            defer iter.deinit(std.testing.allocator);

            var index: usize = 100;
            while (iter.next()) |item| {
                try std.testing.expectEqual(
                    entities[index],
                    item.entity,
                );

                try std.testing.expectEqual(
                    Testing.Component.A{
                        .value = @as(u32, @intCast(index)),
                    },
                    item.a,
                );

                try std.testing.expectEqual(
                    Testing.Component.B{
                        .value = @as(u8, @intCast(index)),
                    },
                    item.b,
                );
                index += 1;
            }
        }
    }
}

test "query with include field works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct {
            entity: Entity,
            a: Testing.Component.A,
        },
        .{Testing.Component.B},
        .{},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);

        defer iter.deinit(std.testing.allocator);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(
                entities[index],
                item.entity,
            );

            try std.testing.expectEqual(
                Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                },
                item.a,
            );
            index += 1;
        }
    }
}

test "query entity only split works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    const EntityQuery = Query(
        struct {
            entity: Entity,
        },
        .{},
        .{},
    );

    var iter = try EntityQuery.submit(std.testing.allocator, &storage);
    var other_iters: [10]EntityQuery = undefined;
    iter.split(&other_iters);

    var index: usize = 0;
    while (iter.next()) |item| {
        try std.testing.expectEqual(
            entities[index],
            item.entity,
        );
        index += 1;
    }
    for (&other_iters) |*other_iter| {
        while (other_iter.next()) |item| {
            try std.testing.expectEqual(
                entities[index],
                item.entity,
            );
            index += 1;
        }
    }

    try std.testing.expectEqual(entities.len, index);
}

test "query entity id with tag include and exclude sized type" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
            Testing.Component.C{},
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct {
            entity: Entity,
        },
        .{Testing.Component.C},
        .{Testing.Component.A},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        while (iter.next()) |item| {
            _ = item;
            return error.MatchingInvalidEntity;
        }
    }
}

test "query split works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    const TQueries = Testing.QueryAndQueryAny(
        struct {
            entity: Entity,
            a: Testing.Component.A,
        },
        .{},
        .{},
    );

    inline for (TQueries, 0..) |TQuery, query_t_index| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        var other_iters: [10]TQuery = undefined;
        if (query_t_index == 0) {
            iter.split(&other_iters);
        } else {
            iter.split();
        }

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(
                entities[index],
                item.entity,
            );

            try std.testing.expectEqual(
                Testing.Component.A{
                    .value = @as(u32, @intCast(index)),
                },
                item.a,
            );
            index += 1;
        }

        if (query_t_index == 0) {
            for (&other_iters) |*other_iter| {
                while (other_iter.next()) |item| {
                    try std.testing.expectEqual(
                        entities[index],
                        item.entity,
                    );
                    index += 1;
                }
            }
        }

        try std.testing.expectEqual(entities.len, index);
    }
}

test "reproducer: MineSweeper index out of bound caused by incorrect mapping of query to internal storage" {
    const transform = struct {
        const Position = struct {
            a: u8 = 0.0,
        };

        const Rotation = struct {
            a: u16 = 0.0,
        };

        const Scale = struct {
            a: u32 = 0,
        };

        const WorldTransform = struct {
            a: u64 = 0,
        };
    };

    const Parent = struct {
        a: u128 = 0,
    };
    const Children = struct {
        a: u256 = 0,
    };

    const RepStorage = @import("storage.zig").CreateStorage(.{
        transform.Position,
        transform.Rotation,
        transform.Scale,
        transform.WorldTransform,
        Parent,
        Children,
    });

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    const Node = struct {
        p: transform.Position = .{},
        r: transform.Rotation = .{},
        s: transform.Scale = .{},
        w: transform.WorldTransform = .{},
        c: Children = .{},
    };
    _ = try storage.createEntity(Node{});

    const TQueries = Testing.QueryAndQueryAny(
        struct {
            position: transform.Position,
            rotation: transform.Rotation,
            scale: transform.Scale,
            world_transform: *transform.WorldTransform,
            children: Children,
        },
        .{},
        // exclude type
        .{Parent},
    );

    inline for (TQueries) |TQuery| {
        var iter = try TQuery.submit(std.testing.allocator, &storage);
        defer iter.deinit(std.testing.allocator);

        try testing.expect(iter.next() != null);
    }
}
