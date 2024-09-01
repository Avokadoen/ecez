const std = @import("std");
const Allocator = std.mem.Allocator;

const set = @import("sparse_set.zig");

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

pub fn CreateStorage(comptime all_components: anytype) type {
    return struct {
        // a flat array of the type of each field in the components tuple
        pub const component_type_array = verify_and_extract_field_types_blk: {
            const components_info = @typeInfo(@TypeOf(all_components));
            if (components_info != .Struct) {
                @compileError("components was not a tuple of types");
            }

            var field_types: [components_info.Struct.fields.len]type = undefined;
            for (&field_types, components_info.Struct.fields, 0..) |*field_type, field, component_index| {
                if (@typeInfo(field.type) != .Type) {
                    @compileError("components must be a struct of types, field '" ++ field.name ++ "' was " ++ @typeName(field.type));
                }

                if (@typeInfo(all_components[component_index]) != .Struct) {
                    @compileError("component types must be a struct, field '" ++ field.name ++ "' was '" ++ @typeName(all_components[component_index]));
                }
                field_type.* = all_components[component_index];
            }
            break :verify_and_extract_field_types_blk field_types;
        };

        pub const GroupSparseSets = CompileReflect.GroupSparseSets(&component_type_array);

        const Storage = @This();

        allocator: Allocator,
        sparse_sets: GroupSparseSets = .{},
        prev_entity_incr: EntityId = 0,

        /// intialize the storage structure
        /// Parameters:
        ///     - allocator: allocator used when initiating entities
        pub fn init(allocator: Allocator) error{OutOfMemory}!Storage {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            return Storage{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            inline for (component_type_array) |Component| {
                var sparse_set: *set.SparseSet(EntityId, Component) = &@field(
                    self.sparse_sets,
                    @typeName(Component),
                );
                sparse_set.deinit(self.allocator);
            }
        }

        /// Clear storage memory for reuse. **All entities will become invalid**.
        pub fn clearRetainingCapacity(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            inline for (component_type_array) |Component| {
                var sparse_set: *set.SparseSet(EntityId, Component) = &@field(
                    self.sparse_sets,
                    @typeName(Component),
                );
                sparse_set.clearRetainingCapacity();
            }

            self.prev_entity_incr = 0;
        }

        /// Create an entity and returns the entity handle
        /// Parameters:
        ///     - entity_state: the components that the new entity should be assigned
        pub fn createEntity(self: *Storage, entity_state: anytype) error{OutOfMemory}!Entity {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            const field_info = @typeInfo(@TypeOf(entity_state));

            errdefer {
                self.prev_entity_incr -= 1;
                inline for (field_info.Struct.fields) |field| {
                    var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                        self.sparse_sets,
                        @typeName(field.type),
                    );
                    _ = sparse_set.unset(self.prev_entity_incr);
                }
            }

            const this_id = self.prev_entity_incr;
            const next_id = self.prev_entity_incr + 1;
            defer self.prev_entity_incr = next_id;

            inline for (all_components) |Component| {
                const sparse_set: *set.SparseSet(EntityId, Component) = &@field(
                    self.sparse_sets,
                    @typeName(Component),
                );
                try sparse_set.growSparse(self.allocator, next_id);
            }

            inline for (field_info.Struct.fields) |field| {
                var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                    self.sparse_sets,
                    @typeName(field.type),
                );
                const component = @field(
                    entity_state,
                    field.name,
                );
                try sparse_set.set(
                    self.allocator,
                    this_id,
                    component,
                );
            }

            return Entity{
                .id = this_id,
            };
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:               the entity that should be assigned the component value
        ///     - struct_of_components: the new component values
        pub fn setComponents(self: *Storage, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            const field_info = @typeInfo(@TypeOf(struct_of_components));

            // TODO: proper errdefer
            // errdefer

            inline for (field_info.Struct.fields) |field| {
                var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                    self.sparse_sets,
                    @typeName(field.type),
                );

                const component = @field(
                    struct_of_components,
                    field.name,
                );
                try sparse_set.set(
                    self.allocator,
                    entity.id,
                    component,
                );
            }
        }

        /// Remove components owned by entity
        /// Parameters:
        ///     - entity:    the entity being mutated
        ///     - components: the components to remove in a tuple/struct
        pub fn removeComponents(self: *Storage, entity: Entity, comptime struct_of_remove_components: anytype) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            const field_info = @typeInfo(@TypeOf(struct_of_remove_components));

            // TODO: proper errdefer
            // errdefer

            inline for (field_info.Struct.fields) |field| {
                const ComponentToRemove = @field(struct_of_remove_components, field.name);

                var sparse_set: *set.SparseSet(EntityId, ComponentToRemove) = &@field(
                    self.sparse_sets,
                    @typeName(ComponentToRemove),
                );
                _ = sparse_set.unset(entity.id);
            }
        }

        /// Check if an entity has a set components
        /// Parameters:
        ///     - entity:    the entity to check for type Components
        ///     - components: a tuple of component types to check after
        pub fn hasComponents(self: Storage, entity: Entity, comptime components: anytype) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            const field_info = @typeInfo(@TypeOf(components));

            // TODO: proper errdefer
            // errdefer
            inline for (field_info.Struct.fields) |field| {
                const ComponentToCheck = @field(components, field.name);

                const sparse_set: set.SparseSet(EntityId, ComponentToCheck) = @field(
                    self.sparse_sets,
                    @typeName(ComponentToCheck),
                );

                if (sparse_set.isSet(entity.id) == false) {
                    return false;
                }
            }

            return true;
        }

        /// Fetch an entity's component data
        /// Parameters:
        ///     - entity:    the entity to retrieve Component from
        ///     - Components: a struct type where fields are compoents that that belong to entity
        pub fn getComponents(self: *const Storage, entity: Entity, comptime Components: type) error{MissingComponent}!Components {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            var result: Components = undefined;
            const field_info = @typeInfo(Components);
            inline for (field_info.Struct.fields) |field| {
                const component_to_get = CompileReflect.compactComponentRequest(field.type);

                const sparse_set: set.SparseSet(EntityId, component_to_get.type) = @field(
                    self.sparse_sets,
                    @typeName(component_to_get.type),
                );

                const get_ptr = sparse_set.get(entity.id) orelse return error.MissingComponent;
                switch (component_to_get.attr) {
                    .ptr => @field(result, field.name) = get_ptr,
                    .value => @field(result, field.name) = get_ptr.*,
                }
            }

            return result;
        }

        /// Query components which can be iterated upon.
        /// Parameters:
        ///     - ResultItem:    All the components you would like to iterate over in a single struct.
        ///                      Each component in the struct will belong to the same entity.
        ///                      A field does not have to be a component if it is of type Entity and it's the first
        ///                      field.
        ///     - exclude_types: All the components that should be excluded from the query result
        ///
        /// Example:
        /// ```
        /// var a_iter = Storage.Query(struct{ entity: Entity, a: A }, .{B}).submit(&storage);
        /// defer a_iter.deinit();
        ///
        /// while (a_iter.next()) |item| {
        ///    std.debug.print("{d}", .{item.entity});
        ///    std.debug.print("{any}", .{item.a});
        /// }
        /// ```
        pub fn Query(comptime ResultItem: type, comptime exclude_types: anytype) type {
            @setEvalBranchQuota(10000);

            const include_type_info = @typeInfo(ResultItem);
            if (include_type_info != .Struct) {
                @compileError("query result_item must be a struct of components");
            }
            const include_fields = include_type_info.Struct.fields;
            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }
            const exclude_fields = exclude_type_info.Struct.fields;

            const include_start_index, const include_end_index = check_for_entity_blk: {
                if (include_fields[0].type == Entity) {
                    break :check_for_entity_blk .{ 1, include_fields.len };
                }
                break :check_for_entity_blk .{ 0, include_fields.len };
            };
            const component_include_count = include_end_index - include_start_index;

            const incl_component_indices, const excl_component_indices, const query_components = reflect_on_query_blk: {
                var raw_component_types: [component_include_count + exclude_fields.len]type = undefined;
                var incl_indices: [component_include_count]usize = undefined;
                inline for (
                    &incl_indices,
                    raw_component_types[0..component_include_count],
                    include_fields[include_start_index..],
                    0..,
                ) |
                    *component_index,
                    *query_component,
                    incl_field,
                    incl_index,
                | {
                    const request = CompileReflect.compactComponentRequest(incl_field.type);
                    component_index.* = incl_index;
                    query_component.* = request.type;
                }

                var excl_indices: [exclude_fields.len]usize = undefined;
                inline for (
                    &excl_indices,
                    raw_component_types[component_include_count .. component_include_count + exclude_fields.len],
                    0..,
                    include_start_index..,
                ) |
                    *component_index,
                    *query_component,
                    excl_index,
                    comp_index,
                | {
                    const request = CompileReflect.compactComponentRequest(exclude_types[excl_index]);
                    component_index.* = comp_index;
                    query_component.* = request.type;
                }

                break :reflect_on_query_blk .{ incl_indices, excl_indices, raw_component_types };
            };

            return struct {
                pub const _include_fields = include_fields;
                pub const secret_field = QueryType;

                pub const ThisQuery = @This();

                // TODO: this is horrible for cache, we should find the next N entities instead
                sparse_cursors: EntityId,
                storage_entity_count_ptr: *const EntityId,

                search_order: [component_include_count + exclude_fields.len]usize,
                sparse_sets: CompileReflect.GroupSparseSetsPtr(&query_components),

                pub fn submit(storage: *Storage) ThisQuery {
                    var current_index: usize = undefined;
                    var current_min_value: usize = undefined;
                    var last_min_value: usize = 0;
                    var search_order: [component_include_count + exclude_fields.len]usize = undefined;
                    inline for (&search_order, 0..) |*search, search_index| {
                        current_min_value = std.math.maxInt(usize);

                        inline for (incl_component_indices) |component_index| {
                            var skip: bool = false;
                            // Skip indices we already stored
                            already_included_loop: for (search_order[0..search_index]) |prev_found| {
                                if (prev_found == component_index) {
                                    skip = true;
                                    continue :already_included_loop;
                                }
                            }

                            if (skip == false) {
                                const Component = all_components[component_index];
                                const sparse_set: set.SparseSet(EntityId, Component) = @field(
                                    storage.sparse_sets,
                                    @typeName(Component),
                                );

                                if (sparse_set.len <= current_min_value and sparse_set.len >= last_min_value) {
                                    current_index = component_index;
                                }
                            }
                        }

                        inline for (excl_component_indices) |component_index| {
                            var skip: bool = false;
                            // Skip indices we already stored
                            already_included_loop: for (search_order[0..search_index]) |prev_found| {
                                if (prev_found == component_index) {
                                    skip = true;
                                    continue :already_included_loop;
                                }
                            }

                            if (skip == false) {
                                const Component = all_components[component_index];
                                const sparse_set: set.SparseSet(EntityId, Component) = @field(
                                    storage.sparse_sets,
                                    @typeName(Component),
                                );

                                const inverse_value = storage.prev_entity_incr - sparse_set.len;
                                if (inverse_value <= current_min_value and inverse_value >= last_min_value) {
                                    current_index = component_index;
                                }
                            }
                        }

                        search.* = current_index;
                        last_min_value = current_min_value;
                    }

                    var sparse_sets: CompileReflect.GroupSparseSetsPtr(&query_components) = undefined;
                    inline for (query_components) |Component| {
                        @field(sparse_sets, @typeName(Component)) = &@field(storage.sparse_sets, @typeName(Component));
                    }

                    return ThisQuery{
                        .sparse_cursors = 0,
                        .storage_entity_count_ptr = &storage.prev_entity_incr,
                        .search_order = search_order,
                        .sparse_sets = sparse_sets,
                    };
                }

                pub fn next(self: *ThisQuery) ?ResultItem {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    // TODO: this is horrible for cache, we should find the next N entities instead
                    // Find next entity
                    search_next_loop: while (true) {
                        if (self.sparse_cursors >= self.storage_entity_count_ptr.*) {
                            return null;
                        }

                        // Check that entry has all include components
                        const include_components = query_components[0..incl_component_indices.len];
                        inline for (include_components) |IncludeComponent| {
                            if (@field(self.sparse_sets, @typeName(IncludeComponent)).isSet(self.sparse_cursors) == false) {
                                self.sparse_cursors += 1;
                                continue :search_next_loop;
                            }
                        }

                        // Check that entry does not have any exclude components
                        const exclude_components = query_components[incl_component_indices.len .. incl_component_indices.len + excl_component_indices.len];
                        inline for (exclude_components) |ExcludeComponent| {
                            if (@field(self.sparse_sets, @typeName(ExcludeComponent)).isSet(self.sparse_cursors) == true) {
                                self.sparse_cursors += 1;
                                continue :search_next_loop;
                            }
                        }

                        break :search_next_loop; // sparse_cursor is a valid entity!
                    }

                    var result: ResultItem = undefined;
                    // if entity is first field
                    if (include_start_index > 0) {
                        @field(result, include_fields[0].name) = Entity{ .id = self.sparse_cursors };
                    }

                    inline for (include_fields[include_start_index..include_end_index]) |incl_field| {
                        const component_to_get = CompileReflect.compactComponentRequest(incl_field.type);

                        const sparse_set = @field(self.sparse_sets, @typeName(component_to_get.type));
                        const component_ptr = sparse_set.get(self.sparse_cursors).?;

                        switch (component_to_get.attr) {
                            .ptr => @field(result, incl_field.name) = component_ptr,
                            .value => @field(result, incl_field.name) = component_ptr.*,
                        }
                    }

                    self.sparse_cursors += 1;
                    return result;
                }
            };
        }

        fn indexOfComponent(comptime Component: type) usize {
            inline for (component_type_array, 0..) |StorageComponent, index| {
                if (Component == StorageComponent) {
                    return index;
                }
            }

            @compileError(@typeName(Component) ++ " is not a compoenent in this storage");
        }
    };
}

pub const QueryType = struct {};

pub const CompileReflect = struct {
    pub const CompactComponentRequest = struct {
        pub const Attr = enum {
            value,
            ptr,
        };

        type: type,
        attr: Attr,
    };
    pub fn compactComponentRequest(comptime ComponentPtrOrValueType: type) CompactComponentRequest {
        const type_info = @typeInfo(ComponentPtrOrValueType);

        return switch (type_info) {
            .Struct => .{
                .type = ComponentPtrOrValueType,
                .attr = .value,
            },
            .Pointer => |ptr_info| .{
                .type = ptr_info.child,
                .attr = .ptr,
            },
            else => @compileError(@typeName(ComponentPtrOrValueType) ++ " is not pointer, nor struct."),
        };
    }

    pub fn GroupSparseSets(comptime components: []const type) type {
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (&struct_fields, components) |*field, component| {
            const SparseSet = set.SparseSet(EntityId, component);
            const default_value = SparseSet{};
            field.* = std.builtin.Type.StructField{
                .name = @typeName(component),
                .type = SparseSet,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(SparseSet),
            };
        }
        const group_type = std.builtin.Type{ .Struct = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } };
        return @Type(group_type);
    }

    pub fn GroupSparseSetsPtr(comptime components: []const type) type {
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (&struct_fields, components) |*field, component| {
            const SparseSet = set.SparseSet(EntityId, component);
            field.* = std.builtin.Type.StructField{
                .name = @typeName(component),
                .type = *SparseSet,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(*SparseSet),
            };
        }
        const group_type = std.builtin.Type{ .Struct = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } };
        return @Type(group_type);
    }
};

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = CreateStorage(Testing.AllComponentsTuple);

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AEntityType = Testing.Archetype.A;
const BEntityType = Testing.Archetype.B;
const AbEntityType = Testing.Archetype.AB;
const AcEntityType = Testing.Archetype.AC;
const BcEntityType = Testing.Archetype.BC;
const AbcEntityType = Testing.Archetype.ABC;

test "init() + deinit() is idempotent" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity0 = try storage.createEntity(initial_state);
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try storage.createEntity(initial_state);
    try testing.expectEqual(entity1.id, 1);
}

test "createEntity() can create empty entities" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));

    const a = Testing.Component.A{ .value = 123 };
    {
        try storage.setComponents(entity, .{a});
        try testing.expectEqual(a, (try storage.getComponents(entity, AEntityType)).a);
    }

    const b = Testing.Component.B{ .value = 8 };
    {
        try storage.setComponents(entity, .{b});
        const comps = try storage.getComponents(entity, AbEntityType);
        try testing.expectEqual(a, comps.a);
        try testing.expectEqual(b, comps.b);
    }
}

test "setComponents() works " {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity1 = blk: {
        break :blk try storage.createEntity(.{Testing.Component.A{}});
    };

    const a = Testing.Component.A{ .value = 123 };
    const b = Testing.Component.B{ .value = 42 };
    try storage.setComponents(entity1, .{ a, b });

    const comps = try storage.getComponents(entity1, AbEntityType);
    try testing.expectEqual(a, comps.a);
    try testing.expectEqual(b, comps.b);
}

test "setComponents() update entities component state" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{},
        .b = Testing.Component.B{},
    };
    const entity = try storage.createEntity(initial_state);

    const a = Testing.Component.A{ .value = 123 };
    try storage.setComponents(entity, .{a});

    const stored_a = try storage.getComponents(entity, AEntityType);
    try testing.expectEqual(a, stored_a.a);
}

test "setComponents() with zero sized component works" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{
        Testing.Component.A{},
        Testing.Component.B{},
    });

    const c = Testing.Component.C{};
    try storage.setComponents(entity, .{c});

    try testing.expectEqual(true, storage.hasComponents(entity, .{ Testing.Component.A, Testing.Component.B, Testing.Component.C }));
}

test "setComponents() can reassign multiple components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage.setComponents(entity, Testing.Archetype.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored = try storage.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "setComponents() can add new components to entity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage.setComponents(entity, Testing.Archetype.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored = try storage.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "removeComponents() removes the component as expected" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = BcEntityType{
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.setComponents(entity, .{Testing.Component.A{}});
    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.A}));

    try storage.removeComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));

    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.B}));

    try storage.removeComponents(entity, .{Testing.Component.B});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.B}));
}

test "removeComponents() removes all components from entity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.removeComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));
}

test "removeComponents() removes multiple components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = Testing.Archetype.ABC{};
    const entity = try storage.createEntity(initial_state);

    try storage.removeComponents(entity, .{ Testing.Component.A, Testing.Component.C });

    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));
    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.B}));
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.C}));
}

test "hasComponents() identify missing and present components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AcEntityType{
        .a = Testing.Component.A{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.A}));
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.B}));
    try testing.expectEqual(false, storage.hasComponents(entity, .{ Testing.Component.A, Testing.Component.B }));
    try testing.expectEqual(false, storage.hasComponents(entity, .{ Testing.Component.A, Testing.Component.B, Testing.Component.C }));
    try testing.expectEqual(true, storage.hasComponents(entity, .{ Testing.Component.A, Testing.Component.C }));
}

test "getComponents() retrieve component value" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    _ = try storage.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 1 };
    _ = try storage.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 2 };
    _ = try storage.createEntity(initial_state);

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    const entity = try storage.createEntity(entity_initial_state);

    initial_state.a = Testing.Component.A{ .value = 3 };
    _ = try storage.createEntity(initial_state);
    initial_state.a = Testing.Component.A{ .value = 4 };
    _ = try storage.createEntity(initial_state);

    try testing.expectEqual(entity_initial_state, try storage.getComponents(entity, AEntityType));
}

test "getComponents() can mutate component value with ptr" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const MutableA = struct { a: *Testing.Component.A };
    const a_ptr = try storage.getComponents(entity, MutableA);
    try testing.expectEqual(initial_state.a, a_ptr.a.*);

    const new_a_value = Testing.Component.A{ .value = 42 };

    // mutate a value ptr
    a_ptr.a.* = new_a_value;

    try testing.expectEqual(new_a_value, (try storage.getComponents(entity, MutableA)).a.*);
}

test "clearRetainingCapacity() allow storage reuse" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var first_entity: Entity = undefined;

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    var entity: Entity = undefined;

    for (0..100) |i| {
        storage.clearRetainingCapacity();

        var initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 0 },
        };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 1 };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 2 };
        _ = try storage.createEntity(initial_state);

        if (i == 0) {
            first_entity = try storage.createEntity(entity_initial_state);
        } else {
            entity = try storage.createEntity(entity_initial_state);
        }

        initial_state.a = Testing.Component.A{ .value = 3 };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 4 };
        _ = try storage.createEntity(initial_state);
    }

    try testing.expectEqual(first_entity, entity);
    const entity_a = try storage.getComponents(entity, AEntityType);
    try testing.expectEqual(entity_initial_state.a, entity_a.a);
}

test "query with single include type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with multiple include type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var a_b_iter = StorageStub.Query(
            struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
            },
            .{},
        ).submit(&storage);

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

test "query with single ptr include type works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = StorageStub.Query(
            struct { a_ptr: *Testing.Component.A },
            .{},
        ).submit(&storage);

        while (a_iter.next()) |item| {
            item.a_ptr.value += 1;
            index += 1;
        }
    }

    {
        var index: usize = 1;
        var a_iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and single exclude works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{Testing.Component.B},
        ).submit(&storage);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and multiple exclude works" {
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
        _ = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{ Testing.Component.B, Testing.Component.C },
        ).submit(&storage);

        var index: usize = 200;
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
        entity.* = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{},
        ).submit(&storage);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            index += 1;
        }
    }
}

test "query with entity and include and exclude only works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{Testing.Component.B},
        ).submit(&storage);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);
            index += 1;
        }
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by adding additional components to entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepStorage = CreateStorage(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata });

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 0, .c = undefined };
    try storage.setComponents(entity, .{obj});

    const Obj = struct { o: RenderContext.ObjectMetadata };
    try testing.expectEqual(
        obj,
        (try storage.getComponents(entity, Obj)).o,
    );

    const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
    try storage.setComponents(entity, .{instance});

    try testing.expectEqual(
        obj,
        (try storage.getComponents(entity, Obj)).o,
    );
    const Inst = struct { i: Editor.InstanceHandle };
    try testing.expectEqual(
        instance,
        (try storage.getComponents(entity, Inst)).i,
    );
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by having more than one entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepStorage = CreateStorage(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata });

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    {
        const entity = try storage.createEntity(.{});

        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 5, .c = undefined };
        const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };

        try storage.setComponents(entity, .{ obj, instance });

        const comps = try storage.getComponents(entity, struct { o: RenderContext.ObjectMetadata, i: Editor.InstanceHandle });
        try testing.expectEqual(
            obj.a,
            comps.o.a,
        );
        try testing.expectEqual(
            obj.b,
            comps.o.b,
        );
        try testing.expectEqual(
            instance,
            comps.i,
        );
    }
    {
        const entity = try storage.createEntity(.{});
        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 2, .c = undefined };
        const instance = Editor.InstanceHandle{ .a = 1, .b = 1, .c = 1 };
        try storage.setComponents(entity, .{ obj, instance });

        const comps = try storage.getComponents(entity, struct { o: RenderContext.ObjectMetadata, i: Editor.InstanceHandle });
        try testing.expectEqual(
            obj.a,
            comps.o.a,
        );
        try testing.expectEqual(
            obj.b,
            comps.o.b,
        );
        try testing.expectEqual(
            instance,
            comps.i,
        );
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Removing component cause storage to become in invalid state" {
    const InstanceHandle = packed struct {
        a: u16,
        b: u32,
        c: u16,
    };
    const Transform = struct {
        mat: [4]@Vector(4, f32),
    };
    const Position = struct {
        vec: @Vector(4, f32),
    };
    const Rotation = struct {
        quat: @Vector(4, f32),
    };
    const Scale = struct {
        vec: @Vector(4, f32),
    };
    const ObjectMetadata = struct {
        a: Entity,
        b: u8,
        c: [64]u8,
    };

    const RepStorage = CreateStorage(.{
        ObjectMetadata,
        Transform,
        Position,
        Rotation,
        Scale,
        InstanceHandle,
    });

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    const instance_handle = InstanceHandle{ .a = 3, .b = 3, .c = 3 };
    const transform = Transform{ .mat = .{
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
    } };
    const position = Position{ .vec = [4]f32{ 3, 3, 3, 3 } };
    const rotation = Rotation{ .quat = [4]f32{ 3, 3, 3, 3 } };
    const scale = Scale{ .vec = [4]f32{ 3, 3, 3, 3 } };
    const obj = ObjectMetadata{ .a = Entity{ .id = 3 }, .b = 3, .c = undefined };

    const SceneObject = struct {
        obj: ObjectMetadata,
        transform: Transform,
        position: Position,
        rotation: Rotation,
        scale: Scale,
        instance_handle: InstanceHandle,
    };
    const entity_state = SceneObject{
        .obj = obj,
        .transform = transform,
        .position = position,
        .rotation = rotation,
        .scale = scale,
        .instance_handle = instance_handle,
    };

    _ = try storage.createEntity(entity_state);
    const entity = try storage.createEntity(entity_state);
    _ = try storage.createEntity(entity_state);

    {
        const actual_state = try storage.getComponents(entity, SceneObject);
        try testing.expectEqual(transform, actual_state.transform);
        try testing.expectEqual(position, actual_state.position);
        try testing.expectEqual(rotation, actual_state.rotation);
        try testing.expectEqual(scale, actual_state.scale);
        try testing.expectEqual(instance_handle, actual_state.instance_handle);
    }

    _ = try storage.removeComponents(entity, .{Position});

    {
        const SceneObjectNoPos = struct {
            obj: ObjectMetadata,
            transform: Transform,
            rotation: Rotation,
            scale: Scale,
            instance_handle: InstanceHandle,
        };
        const actual_state = try storage.getComponents(entity, SceneObjectNoPos);
        try testing.expectEqual(transform, actual_state.transform);
        try testing.expectEqual(rotation, actual_state.rotation);
        try testing.expectEqual(scale, actual_state.scale);
        try testing.expectEqual(instance_handle, actual_state.instance_handle);
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

    const RepStorage = CreateStorage(.{
        transform.Position,
        transform.Rotation,
        transform.Scale,
        transform.WorldTransform,
        Parent,
        Children,
    });

    const QueryItem = struct {
        position: transform.Position,
        rotation: transform.Rotation,
        scale: transform.Scale,
        world_transform: *transform.WorldTransform,
        children: Children,
    };
    const Query = RepStorage.Query(
        QueryItem,
        // exclude type
        .{Parent},
    );
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

    var iter = Query.submit(&storage);

    try testing.expect(iter.next() != null);
}
