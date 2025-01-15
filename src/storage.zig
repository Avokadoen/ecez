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

pub fn CreateStorage(comptime all_components: anytype) type {
    return struct {
        pub const EcezType = StorageType;

        // a flat array of the type of each field in the components tuple
        pub const component_type_array = CompileReflect.verifyComponentTuple(all_components);

        pub const GroupDenseSets = CompileReflect.GroupDenseSets(&component_type_array);
        pub const GroupSparseSets = CompileReflect.GroupSparseSets(&component_type_array);

        const Storage = @This();

        allocator: Allocator,

        sparse_sets: GroupSparseSets,
        dense_sets: GroupDenseSets,

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
                .sparse_sets = .{},
                .dense_sets = .{},
            };
        }

        /// deinitalize the storage and any memory tied to it.
        ///
        pub fn deinit(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            inline for (component_type_array) |Component| {
                if (@sizeOf(Component) > 0) {
                    const dense_set = self.getDenseSetPtr(Component);
                    dense_set.deinit(self.allocator);
                }
            }
            inline for (component_type_array) |Component| {
                const sparse_set = self.getSparseSetPtr(Component);
                sparse_set.deinit(self.allocator);
            }
        }

        /// Clear storage memory for reuse. **All entities will become invalid**.
        pub fn clearRetainingCapacity(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            inline for (component_type_array) |Component| {
                if (@sizeOf(Component) > 0) {
                    const sparse_set: *set.Sparse.Full = self.getSparseSetPtr(Component);
                    const dense_set = self.getDenseSetPtr(Component);

                    set.clearRetainingCapacity(sparse_set, dense_set);
                } else {
                    const sparse_set: *set.Sparse.Tag = self.getSparseSetPtr(Component);
                    sparse_set.clearRetainingCapacity();
                }
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

            // This will "leak" a handle if grow fails, but if it fails, then the app has more issues anyways.
            const this_id = self.number_of_entities.fetchAdd(1, .acq_rel);

            // Ensure capacity first to avoid errdefer
            inline for (field_info.Struct.fields) |field| {
                const Component = field.type;

                {
                    var sparse_set = self.getSparseSetPtr(Component);
                    try sparse_set.grow(self.allocator, this_id + 1);
                }

                if (@sizeOf(Component) > 0) {
                    var dense_set = self.getDenseSetPtr(Component);
                    try dense_set.grow(self.allocator, dense_set.dense_len + 1);
                }
            }

            inline for (field_info.Struct.fields) |field| {
                const Component = field.type;
                const component: Component = @field(
                    entity_state,
                    field.name,
                );

                const sparse_set = self.getSparseSetPtr(Component);
                if (@sizeOf(Component) > 0) {
                    const dense_set = self.getDenseSetPtr(Component);
                    set.setAssumeCapacity(
                        sparse_set,
                        dense_set,
                        this_id,
                        component,
                    );
                } else {
                    sparse_set.setAssumeCapacity(this_id);
                }
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
        ///
        /// Hazards:
        ///
        ///     It's undefined behaviour to call setComponents, then read a stale query result (returned from Query.next) item pointer field.
        ///     The same is true for returned getComponent(s) that are pointers. Be sure to call setComponents AFTER any component pointer access.
        pub fn setComponents(self: *Storage, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                @TypeOf(struct_of_components),
            );

            const field_info = @typeInfo(@TypeOf(struct_of_components));

            // Ensure capacity first to avoid errdefer
            inline for (field_info.Struct.fields) |field| {
                const Component = field.type;
                {
                    var sparse_set = self.getSparseSetPtr(Component);
                    try sparse_set.grow(self.allocator, entity.id + 1);
                }

                if (@sizeOf(Component) > 0) {
                    var dense_set = self.getDenseSetPtr(Component);
                    try dense_set.grow(self.allocator, entity.id + 1);
                }
            }

            inline for (field_info.Struct.fields) |field| {
                const Component = field.type;
                const component: Component = @field(
                    struct_of_components,
                    field.name,
                );

                const sparse_set = self.getSparseSetPtr(field.type);
                if (@sizeOf(Component) > 0) {
                    const dense_set = self.getDenseSetPtr(field.type);
                    set.setAssumeCapacity(
                        sparse_set,
                        dense_set,
                        entity.id,
                        component,
                    );
                } else {
                    sparse_set.setAssumeCapacity(entity.id);
                }
            }
        }

        /// Unset components owned by entity
        ///
        /// Parameters:
        ///
        ///     - entity:    the entity being mutated
        ///     - components: the components to remove in a tuple/struct
        pub fn unsetComponents(self: *Storage, entity: Entity, comptime struct_of_remove_components: anytype) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                struct_of_remove_components,
            );

            const field_info = @typeInfo(@TypeOf(struct_of_remove_components));
            inline for (field_info.Struct.fields) |field| {
                const ComponentToRemove = @field(struct_of_remove_components, field.name);

                const sparse_set = self.getSparseSetPtr(ComponentToRemove);

                if (@sizeOf(ComponentToRemove) > 0) {
                    const dense_set = self.getDenseSetPtr(ComponentToRemove);
                    _ = set.unset(
                        sparse_set,
                        dense_set,
                        entity.id,
                    );
                } else {
                    sparse_set.unset(entity.id);
                }
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

                if (self.getSparseSetConstPtr(ComponentToCheck).isSet(entity.id) == false) {
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
        ///     - Components: a struct type where fields are compoents that that belong to entity.
        ///                   It's illegal to have field that is pointer to Component of size == 0
        ///
        /// Hazards:
        ///
        ///     it's undefined behaviour to read component pointers after a call setComponents with the same component type(s),
        ///     even it it's not on the same entity.
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

                const sparse_set = self.getSparseSetConstPtr(component_to_get.type);
                if (@sizeOf(component_to_get.type) > 0) {
                    const dense_set = self.getDenseSetConstPtr(component_to_get.type);

                    const get_ptr = set.get(
                        sparse_set,
                        dense_set,
                        entity.id,
                    ) orelse return error.MissingComponent;
                    switch (component_to_get.attr) {
                        .ptr => @field(result, field.name) = get_ptr,
                        .value => @field(result, field.name) = get_ptr.*,
                    }
                } else {
                    comptime {
                        if (component_to_get.attr == .ptr) {
                            const error_message = std.fmt.comptimePrint("field '{s}' is a pointer to zero sized component which is illegal", .{field.name});
                            @compileError(error_message);
                        }
                    }

                    if (sparse_set.isSet(entity.id) == false) {
                        return error.MissingComponent;
                    }

                    @field(result, field.name) = component_to_get.type{};
                }
            }

            return result;
        }

        /// Fetch an entity's component data
        ///
        /// Parameters:
        ///
        ///     - entity:    the entity to retrieve Component from
        ///     - Component: Component to fetch from entity. Size of Component must be greater than 0
        ///
        /// Hazards:
        ///
        ///     it's undefined behaviour to read component pointers after a call setComponents with the same component type,
        ///     even it it's not on the same entity.
        pub fn getComponent(self: *const Storage, entity: Entity, comptime Component: type) error{MissingComponent}!Component {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                .{Component},
            );

            const component_to_get = CompileReflect.compactComponentRequest(Component);
            comptime {
                if (@sizeOf(component_to_get.type) == 0) {
                    const error_message = std.fmt.comptimePrint("Component size must be greater than 0, @sizeOf({s}) == 0", .{@typeName(component_to_get.type)});
                    @compileError(error_message);
                }
            }

            const sparse_set = self.getSparseSetConstPtr(component_to_get.type);
            const dense_set = self.getDenseSetConstPtr(component_to_get.type);
            const get_ptr = set.get(
                sparse_set,
                dense_set,
                entity.id,
            ) orelse return error.MissingComponent;
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
        ///
        /// Request a component as a pointer for write access. Value for read-only access
        pub fn Subset(comptime component_subset: anytype) type {

            // Check if tuple is valid and get array of types instead if valid
            const comp_types = CompileReflect.verifyComponentTuple(component_subset);
            const inner_comp_types = get_inner_blk: {
                var inner: [comp_types.len]type = undefined;
                for (&inner, comp_types) |*Inner, CompType| {
                    Inner.* = CompileReflect.compactComponentRequest(CompType).type;
                }
                break :get_inner_blk inner;
            };

            // Check that each component type is part of the storage
            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not a storage component",
                &component_type_array,
                component_subset,
            );

            return struct {
                pub const EcezType = SubsetType;

                pub const component_access = comp_types;

                pub const ThisSubset = @This();

                storage: *Storage,

                pub fn createEntity(self: *ThisSubset, entity_state: anytype) error{OutOfMemory}!Entity {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const entity_state_info = @typeInfo(@TypeOf(entity_state));
                        get_validation_loop: for (entity_state_info.Struct.fields) |field| {
                            const FieldType = field.type;
                            for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                                if (FieldType == InnerSubsetComp) {
                                    // Subset is registered to have ptr access, validation is OK
                                    const subset_access = CompileReflect.compactComponentRequest(SubsetComp);
                                    if (subset_access.attr == .ptr) {
                                        continue :get_validation_loop;
                                    }

                                    // Criteria above not met. Validation NOT OK
                                    @compileError(@src().fn_name ++ " " ++ @typeName(InnerSubsetComp) ++ ", subset " ++ simplifiedTypeName() ++ " only has value access (must have ptr/write access)");
                                }
                            }
                            @compileError(@src().fn_name ++ " " ++ @typeName(FieldType) ++ " subset " ++ simplifiedTypeName() ++ " does not have this type");
                        }
                    }

                    return self.storage.createEntity(entity_state);
                }

                pub fn setComponents(self: *const ThisSubset, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const set_info = @typeInfo(@TypeOf(struct_of_components));
                        get_validation_loop: for (set_info.Struct.fields) |field| {
                            const FieldType = field.type;
                            for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                                if (FieldType == InnerSubsetComp) {
                                    // Subset is registered to have ptr access, validation is OK
                                    const subset_access = CompileReflect.compactComponentRequest(SubsetComp);
                                    if (subset_access.attr == .ptr) {
                                        continue :get_validation_loop;
                                    }

                                    // Criteria above not met. Validation NOT OK
                                    @compileError(@src().fn_name ++ " " ++ @typeName(InnerSubsetComp) ++ ", subset " ++ simplifiedTypeName() ++ " only has value access (must have ptr/write access)");
                                }
                            }
                            @compileError(@src().fn_name ++ " " ++ @typeName(FieldType) ++ " subset " ++ simplifiedTypeName() ++ " does not have this type");
                        }
                    }

                    return self.storage.setComponents(entity, struct_of_components);
                }

                pub fn unsetComponents(self: *const ThisSubset, entity: Entity, comptime struct_of_remove_components: anytype) void {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const unset_info = @typeInfo(@TypeOf(struct_of_remove_components));
                        get_validation_loop: for (unset_info.Struct.fields) |field| {
                            const FieldType = @field(struct_of_remove_components, field.name);
                            for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                                if (FieldType == InnerSubsetComp) {
                                    // Subset is registered to have ptr access, validation is OK
                                    const subset_access = CompileReflect.compactComponentRequest(SubsetComp);
                                    if (subset_access.attr == .ptr) {
                                        continue :get_validation_loop;
                                    }

                                    // Criteria above not met. Validation NOT OK
                                    @compileError(@src().fn_name ++ " " ++ @typeName(InnerSubsetComp) ++ ", subset " ++ simplifiedTypeName() ++ " only has value access (must have ptr/write access)");
                                }
                            }
                            @compileError(@src().fn_name ++ " " ++ @typeName(FieldType) ++ " subset " ++ simplifiedTypeName() ++ " does not have this type");
                        }
                    }

                    self.storage.unsetComponents(entity, struct_of_remove_components);
                }

                pub fn hasComponents(self: *const ThisSubset, entity: Entity, comptime components: anytype) bool {
                    comptime CompileReflect.verifyInnerTypesIsInSlice(
                        " is not part of " ++ simplifiedTypeName(),
                        &inner_comp_types,
                        components,
                    );

                    return self.storage.hasComponents(entity, components);
                }

                pub fn getComponents(self: *const ThisSubset, entity: Entity, comptime Components: type) error{MissingComponent}!Components {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const get_info = @typeInfo(Components);
                        get_validation_loop: for (get_info.Struct.fields) |field| {
                            const component_to_get = CompileReflect.compactComponentRequest(field.type);

                            for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                                if (component_to_get.type == InnerSubsetComp) {
                                    // If we found get component in subset, and it is access by value, then validation is OK
                                    if (component_to_get.attr == .value) {
                                        continue :get_validation_loop;
                                    }

                                    // Get by ptr, subset is registered to have ptr access, validation is OK
                                    const subset_access = CompileReflect.compactComponentRequest(SubsetComp);
                                    if (subset_access.attr == .ptr) {
                                        continue :get_validation_loop;
                                    }

                                    // Criteria above not met. Validation NOT OK
                                    @compileError(@src().fn_name ++ " called with ptr of " ++ @typeName(InnerSubsetComp) ++ ", subset " ++ simplifiedTypeName() ++ " only has value access");
                                }
                            }
                            @compileError(@src().fn_name ++ " requested " ++ @typeName(component_to_get.type) ++ " subset " ++ simplifiedTypeName() ++ " does not have this type");
                        }
                    }

                    return self.storage.getComponents(entity, Components);
                }

                pub fn getComponent(self: *const ThisSubset, entity: Entity, comptime Component: type) error{MissingComponent}!Component {
                    // Validate that the correct access was requested in subset type
                    comptime get_validation_blk: {
                        const component_to_get = CompileReflect.compactComponentRequest(Component);

                        for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                            if (component_to_get.type == InnerSubsetComp) {
                                // If we found get component in subset, and it is access by value, then validation is OK
                                if (component_to_get.attr == .value) {
                                    break :get_validation_blk;
                                }

                                // Get by ptr, subset is registered to have ptr access, validation is OK
                                const subset_access = CompileReflect.compactComponentRequest(SubsetComp);
                                if (subset_access.attr == .ptr) {
                                    break :get_validation_blk;
                                }

                                // Criteria above not met. Validation NOT OK
                                @compileError(@src().fn_name ++ " called with ptr of " ++ @typeName(InnerSubsetComp) ++ ", subset " ++ simplifiedTypeName() ++ " only has value access");
                            }
                        }
                        @compileError(@src().fn_name ++ " requested " ++ @typeName(component_to_get.type) ++ " subset " ++ simplifiedTypeName() ++ " does not have this type");
                    }

                    return self.storage.getComponent(entity, Component);
                }

                fn simplifiedTypeName() [:0]const u8 {
                    const type_name = @typeName(ThisSubset);
                    const start_index = std.mem.indexOf(u8, type_name, "Subset").?;
                    return type_name[start_index..];
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
        /// var living_iter = Storage.Query(struct{ entity: Entity, a: Health }, .{LivingTag} .{DeadTag}).submit(&storage);
        /// while (living_iter.next()) |item| {
        ///    std.debug.print("{d}", .{item.entity});
        ///    std.debug.print("{any}", .{item.a});
        /// }
        /// ```
        pub fn Query(comptime ResultItem: type, comptime include_types: anytype, comptime exclude_types: anytype) type {
            @setEvalBranchQuota(10000);

            // Start by reflecting on ResultItem type
            const result_type_info = @typeInfo(ResultItem);
            if (result_type_info != .Struct) {
                const error_message = std.fmt.comptimePrint("Query ResultItem '{s}' must be a struct of components", .{@typeName(ResultItem)});
                @compileError(error_message);
            }

            const fields = result_type_info.Struct.fields;
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
            if (include_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }
            const include_fields = include_type_info.Struct.fields;

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }
            const exclude_fields = exclude_type_info.Struct.fields;
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
                        if (request.attr == .ptr) {
                            const error_message = std.fmt.comptimePrint(
                                "Query include_type {s} cant be a pointer",
                                .{@typeName(request.type)},
                            );
                            @compileError(error_message);
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
                        if (request.attr == .ptr) {
                            const error_message = std.fmt.comptimePrint(
                                "Query include_type {s} cant be a pointer",
                                .{@typeName(request.type)},
                            );
                            @compileError(error_message);
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

                    pub fn submit(storage: *Storage) ThisQuery {
                        const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                        defer zone.End();

                        return ThisQuery{
                            .sparse_cursors = 0,
                            .storage_entity_count_ptr = &storage.number_of_entities,
                        };
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

                // TODO: this is horrible for cache, we should find the next N entities instead
                sparse_cursors: EntityId,
                storage_entity_count_ptr: *const std.atomic.Value(EntityId),

                full_set_search_order: [full_sparse_set_count]usize,
                full_sparse_sets: [full_sparse_set_count]*const set.Sparse.Full,

                tag_sparse_sets_bits: EntityId,
                tag_sparse_sets: [tag_sparse_set_count]*const set.Sparse.Tag,

                dense_sets: CompileReflect.GroupDenseSetsConstPtr(&query_components),

                pub fn submit(storage: *Storage) ThisQuery {
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

                        inline for (query_components, 0..) |QueryComp, q_index| {
                            if (@sizeOf(QueryComp) == 0) continue;

                            var skip_component: bool = false;
                            // Skip indices we already stored
                            already_included_loop: for (full_set_search_order[0..search_index]) |prev_found| {
                                if (prev_found == q_index) {
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
                                    const is_result_or_include_component = q_index < result_component_count + include_fields.len;
                                    if (is_result_or_include_component) {
                                        break :get_len_blk query_candidate_len;
                                    } else {
                                        break :get_len_blk number_of_entities - query_candidate_len;
                                    }
                                };

                                if (len_value <= current_min_value and len_value >= last_min_value) {
                                    current_index = q_index;
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

                pub fn next(self: *ThisQuery) ?ResultItem {
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
                            .ptr => @field(result, result_field.name) = component_ptr,
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

                fn indexOfComponentSparse(comptime Component: type) comptime_int {
                    for (query_components, 0..) |ComponentQ, comp_index| {
                        if (ComponentQ == Component) {
                            return comp_index;
                        }
                    }
                    @compileError(@typeName(Component) ++ " is not a component in Query");
                }
            };
        }

        /// Retrieve the dense set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getDenseSetConstPtr(storage: *const Storage, comptime Component: type) *const set.Dense(Component) {
            comptime std.debug.assert(@sizeOf(Component) > 0);
            return &@field(
                storage.dense_sets,
                @typeName(Component),
            );
        }

        /// Retrieve the dense set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getDenseSetPtr(storage: *Storage, comptime Component: type) *set.Dense(Component) {
            comptime std.debug.assert(@sizeOf(Component) > 0);
            return &@field(
                storage.dense_sets,
                @typeName(Component),
            );
        }

        /// Retrieve the sparse set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getSparseSetConstPtr(storage: *const Storage, comptime Component: type) *const set.Sparse.CompToSparseType(Component) {
            return &@field(
                storage.sparse_sets,
                @typeName(Component),
            );
        }

        /// Retrieve the sparse set for a component type.
        /// Mostly meant for internal usage. Be careful not to write to the set as this can
        /// lead to inconsistent storage state.
        pub fn getSparseSetPtr(storage: *Storage, comptime Component: type) *set.Sparse.CompToSparseType(Component) {
            return &@field(
                storage.sparse_sets,
                @typeName(Component),
            );
        }

        fn indexOfStorageComponent(comptime Component: type) usize {
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
        inline for (&struct_fields, components) |*field, Component| {
            const SparseSet = set.Sparse.CompToSparseType(Component);
            const default_value = SparseSet{};
            field.* = std.builtin.Type.StructField{
                .name = @typeName(Component),
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

    /// Generate the struct that will store our dense sets.
    pub fn GroupDenseSets(comptime components: []const type) type {
        comptime var non_zero_component_count = 0;
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (components) |Component| {
            if (@sizeOf(Component) == 0) {
                continue;
            }

            const DenseSet = set.Dense(Component);
            const default_value = DenseSet{};
            struct_fields[non_zero_component_count] = std.builtin.Type.StructField{
                .name = @typeName(Component),
                .type = DenseSet,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(DenseSet),
            };

            non_zero_component_count += 1;
        }
        const group_type = std.builtin.Type{ .Struct = .{
            .layout = .auto,
            .fields = struct_fields[0..non_zero_component_count],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } };
        return @Type(group_type);
    }

    pub fn GroupDenseSetsConstPtr(comptime components: []const type) type {
        comptime var non_zero_component_count = 0;
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (components) |Component| {
            if (@sizeOf(Component) == 0) {
                continue;
            }

            const DenseSet = set.Dense(Component);
            struct_fields[non_zero_component_count] = std.builtin.Type.StructField{
                .name = @typeName(Component),
                .type = *const DenseSet,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(*DenseSet),
            };

            non_zero_component_count += 1;
        }
        const group_type = std.builtin.Type{ .Struct = .{
            .layout = .auto,
            .fields = struct_fields[0..non_zero_component_count],
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

            const compo_field_info = @typeInfo(components[component_index]);
            if (compo_field_info != .Struct and compo_field_info != .Pointer) {
                @compileError("component types must be a struct or pointer, field '" ++ field.name ++ "' was '" ++ @typeName(components[component_index]));
            }

            field_type.* = components[component_index];
        }

        return field_types;
    }

    fn verifyInnerTypesIsInSlice(
        comptime fmt_error_message: []const u8,
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

            @compileError(@typeName(InnerType) ++ fmt_error_message);
        }
    }
};

const Testing = @import("Testing.zig");
const testing = std.testing;

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;

const StorageStub = Testing.StorageStub;
const Queries = Testing.Queries;

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

    storage.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));

    try testing.expectEqual(true, storage.hasComponents(entity, .{Testing.Component.B}));

    storage.unsetComponents(entity, .{Testing.Component.B});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.B}));
}

test "unsetComponents() removes all components from entity" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{Testing.Component.A{}});

    storage.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));
}

test "unsetComponents() removes multiple components" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const initial_state = Testing.Structure.ABC{};
    const entity = try storage.createEntity(initial_state);

    storage.unsetComponents(entity, .{ Testing.Component.A, Testing.Component.C });

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

test "storage with 0 size component is valid" {
    const ZeroComp = struct {};
    var storage = try CreateStorage(.{ZeroComp}).init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    try testing.expectEqual(false, storage.hasComponents(entity, .{ZeroComp}));

    try storage.setComponents(entity, .{ZeroComp{}});
    try testing.expectEqual(true, storage.hasComponents(entity, .{ZeroComp}));

    _ = try storage.getComponents(entity, struct { z: ZeroComp });
    storage.unsetComponents(entity, .{ZeroComp});
    try testing.expectEqual(false, storage.hasComponents(entity, .{ZeroComp}));
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

    const Subset = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });
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

    const Subset = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });
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

    const Subset = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });
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

    const Subset = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });
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

    storage_subset.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage_subset.hasComponents(entity, .{Testing.Component.A}));

    try testing.expectEqual(true, storage_subset.hasComponents(entity, .{Testing.Component.B}));

    storage_subset.unsetComponents(entity, .{Testing.Component.B});
    try testing.expectEqual(false, storage_subset.hasComponents(entity, .{Testing.Component.B}));
}

test "Subset read only getComponent(s)" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Subset = StorageStub.Subset(.{
        Testing.Component.A,
        Testing.Component.B,
    });
    const storage_subset = Subset{
        .storage = &storage,
    };

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(iter) },
            Testing.Component.B{ .value = @intCast(iter) },
        });
    }

    for (entities, 0..) |entity, iter| {
        const b = try storage_subset.getComponent(entity, Testing.Component.B);

        try testing.expectEqual(
            Testing.Component.B{ .value = @intCast(iter) },
            b,
        );
    }

    for (entities, 0..) |entity, iter| {
        const ab = try storage_subset.getComponents(entity, Testing.Structure.AB);

        try testing.expectEqual(
            Testing.Component.A{ .value = @intCast(iter) },
            ab.a,
        );
        try testing.expectEqual(
            Testing.Component.B{ .value = @intCast(iter) },
            ab.b,
        );
    }
}

test "query with single result component type works" {
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
        var a_iter = Queries.ReadA.submit(&storage);

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
        var a_iter = Queries.ReadA.submit(&storage);

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
        var a_iter = Queries.ReadA.submit(&storage);

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

    {
        var a_b_iter = Queries.ReadAReadB.submit(&storage);

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

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = Queries.WriteA.submit(&storage);

        while (a_iter.next()) |item| {
            item.a.value += 1;
            index += 1;
        }
    }

    {
        var index: usize = 1;
        var a_iter = Queries.ReadA.submit(&storage);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
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

    {
        var iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
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

    {
        var iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
            .{ Testing.Component.B, Testing.Component.C },
        ).submit(&storage);

        const expected_order = [_]usize{ 1, 0 };
        try std.testing.expectEqualSlices(usize, &expected_order, &iter.full_set_search_order);

        var index: usize = 200;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single result component, single include and single (tag component) exclude works" {
    // Issue found in Wizard Rampage project https://github.com/Avokadoen/wizard_rampage while prototyping in it

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

    {
        var iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{Testing.Component.B},
            .{Testing.Component.C},
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
            .{},
        ).submit(&storage);

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
        // Test with entity as first argument
        var iter = StorageStub.Query(
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{},
            .{Testing.Component.B},
        ).submit(&storage);

        const expected_order = [_]usize{ 1, 0 };
        try std.testing.expectEqualSlices(usize, &expected_order, &iter.full_set_search_order);

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

    {
        // Test with entity as second argument
        var iter = StorageStub.Query(
            struct {
                a: Testing.Component.A,
                entity: Entity,
            },
            .{},
            .{Testing.Component.B},
        ).submit(&storage);

        const expected_order = [_]usize{ 1, 0 };
        try std.testing.expectEqualSlices(usize, &expected_order, &iter.full_set_search_order);

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

    {
        // Test with entity as "sandwiched" between A and B
        var iter = StorageStub.Query(
            struct {
                a: Testing.Component.A,
                entity: Entity,
                b: Testing.Component.B,
            },
            .{},
            .{},
        ).submit(&storage);

        const expected_order = [_]usize{ 1, 0 };
        try std.testing.expectEqualSlices(usize, &expected_order, &iter.full_set_search_order);

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

test "query wuth include field works" {
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
            .{},
        ).submit(&storage);

        const expected_order = [_]usize{ 1, 0 };
        try std.testing.expectEqualSlices(usize, &expected_order, &iter.full_set_search_order);

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

    storage.unsetComponents(entity, .{Position});

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
        .{},
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
