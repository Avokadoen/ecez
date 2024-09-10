const std = @import("std");
const Allocator = std.mem.Allocator;

const set = @import("sparse_set.zig");

const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityId = entity_type.EntityId;

pub const StorageType = struct {};
pub const SubsetType = struct {};
pub const QueryType = struct {};

pub const SubsetAccess = enum {
    read_only,
    read_and_write,
};

pub fn CreateStorage(comptime all_components: anytype) type {
    return struct {
        pub const EcezType = StorageType;

        // a flat array of the type of each field in the components tuple
        pub const component_type_array = CompileReflect.verifyComponentTuple(all_components);

        pub const GroupSparseSets = CompileReflect.GroupSparseSets(&component_type_array);

        const Storage = @This();

        allocator: Allocator,
        sparse_sets: GroupSparseSets = .{},
        number_of_entities: std.atomic.Value(EntityId) = .{ .raw = 0 },

        /// intialize the storage structure
        ///
        /// Parameters:
        ///
        ///     - allocator: allocator used when initiating entities
        pub fn init(allocator: Allocator) error{OutOfMemory}!Storage {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            return Storage{
                .allocator = allocator,
            };
        }

        /// deinitalize the storage and any memory tied to it.
        ///
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

            self.number_of_entities.store(0, .seq_cst);
        }

        /// Create an entity and returns the entity handle
        ///
        /// Parameters:
        ///
        ///     - entity_state: the components that the new entity should be assigned
        pub fn createEntity(self: *Storage, entity_state: anytype) error{OutOfMemory}!Entity {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                @TypeOf(entity_state),
            );

            const field_info = @typeInfo(@TypeOf(entity_state));
            const this_id = self.number_of_entities.fetchAdd(1, .acq_rel);

            errdefer {
                // TODO: subtract here is racy, find a proper way if reclaiming entity as this is technically a minor leak
                // self.number_of_entities.fetchSub(.AcquireRelease);
                inline for (field_info.Struct.fields) |field| {
                    var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                        self.sparse_sets,
                        @typeName(field.type),
                    );
                    _ = sparse_set.unset(this_id);
                }
            }

            inline for (field_info.Struct.fields) |field| {
                var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                    self.sparse_sets,
                    @typeName(field.type),
                );

                // Ensure that the sparse set has a slot for this entity
                try sparse_set.growSparse(self.allocator, this_id + 1);

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
        ///
        /// Parameters:
        ///
        ///     - entity:               the entity that should be assigned the component value
        ///     - struct_of_components: the new component values
        pub fn setComponents(self: *Storage, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                @TypeOf(struct_of_components),
            );

            const field_info = @typeInfo(@TypeOf(struct_of_components));

            // TODO: proper errdefer
            // errdefer

            inline for (field_info.Struct.fields) |field| {
                var sparse_set: *set.SparseSet(EntityId, field.type) = &@field(
                    self.sparse_sets,
                    @typeName(field.type),
                );

                // Ensure that the sparse set has a slot for this entity
                try sparse_set.growSparse(self.allocator, entity.id + 1);

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

        /// Unset components owned by entity
        ///
        /// Parameters:
        ///
        ///     - entity:    the entity being mutated
        ///     - components: the components to remove in a tuple/struct
        pub fn unsetComponents(self: *Storage, entity: Entity, comptime struct_of_remove_components: anytype) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                struct_of_remove_components,
            );

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

        /// Check if an entity has a set of components
        ///
        /// Parameters:
        ///
        ///     - entity:     the entity to check for type Components
        ///     - components: a tuple of component types to check after
        pub fn hasComponents(self: Storage, entity: Entity, comptime components: anytype) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                components,
            );

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
        ///
        /// Parameters:
        ///
        ///     - entity:    the entity to retrieve Component from
        ///     - Components: a struct type where fields are compoents that that belong to entity
        pub fn getComponents(self: *const Storage, entity: Entity, comptime Components: type) error{MissingComponent}!Components {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                Components,
            );

            var result: Components = undefined;
            const field_info = @typeInfo(Components);
            if (field_info != .Struct) {
                @compileError(@src().fn_name ++ " expect Components type arg to be a struct of components");
            }

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

        /// Fetch an entity's component data
        ///
        /// Parameters:
        ///
        ///     - entity:    the entity to retrieve Component from
        ///     - Components: a struct type where fields are compoents that that belong to entity
        pub fn getComponent(self: *const Storage, entity: Entity, comptime Component: type) error{MissingComponent}!Component {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                .{Component},
            );

            const component_to_get = CompileReflect.compactComponentRequest(Component);
            const sparse_set: set.SparseSet(EntityId, component_to_get.type) = @field(
                self.sparse_sets,
                @typeName(component_to_get.type),
            );

            const get_ptr = sparse_set.get(entity.id) orelse return error.MissingComponent;
            switch (component_to_get.attr) {
                .ptr => return get_ptr,
                .value => return get_ptr.*,
            }
        }

        /// Create a SubStorage api. Allows calling createEntity, (un)setComponents, getComponent(s), hasComponents
        /// using types registered in fn SubStorage arg 'components'.
        ///
        /// Parameters:
        ///
        ///     - component_subset: All components that may be edited by this storage subset
        ///
        /// This is used by the scheduler to track systems that does storage edits and to allow
        /// narrow synchronization. In other words, this lets the scheduler see which components
        /// need to be accounted for in a system when present as a system argument.
        pub fn Subset(comptime component_subset: anytype, comptime access: SubsetAccess) type {

            // Check if tuple is valid and get array of types instead if valid
            const comp_arr = CompileReflect.verifyComponentTuple(component_subset);

            // Check that each component type is part of the storage
            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not a storage component",
                &component_type_array,
                component_subset,
            );

            return struct {
                pub const EcezType = SubsetType;
                pub const component_subset_arr = comp_arr;
                pub const track_access = access;

                pub const ThisSubset = @This();

                storage: *Storage,

                pub fn createEntity(self: *ThisSubset, entity_state: anytype) error{OutOfMemory}!Entity {
                    comptime {
                        dissallowInReadOnly(@src());

                        CompileReflect.verifyInnerTypesIsInSlice(
                            " is not part of " ++ simplifiedTypeName(),
                            &component_subset_arr,
                            @TypeOf(entity_state),
                        );
                    }

                    return self.storage.createEntity(entity_state);
                }

                pub fn setComponents(self: *const ThisSubset, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
                    comptime {
                        dissallowInReadOnly(@src());

                        CompileReflect.verifyInnerTypesIsInSlice(
                            " is not part of " ++ simplifiedTypeName(),
                            &component_subset_arr,
                            @TypeOf(struct_of_components),
                        );
                    }

                    return self.storage.setComponents(entity, struct_of_components);
                }

                pub fn unsetComponents(self: *const ThisSubset, entity: Entity, comptime struct_of_remove_components: anytype) error{OutOfMemory}!void {
                    comptime {
                        dissallowInReadOnly(@src());

                        CompileReflect.verifyInnerTypesIsInSlice(
                            " is not part of " ++ simplifiedTypeName(),
                            &component_subset_arr,
                            struct_of_remove_components,
                        );
                    }

                    return self.storage.unsetComponents(entity, struct_of_remove_components);
                }

                pub fn hasComponents(self: *const ThisSubset, entity: Entity, comptime components: anytype) bool {
                    comptime CompileReflect.verifyInnerTypesIsInSlice(
                        " is not part of " ++ simplifiedTypeName(),
                        &component_subset_arr,
                        components,
                    );

                    return self.storage.hasComponents(entity, components);
                }

                pub fn getComponents(self: *const ThisSubset, entity: Entity, comptime Components: type) error{MissingComponent}!Components {
                    comptime {
                        // If this is a read only storage, then we must make sure there is no pointers in Components
                        if (access == .read_only) {
                            const components_info = @typeInfo(Components);
                            for (components_info.Struct.fields) |field| {
                                const field_info = @typeInfo(field.type);
                                if (field_info.Pointer) {
                                    @compileError("Accessing component pointers is illegal in a read only sub storage");
                                }
                            }
                        }

                        CompileReflect.verifyInnerTypesIsInSlice(
                            " is not part of " ++ simplifiedTypeName(),
                            &component_subset_arr,
                            Components,
                        );
                    }

                    return self.storage.getComponents(entity, Components);
                }

                pub fn getComponent(self: *const ThisSubset, entity: Entity, comptime Component: type) error{MissingComponent}!Component {
                    comptime {
                        // If this is a read only storage, then we must make sure there is no pointers in Components
                        if (access == .read_only) {
                            const components_info = @typeInfo(Component);
                            if (components_info.Pointer) {
                                @compileError("Accessing component pointers is illegal in a read only sub storage");
                            }
                        }

                        CompileReflect.verifyInnerTypesIsInSlice(
                            " is not part of " ++ simplifiedTypeName(),
                            &component_subset_arr,
                            .{Component},
                        );
                    }

                    return self.storage.getComponent(entity, Component);
                }

                fn simplifiedTypeName() [:0]const u8 {
                    const type_name = @typeName(ThisSubset);
                    const start_index = std.mem.indexOf(u8, type_name, "Subset").?;
                    return type_name[start_index..];
                }

                fn dissallowInReadOnly(caller: std.builtin.SourceLocation) void {
                    if (access == .read_only) {
                        @compileError("can't call " ++ caller.fn_name ++ " on a read only Storage Subset");
                    }
                }
            };
        }

        /// Query components which can be iterated upon.
        ///
        /// Parameters:
        ///
        ///     - ResultItem:    All the components you would like to iterate over in a single struct.
        ///                      Each component in the struct will belong to the same entity.
        ///                      A field does not have to be a component if it is of type Entity and it's the first
        ///                      field.
        ///
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
                pub const EcezType = QueryType;

                pub const ThisQuery = @This();

                // TODO: this is horrible for cache, we should find the next N entities instead
                sparse_cursors: EntityId,
                storage_entity_count_ptr: *const std.atomic.Value(EntityId),

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
                            var skip_component: bool = false;
                            // Skip indices we already stored
                            already_included_loop: for (search_order[0..search_index]) |prev_found| {
                                if (prev_found == component_index) {
                                    skip_component = true;
                                    continue :already_included_loop;
                                }
                            }

                            if (skip_component == false) {
                                const Component = all_components[component_index];
                                const sparse_set: set.SparseSet(EntityId, Component) = @field(
                                    storage.sparse_sets,
                                    @typeName(Component),
                                );

                                if (sparse_set.dense_len <= current_min_value and sparse_set.dense_len >= last_min_value) {
                                    current_index = component_index;
                                }
                            }
                        }

                        inline for (excl_component_indices) |component_index| {
                            var skip_component: bool = false;
                            // Skip indices we already stored
                            already_included_loop: for (search_order[0..search_index]) |prev_found| {
                                if (prev_found == component_index) {
                                    skip_component = true;
                                    continue :already_included_loop;
                                }
                            }

                            if (skip_component == false) {
                                const Component = all_components[component_index];
                                const sparse_set: set.SparseSet(EntityId, Component) = @field(
                                    storage.sparse_sets,
                                    @typeName(Component),
                                );

                                const inverse_value = storage.number_of_entities.load(.monotonic) - sparse_set.dense_len;
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
                        .storage_entity_count_ptr = &storage.number_of_entities,
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
                        if (self.sparse_cursors >= self.storage_entity_count_ptr.load(.monotonic)) {
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

                pub fn skip(self: *ThisQuery, skip_count: u32) void {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    // TODO: this is horrible for cache, we should find the next N entities instead
                    // Find next entity
                    for (0..skip_count) |_| {
                        search_next_loop: while (true) {
                            if (self.sparse_cursors >= self.storage_entity_count_ptr.load(.monotonic)) {
                                return;
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

                        self.sparse_cursors = @min(self.sparse_cursors + 1, self.storage_entity_count_ptr.load(.monotonic));
                    }
                }

                pub fn reset(self: *ThisQuery) void {
                    self.sparse_cursors = 0;
                }
            };
        }

        /// Retrieve the sparse set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getSparseSetValue(storage: Storage, comptime Component: type) set.SparseSet(EntityId, Component) {
            return @field(
                storage.sparse_sets,
                @typeName(Component),
            );
        }

        /// Retrieve the sparse set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getSparseSetPtr(storage: *Storage, comptime Component: type) *set.SparseSet(EntityId, Component) {
            return &@field(
                storage.sparse_sets,
                @typeName(Component),
            );
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
            else => @compileError(@typeName(ComponentPtrOrValueType) ++ " is not pointer, nor a struct."),
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

    /// Produce a flat array of component types if the 'components' tuple is valid
    fn verifyComponentTuple(comptime components: anytype) return_type_blk: {
        const components_info = @typeInfo(@TypeOf(components));
        if (components_info != .Struct) {
            @compileError("components was not a tuple of types");
        }

        break :return_type_blk [components_info.Struct.fields.len]type;
    } {
        const components_info = @typeInfo(@TypeOf(components));
        var field_types: [components_info.Struct.fields.len]type = undefined;
        for (&field_types, components_info.Struct.fields, 0..) |*field_type, field, component_index| {
            if (@typeInfo(field.type) != .Type) {
                @compileError("components must be a struct of types, field '" ++ field.name ++ "' was " ++ @typeName(field.type));
            }

            if (@typeInfo(components[component_index]) != .Struct) {
                @compileError("component types must be a struct, field '" ++ field.name ++ "' was '" ++ @typeName(components[component_index]));
            }

            field_type.* = components[component_index];
        }

        return field_types;
    }

    fn verifyInnerTypesIsInSlice(
        comptime fmt_error_msg: []const u8,
        comptime type_slice: []const type,
        comptime type_tuple: anytype,
    ) void {
        const TupleUnwrapped = if (@TypeOf(type_tuple) == type) type_tuple else @TypeOf(type_tuple);

        const type_tuple_info = @typeInfo(TupleUnwrapped);
        field_loop: for (type_tuple_info.Struct.fields) |field| {
            const FieldTypeUnwrapped = if (field.type == type) @field(type_tuple, field.name) else field.type;
            const InnerType = compactComponentRequest(FieldTypeUnwrapped).type;

            for (type_slice) |Type| {
                if (InnerType == Type) {
                    continue :field_loop;
                }
            }

            @compileError(@typeName(InnerType) ++ fmt_error_msg);
        }
    }
};

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = CreateStorage(Testing.AllComponentsTuple);

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;

test "init() + deinit() is idempotent" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = .{
        Testing.Component.A{},
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
        try testing.expectEqual(a, try storage.getComponent(entity, Testing.Component.A));
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

    const stored_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
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
    try storage.setComponents(entity, Testing.Structure.AB{
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
    try storage.setComponents(entity, Testing.Structure.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored = try storage.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "unsetComponents() removes the component as expected" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = BcEntityType{
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.setComponents(entity, .{Testing.Component.A{}});
    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.A}));

    try storage.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));

    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.B}));

    try storage.unsetComponents(entity, .{Testing.Component.B});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.B}));
}

test "unsetComponents() removes all components from entity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{Testing.Component.A{}});

    try storage.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));
}

test "unsetComponents() removes multiple components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = Testing.Structure.ABC{};
    const entity = try storage.createEntity(initial_state);

    try storage.unsetComponents(entity, .{ Testing.Component.A, Testing.Component.C });

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

test "getComponents() retrieve component values" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 0 },
            .b = Testing.Component.B{ .value = 0 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 1 },
            .b = Testing.Component.B{ .value = 1 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 2 },
            .b = Testing.Component.B{ .value = 2 },
        };
        _ = try storage.createEntity(initial_state);
    }

    const entity_initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 123 },
        .b = Testing.Component.B{ .value = 123 },
    };
    const entity = try storage.createEntity(entity_initial_state);

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 3 },
            .b = Testing.Component.B{ .value = 3 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 4 },
            .b = Testing.Component.B{ .value = 4 },
        };
        _ = try storage.createEntity(initial_state);
    }

    try testing.expectEqual(entity_initial_state, try storage.getComponents(entity, AbEntityType));
}

test "getComponents() can mutate component value with ptr" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const MutableAB = struct { a: *Testing.Component.A, b: *Testing.Component.B };
    const ab_ptr = try storage.getComponents(entity, MutableAB);
    try testing.expectEqual(initial_state.a, ab_ptr.a.*);
    try testing.expectEqual(initial_state.b, ab_ptr.b.*);

    const new_a_value = Testing.Component.A{ .value = 42 };
    const new_b_value = Testing.Component.B{ .value = 99 };

    // mutate a value ptr
    ab_ptr.a.* = new_a_value;
    ab_ptr.b.* = new_b_value;

    const stored_components = try storage.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a_value, stored_components.a);
    try testing.expectEqual(new_b_value, stored_components.b);
}

test "getComponent() retrieve component values" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 0 },
            .b = Testing.Component.B{ .value = 0 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 1 },
            .b = Testing.Component.B{ .value = 1 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 2 },
            .b = Testing.Component.B{ .value = 2 },
        };
        _ = try storage.createEntity(initial_state);
    }

    const entity_initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 123 },
        .b = Testing.Component.B{ .value = 123 },
    };
    const entity = try storage.createEntity(entity_initial_state);

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 3 },
            .b = Testing.Component.B{ .value = 3 },
        };
        _ = try storage.createEntity(initial_state);
    }

    {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 4 },
            .b = Testing.Component.B{ .value = 4 },
        };
        _ = try storage.createEntity(initial_state);
    }

    try testing.expectEqual(entity_initial_state.a, try storage.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(entity_initial_state.b, try storage.getComponent(entity, Testing.Component.B));
}

test "getComponent() can mutate component value with ptr" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const MutableAB = struct { a: *Testing.Component.A, b: *Testing.Component.B };
    const ab_ptr = try storage.getComponents(entity, MutableAB);
    try testing.expectEqual(initial_state.a, ab_ptr.a.*);
    try testing.expectEqual(initial_state.b, ab_ptr.b.*);

    const new_a_value = Testing.Component.A{ .value = 42 };
    const new_b_value = Testing.Component.B{ .value = 99 };

    // mutate a value ptr
    ab_ptr.a.* = new_a_value;
    ab_ptr.b.* = new_b_value;

    try testing.expectEqual(new_a_value, try storage.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(new_b_value, try storage.getComponent(entity, Testing.Component.B));
}

test "clearRetainingCapacity() allow storage reuse" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var first_entity: Entity = undefined;

    const initial_value: u32 = 123;
    var entity: Entity = undefined;

    for (0..100) |i| {
        storage.clearRetainingCapacity();

        _ = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});
        _ = try storage.createEntity(.{Testing.Component.A{ .value = 1 }});
        _ = try storage.createEntity(.{Testing.Component.A{ .value = 2 }});

        if (i == 0) {
            first_entity = try storage.createEntity(.{Testing.Component.A{ .value = initial_value }});
        } else {
            entity = try storage.createEntity(.{Testing.Component.A{ .value = initial_value }});
        }

        _ = try storage.createEntity(.{Testing.Component.A{ .value = 3 }});
        _ = try storage.createEntity(.{Testing.Component.A{ .value = 4 }});
    }

    try testing.expectEqual(first_entity, entity);
    const comp_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(Testing.Component.A{ .value = initial_value }, comp_a);
}

test "Subset createEntity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Subset = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B }, .read_and_write);
    var storage_subset = Subset{
        .storage = &storage,
    };

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 42 },
        .b = Testing.Component.B{ .value = 42 },
    };
    const entity = try storage_subset.createEntity(initial_state);

    const stored = try storage_subset.getComponents(entity, AbEntityType);
    try testing.expectEqual(initial_state.a, stored.a);
    try testing.expectEqual(initial_state.b, stored.b);
}

test "Subset setComponents() can reassign multiple components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Subset = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B }, .read_and_write);
    var storage_subset = Subset{
        .storage = &storage,
    };

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage_subset.setComponents(entity, Testing.Structure.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored = try storage_subset.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "Subset setComponents() can add new components to entity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Subset = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B }, .read_and_write);
    var storage_subset = Subset{
        .storage = &storage,
    };

    const entity = try storage.createEntity(.{});

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage_subset.setComponents(entity, Testing.Structure.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored = try storage.getComponents(entity, AbEntityType);
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "Subset unsetComponents() removes the component as expected" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Subset = StorageStub.Subset(.{ Testing.Component.A, Testing.Component.B }, .read_and_write);
    var storage_subset = Subset{
        .storage = &storage,
    };

    const initial_state = BcEntityType{
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.setComponents(entity, .{Testing.Component.A{}});
    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.A}));

    try storage_subset.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage_subset.hasComponents(entity, .{Testing.Component.A}));

    try testing.expectEqual(true, storage_subset.hasComponents(entity, .{Testing.Component.B}));

    try storage_subset.unsetComponents(entity, .{Testing.Component.B});
    try testing.expectEqual(false, storage_subset.hasComponents(entity, .{Testing.Component.B}));
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

test "query skip works" {
    var storage = try StorageStub.init(std.testing.allocator);
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var a_iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

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

    {
        var a_iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

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
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
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
        _ = try storage.createEntity(.{
            Testing.Component.A{ .value = @as(u32, @intCast(index)) },
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

    _ = try storage.unsetComponents(entity, .{Position});

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
