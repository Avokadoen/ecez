const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Color = @import("misc.zig").Color;
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const set = @import("sparse_set.zig");
const Testing = @import("Testing.zig");
const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;
const StorageStub = Testing.StorageStub;
const ztracy = @import("ecez_ztracy.zig");

pub const StorageType = struct {};
pub const SubsetType = struct {};

pub fn CreateStorage(comptime all_components: anytype) type {
    return struct {
        pub const EcezType = StorageType;

        // a flat array of the type of each field in the components tuple
        pub const component_type_array = CompileReflect.verifyComponentTuple(all_components);

        pub const AllComponentWriteAccess = CompileReflect.AllWriteAccessType(&component_type_array){};
        pub const GroupDenseSets = CompileReflect.GroupDenseSets(&component_type_array);
        pub const GroupSparseSets = CompileReflect.GroupSparseSets(&component_type_array);

        const Storage = @This();

        allocator: Allocator,

        sparse_sets: GroupSparseSets,
        dense_sets: GroupDenseSets,

        created_entity_count: std.atomic.Value(entity_type.EntityId) = .{ .raw = 0 },

        inactive_entity_lock: std.Thread.Mutex = .{},
        inactive_entities: std.ArrayListUnmanaged(entity_type.EntityId) = .empty,

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

            // deinit all dense sets
            inline for (component_type_array) |Component| {
                // only sized components has dense sets
                if (@sizeOf(Component) > 0) {
                    const dense_set = self.getDenseSetPtr(Component);
                    dense_set.deinit(self.allocator);
                }
            }

            // deinit all sparse sets
            inline for (component_type_array) |Component| {
                const sparse_set = self.getSparseSetPtr(Component);
                sparse_set.deinit(self.allocator);
            }

            self.inactive_entities.deinit(self.allocator);
        }

        /// Clear storage memory for reuse. **All entities will become invalid**.
        pub fn clearRetainingCapacity(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // Clear entity counters
            self.created_entity_count.store(0, .seq_cst);
            self.inactive_entities.clearRetainingCapacity();

            // clear all dense sets
            inline for (component_type_array) |Component| {
                // only sized components has dense sets
                if (@sizeOf(Component) > 0) {
                    const dense_set = self.getDenseSetPtr(Component);
                    dense_set.clearRetainingCapacity();
                }
            }

            // clear all sparse sets
            inline for (component_type_array) |Component| {
                const sparse_set = self.getSparseSetPtr(Component);
                sparse_set.clearRetainingCapacity();
            }
        }

        /// Create an entity and returns the entity handle
        ///
        /// Parameters:
        ///
        ///     - entity_state: the components that the new entity should be assigned
        ///
        /// Example:
        /// ```
        ///    const new_entity = try storage.createEntity(.{
        ///         Component.A{ .value = 42 },
        ///         Component.B{},
        ///    });
        /// ```
        ///
        pub fn createEntity(self: *Storage, entity_state: anytype) error{OutOfMemory}!Entity {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            try self.ensureUnusedCapacity(@TypeOf(entity_state), 1);

            return self.createEntityAssumeCapacity(entity_state);
        }

        /// Create entity and assume storage has sufficient capacity
        ///
        /// Parameters:
        ///
        ///     - entity_state: the components that the new entity should be assigned
        ///
        /// Example:
        /// ```
        ///     try storage.ensureUnusedCapacity(.{Component.A, Component.B}, 200);
        ///     for (abs[0..200]) |ab| {
        ///         const entity = storage.createEntityAssumeCapacity(ab);
        ///         _ = entity;
        ///     }
        /// ```
        ///
        pub fn createEntityAssumeCapacity(self: *Storage, entity_state: anytype) Entity {
            const this_id = get_id_blk: {
                if (self.inactive_entities.items.len > 0) {
                    @branchHint(.unlikely);

                    self.inactive_entity_lock.lock();
                    defer self.inactive_entity_lock.unlock();

                    if (self.inactive_entities.pop()) |inactive| {
                        @branchHint(.likely);
                        break :get_id_blk inactive;
                    }
                }

                break :get_id_blk self.created_entity_count.fetchAdd(1, .acq_rel);
            };

            const EntityState = @TypeOf(entity_state);
            const field_info = @typeInfo(EntityState);

            // For each component in the new entity
            inline for (field_info.@"struct".fields) |field| {
                const Component = field.type;
                const component: Component = @field(
                    entity_state,
                    field.name,
                );

                // Grow component sparse set storage
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

        /// Destroy a given entity and its components
        ///
        /// The function can fail as the entity will be cached for reuse (which may OOM)
        pub fn destroyEntity(self: *Storage, entity: Entity) error{OutOfMemory}!void {
            {
                self.inactive_entity_lock.lock();
                defer self.inactive_entity_lock.unlock();

                try self.inactive_entities.append(self.allocator, entity.id);
            }

            self.unsetComponents(entity, all_components);
        }

        /// Ensure any sparse and dense sets related to the components in EntityState have sufficient space for additional_count
        pub fn ensureUnusedCapacity(self: *Storage, comptime EntityState: type, additional_count: entity_type.EntityId) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                EntityState,
            );

            if (additional_count == 0) {
                return;
            }

            // This will "leak" a handle if grow fails, but if it fails, then the app has more issues anyways.
            const this_id = self.created_entity_count.load(.monotonic);

            // Ensure capacity first to avoid errdefer
            const field_info = @typeInfo(EntityState);
            inline for (field_info.@"struct".fields) |field| {
                const Component = field.type;

                // Grow sparse set
                {
                    var sparse_set = self.getSparseSetPtr(Component);
                    try sparse_set.grow(self.allocator, this_id + additional_count);
                }

                // Grow dense set if present
                if (@sizeOf(Component) > 0) {
                    var dense_set = self.getDenseSetPtr(Component);
                    try dense_set.grow(self.allocator, dense_set.dense_len + additional_count);
                }
            }
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
        ///
        /// Example:
        /// ```
        ///     try storage.setComponents(my_entity, .{
        ///         Component.A{ .value = 50 },
        ///         Component.B{ .value = 50 },
        ///     });
        /// ```
        ///
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
            inline for (field_info.@"struct".fields) |field| {
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

            inline for (field_info.@"struct".fields) |field| {
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
        ///
        /// Hazards:
        ///
        ///     It's undefined behaviour to call unsetComponents, then read a stale query result (returned from Query.next) item pointer field.
        ///     The same is true for returned getComponent(s) that are pointers. Be sure to call unsetComponents AFTER any component pointer access.
        ///
        /// Example:
        /// ```
        ///     storage.unsetComponents(my_entity, .{Component.A, Component.B});
        /// ```
        ///
        pub fn unsetComponents(self: *Storage, entity: Entity, comptime struct_of_remove_components: anytype) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                struct_of_remove_components,
            );

            const field_info = @typeInfo(@TypeOf(struct_of_remove_components));
            inline for (field_info.@"struct".fields) |field| {
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
        ///
        /// Example:
        /// ```
        ///     if(storage.hasComponents(my_entity, .{Component.A})) {
        ///         print("my_entity has A", .{});
        ///     }
        ///
        /// ```
        pub fn hasComponents(self: Storage, entity: Entity, comptime components: anytype) bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                components,
            );

            const field_info = @typeInfo(@TypeOf(components));

            inline for (field_info.@"struct".fields) |field| {
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
        ///     it's undefined behaviour to read component pointers after a call to setComponents or other state mutating functions with the same component type,
        ///     even if it's not on the same entity.
        ///
        /// Example:
        /// ```
        ///     const a_b_c = try storage.getComponents(my_entity, .{
        ///         a: *Component.A,        // we can mutate a
        ///         b: Component.B,         // b is read only
        ///         c: *const Component.C   // c is read only
        ///     });
        ///
        ///     a_b_c.a.value = 51;
        /// ```
        ///
        pub fn getComponents(self: *const Storage, entity: Entity, comptime Components: type) ?Components {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            comptime CompileReflect.verifyInnerTypesIsInSlice(
                " is not part of storage components",
                &component_type_array,
                Components,
            );

            var result: Components = undefined;
            const field_info = @typeInfo(Components);
            if (field_info != .@"struct") {
                @compileError(@src().fn_name ++ " expect Components type arg to be a struct of components");
            }

            inline for (field_info.@"struct".fields) |field| {
                const component_to_get = CompileReflect.compactComponentRequest(field.type);

                const sparse_set = self.getSparseSetConstPtr(component_to_get.type);
                if (@sizeOf(component_to_get.type) > 0) {
                    const dense_set = self.getDenseSetConstPtr(component_to_get.type);

                    const get_ptr = set.get(
                        sparse_set,
                        dense_set,
                        entity.id,
                    ) orelse return null;
                    switch (component_to_get.attr) {
                        .ptr, .const_ptr => @field(result, field.name) = get_ptr,
                        .value => @field(result, field.name) = get_ptr.*,
                    }
                } else {
                    comptime {
                        switch (component_to_get.attr) {
                            .ptr, .const_ptr => {
                                const error_message = std.fmt.comptimePrint("field '{s}' is a pointer to zero sized component which is illegal", .{field.name});
                                @compileError(error_message);
                            },
                            .value => {},
                        }
                    }

                    if (sparse_set.isSet(entity.id) == false) {
                        return null;
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
        ///     it's undefined behaviour to read component pointers after a call to setComponents or other state mutating functions with the same component type,
        ///     even if it's not on the same entity.
        ///
        /// Example:
        /// ```
        ///     const a = storage.getComponent(my_entity, Component.A).?;
        ///     const b = storage.getComponent(my_entity, *Component.B).?;
        ///     const c = storage.getComponent(my_entity, *const Component.C).?;
        /// ```
        pub fn getComponent(self: *const Storage, entity: Entity, comptime Component: type) ?Component {
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
            ) orelse return null;
            switch (component_to_get.attr) {
                .ptr, .const_ptr => return get_ptr,
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
        ///
        /// Example:
        /// ```
        ///     const StorageSubset = Storage.Subset(
        ///         .{
        ///             *Component.A, // Request A by pointer access (subset has write and read access for this type)
        ///             Component.B, // Request B by value only (subset has read only access for this type)
        ///         },
        ///     );
        /// ```
        pub fn Subset(comptime component_subset: anytype) type {

            // Check if tuple is valid and get array of types instead if valid
            const comp_types = CompileReflect.verifyComponentTuple(component_subset);
            const inner_comp_types = get_inner_blk: {
                var inner: [comp_types.len]type = undefined;
                for (&inner, comp_types) |*Inner, CompType| {
                    const component_request = CompileReflect.compactComponentRequest(CompType);
                    if (component_request.attr == .const_ptr) {
                        // It does not make sense to express a const ptr for a subset type (you can still use it when retrieving a component)
                        @compileError("Subset with const ptr to '" ++ @typeName(component_request.type) ++ "' is not legal, must be either pointer or value when creating a Subset type");
                    }

                    Inner.* = component_request.type;
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

                        // Look up each component in the new entity and verify that each component is registered as write access
                        get_validation_loop: for (entity_state_info.@"struct".fields) |field| {
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

                /// Destroy entity and all components
                /// destroyEntity require subset of `Storage.Subset(Storage.AllComponentWriteAccess)`
                pub fn destroyEntity(self: *ThisSubset, entity: Entity) error{OutOfMemory}!void {
                    if (@TypeOf(component_subset) != @TypeOf(AllComponentWriteAccess)) {
                        @compileError("destroyEntity require subset of `Storage.Subset(Storage.AllComponentWriteAccess)`");
                    }

                    return self.storage.destroyEntity(entity);
                }

                pub fn setComponents(self: *const ThisSubset, entity: Entity, struct_of_components: anytype) error{OutOfMemory}!void {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const set_info = @typeInfo(@TypeOf(struct_of_components));

                        // Look up each component in the new entity and verify that each component is registered as write access
                        get_validation_loop: for (set_info.@"struct".fields) |field| {
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

                        // Look up each component in the new entity and verify that each component is registered as write access
                        get_validation_loop: for (unset_info.@"struct".fields) |field| {
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

                pub fn getComponents(self: *const ThisSubset, entity: Entity, comptime Components: type) ?Components {
                    // Validate that the correct access was requested in subset type
                    comptime {
                        const get_info = @typeInfo(Components);
                        get_validation_loop: for (get_info.@"struct".fields) |field| {
                            const component_to_get = CompileReflect.compactComponentRequest(field.type);

                            for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                                if (component_to_get.type == InnerSubsetComp) {
                                    // If we found get component in subset, and it is access read-only, then validation is OK
                                    switch (component_to_get.attr) {
                                        .value, .const_ptr => continue :get_validation_loop,
                                        .ptr => {},
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

                pub fn getComponent(self: *const ThisSubset, entity: Entity, comptime Component: type) ?Component {
                    // Validate that the correct access was requested in subset type
                    comptime get_validation_blk: {
                        const component_to_get = CompileReflect.compactComponentRequest(Component);

                        for (inner_comp_types, comp_types) |InnerSubsetComp, SubsetComp| {
                            if (component_to_get.type == InnerSubsetComp) {
                                // If we found get component in subset, and it is access read-only, then validation is OK
                                switch (component_to_get.attr) {
                                    .value, .const_ptr => break :get_validation_blk,
                                    .ptr => {},
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
    };
}

pub const CompileReflect = struct {
    pub const CompactComponentRequest = struct {
        pub const Attr = enum {
            value,
            ptr,
            const_ptr,
        };

        type: type,
        attr: Attr,
    };
    pub fn compactComponentRequest(comptime ComponentPtrOrValueType: type) CompactComponentRequest {
        const type_info = @typeInfo(ComponentPtrOrValueType);

        return switch (type_info) {
            .@"struct", .@"union", .@"enum" => .{
                .type = ComponentPtrOrValueType,
                .attr = .value,
            },
            .pointer => |ptr_info| .{
                .type = ptr_info.child,
                .attr = if (ptr_info.is_const) .const_ptr else .ptr,
            },
            else => @compileError(@typeName(ComponentPtrOrValueType) ++ " is not pointer, nor a struct."),
        };
    }

    pub fn GroupSparseSets(comptime components: []const type) type {
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (&struct_fields, components) |*field, Component| {
            const SparseSet = set.Sparse.CompToSparseType(Component);
            const default_value: SparseSet = .empty;
            field.* = std.builtin.Type.StructField{
                .name = @typeName(Component),
                .type = SparseSet,
                .default_value_ptr = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(SparseSet),
            };
        }
        const group_type = std.builtin.Type{ .@"struct" = .{
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
            const default_value: DenseSet = .empty;
            struct_fields[non_zero_component_count] = std.builtin.Type.StructField{
                .name = @typeName(Component),
                .type = DenseSet,
                .default_value_ptr = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf(DenseSet),
            };

            non_zero_component_count += 1;
        }
        const group_type = std.builtin.Type{ .@"struct" = .{
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
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(*DenseSet),
            };

            non_zero_component_count += 1;
        }
        const group_type = std.builtin.Type{ .@"struct" = .{
            .layout = .auto,
            .fields = struct_fields[0..non_zero_component_count],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } };
        return @Type(group_type);
    }

    /// Generate a tuple containing all component types as pointers
    pub fn AllWriteAccessType(comptime components: []const type) type {
        var struct_fields: [components.len]std.builtin.Type.StructField = undefined;
        inline for (&struct_fields, components, 0..) |*struct_field, Component, index| {
            const TypeValue = *compactComponentRequest(Component).type;
            struct_field.* = std.builtin.Type.StructField{
                .name = std.fmt.comptimePrint("{d}", .{index}),
                .type = type,
                .default_value_ptr = @ptrCast(&TypeValue),
                .is_comptime = true,
                .alignment = @alignOf(type),
            };
        }
        const group_type = std.builtin.Type{ .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        } };
        return @Type(group_type);
    }

    /// Produce a flat array of component types if the 'components' tuple is valid
    fn verifyComponentTuple(comptime components: anytype) return_type_blk: {
        const components_info = @typeInfo(@TypeOf(components));
        if (components_info != .@"struct") {
            @compileError("components was not a tuple of types");
        }

        break :return_type_blk [components_info.@"struct".fields.len]type;
    } {
        const components_info = @typeInfo(@TypeOf(components));
        var field_types: [components_info.@"struct".fields.len]type = undefined;
        for (&field_types, components_info.@"struct".fields, 0..) |*field_type, field, component_index| {
            if (@typeInfo(field.type) != .type) {
                @compileError("components must be a struct of types, field '" ++ field.name ++ "' was " ++ @typeName(field.type));
            }

            const compo_field_info = @typeInfo(components[component_index]);
            switch (compo_field_info) {
                .@"struct", .pointer, .@"union", .@"enum" => {},
                else => {
                    @compileError("component types must be a struct or pointer, field '" ++ field.name ++ "' was '" ++ @typeName(components[component_index]));
                },
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
        field_loop: for (type_tuple_info.@"struct".fields) |field| {
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
        try testing.expectEqual(a, storage.getComponent(entity, Testing.Component.A).?);
    }

    const b = Testing.Component.B{ .value = 8 };
    {
        try storage.setComponents(entity, .{b});
        const comps = storage.getComponents(entity, AbEntityType).?;
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

    const comps = storage.getComponents(entity1, AbEntityType).?;
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

    const stored_a = storage.getComponent(entity, Testing.Component.A).?;
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

    const stored = storage.getComponents(entity, AbEntityType).?;
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "ensureUnusedCapacity + createEntityAssumeCapacity works" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const create_count = 129;
    var entities: [create_count]Entity = undefined;

    try storage.ensureUnusedCapacity(Testing.Structure.ABC, create_count);
    for (&entities, 0..) |*entity, create_index| {
        entity.* = storage.createEntityAssumeCapacity(Testing.Structure.ABC{
            .a = Testing.Component.A{ .value = @intCast(create_index) },
            .b = Testing.Component.B{ .value = @intCast(create_index) },
            .c = .{},
        });
    }

    for (&entities, 0..) |entity, create_index| {
        const expected_a = Testing.Component.A{ .value = @intCast(create_index) };
        const expected_b = Testing.Component.B{ .value = @intCast(create_index) };

        const stored = storage.getComponents(entity, AbEntityType).?;
        try testing.expectEqual(expected_a, stored.a);
        try testing.expectEqual(expected_b, stored.b);
    }
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
    storage.unsetComponents(entity, .{Testing.Component.A});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.A}));
}

test "unsetComponents() none-existing sized and zero sized type works" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});

    storage.unsetComponents(entity, .{Testing.Component.A});
    storage.unsetComponents(entity, .{Testing.Component.C});
    try testing.expectEqual(false, storage.hasComponents(entity, .{Testing.Component.C}));
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

test "unsetComponents() removes component 0 in dense storage with no neighbour corruption" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const entity_0 = try storage.createEntity(.{Testing.Component.A{}});
    const entity_1 = try storage.createEntity(.{Testing.Component.A{}});
    const entity_2 = try storage.createEntity(.{Testing.Component.B{}});
    const entity_3 = try storage.createEntity(.{Testing.Component.B{}});

    storage.unsetComponents(entity_2, .{Testing.Component.B});
    storage.unsetComponents(entity_3, .{Testing.Component.B});

    try testing.expectEqual(true, storage.hasComponents(entity_0, .{Testing.Component.A}));
    try testing.expectEqual(false, storage.hasComponents(entity_0, .{Testing.Component.B}));

    try testing.expectEqual(true, storage.hasComponents(entity_1, .{Testing.Component.A}));
    try testing.expectEqual(false, storage.hasComponents(entity_1, .{Testing.Component.B}));

    try testing.expectEqual(false, storage.hasComponents(entity_2, .{Testing.Component.A}));
    try testing.expectEqual(false, storage.hasComponents(entity_2, .{Testing.Component.B}));

    try testing.expectEqual(false, storage.hasComponents(entity_3, .{Testing.Component.A}));
    try testing.expectEqual(false, storage.hasComponents(entity_3, .{Testing.Component.B}));
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

    const stored = storage.getComponents(entity, AbEntityType).?;
    try testing.expectEqual(new_a, stored.a);
    try testing.expectEqual(new_b, stored.b);
}

test "storage with 0 size component is valid" {
    const ZeroComp = struct {};
    var storage = try CreateStorage(.{ZeroComp}).init(testing.allocator);
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    try testing.expectEqual(false, storage.hasComponents(entity, .{ZeroComp}));

    try storage.setComponents(entity, .{ZeroComp{}});
    try testing.expectEqual(true, storage.hasComponents(entity, .{ZeroComp}));

    _ = storage.getComponents(entity, struct { z: ZeroComp }).?;
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

    try testing.expectEqual(
        entity_initial_state,
        storage.getComponents(entity, AbEntityType).?,
    );
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
    const ab_ptr = storage.getComponents(entity, MutableAB).?;
    try testing.expectEqual(initial_state.a, ab_ptr.a.*);
    try testing.expectEqual(initial_state.b, ab_ptr.b.*);

    const new_a_value = Testing.Component.A{ .value = 42 };
    const new_b_value = Testing.Component.B{ .value = 99 };

    // mutate a value ptr
    ab_ptr.a.* = new_a_value;
    ab_ptr.b.* = new_b_value;

    const stored_components = storage.getComponents(entity, AbEntityType).?;
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

    try testing.expectEqual(
        entity_initial_state.a,
        storage.getComponent(entity, Testing.Component.A).?,
    );
    try testing.expectEqual(
        entity_initial_state.b,
        storage.getComponent(entity, Testing.Component.B).?,
    );
}

test "getComponent() with const ptr retrieve component" {
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

    try testing.expectEqual(
        entity_initial_state.a,
        storage.getComponent(entity, *const Testing.Component.A).?.*,
    );
    try testing.expectEqual(
        entity_initial_state.b,
        storage.getComponent(entity, *const Testing.Component.B).?.*,
    );
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
    const ab_ptr = storage.getComponents(entity, MutableAB).?;
    try testing.expectEqual(initial_state.a, ab_ptr.a.*);
    try testing.expectEqual(initial_state.b, ab_ptr.b.*);

    const new_a_value = Testing.Component.A{ .value = 42 };
    const new_b_value = Testing.Component.B{ .value = 99 };

    // mutate a value ptr
    ab_ptr.a.* = new_a_value;
    ab_ptr.b.* = new_b_value;

    try testing.expectEqual(new_a_value, storage.getComponent(entity, Testing.Component.A).?);
    try testing.expectEqual(new_b_value, storage.getComponent(entity, Testing.Component.B).?);
}

test "getComponent() can request const ptr" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const a = Testing.Component.A{ .value = 32 };
    const b = Testing.Component.B{ .value = 42 };
    const initial_state = AbEntityType{
        .a = a,
        .b = b,
    };
    const entity = try storage.createEntity(initial_state);

    const stored_a = storage.getComponent(entity, *const Testing.Component.A).?;
    try testing.expectEqual(a, stored_a.*);
}

test "getComponents() can request const ptr" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const a = Testing.Component.A{ .value = 32 };
    const b = Testing.Component.B{ .value = 42 };
    const initial_state = AbEntityType{
        .a = a,
        .b = b,
    };
    const entity = try storage.createEntity(initial_state);

    const stored = storage.getComponents(entity, struct {
        a: *const Testing.Component.A,
        b: *const Testing.Component.B,
    }).?;
    try testing.expectEqual(a, stored.a.*);
    try testing.expectEqual(b, stored.b.*);
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
    const comp_a = storage.getComponent(entity, Testing.Component.A).?;
    try testing.expectEqual(Testing.Component.A{ .value = initial_value }, comp_a);
}

test "destroyEntity() destroys entity, and create reuse destroyed" {
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, index| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(index) },
            Testing.Component.B{ .value = @intCast(index) },
            Testing.Component.D.two,
            Testing.Component.E{ .two = @intCast(index) },
        });
    }

    for (entities[90..]) |entity| {
        try storage.destroyEntity(entity);
    }

    const reuse_value = 255;
    for (entities[90..]) |*entity| {
        entity.* = try storage.createEntity(.{
            Testing.Component.A{ .value = @intCast(reuse_value) },
            Testing.Component.B{ .value = @intCast(reuse_value) },
            Testing.Component.D.two,
            Testing.Component.E{ .two = @intCast(reuse_value) },
        });
    }

    for (&entities, 0..) |entity, index| {
        const expect_value = if (index < 90) index else reuse_value;
        try testing.expect(entity.id < 100);
        try testing.expectEqual(
            Testing.Component.A{ .value = @intCast(expect_value) },
            storage.getComponent(entity, Testing.Component.A).?,
        );
        try testing.expectEqual(
            Testing.Component.B{ .value = @intCast(expect_value) },
            storage.getComponent(entity, Testing.Component.B).?,
        );
        try testing.expectEqual(
            Testing.Component.D.two,
            storage.getComponent(entity, Testing.Component.D).?,
        );
        try testing.expectEqual(
            Testing.Component.E{ .two = @intCast(expect_value) },
            storage.getComponent(entity, Testing.Component.E).?,
        );
    }
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

    const stored = storage_subset.getComponents(entity, AbEntityType).?;
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

    const stored = storage_subset.getComponents(entity, AbEntityType).?;
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

    const stored = storage.getComponents(entity, AbEntityType).?;
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
        const b = storage_subset.getComponent(entity, Testing.Component.B).?;

        try testing.expectEqual(
            Testing.Component.B{ .value = @intCast(iter) },
            b,
        );
    }

    for (entities, 0..) |entity, iter| {
        const ab = storage_subset.getComponents(entity, Testing.Structure.AB).?;

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
        storage.getComponents(entity, Obj).?.o,
    );

    const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
    try storage.setComponents(entity, .{instance});

    try testing.expectEqual(
        obj,
        storage.getComponents(entity, Obj).?.o,
    );
    const Inst = struct { i: Editor.InstanceHandle };
    try testing.expectEqual(
        instance,
        storage.getComponents(entity, Inst).?.i,
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

        const comps = storage.getComponents(entity, struct { o: RenderContext.ObjectMetadata, i: Editor.InstanceHandle }).?;
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

        const comps = storage.getComponents(entity, struct { o: RenderContext.ObjectMetadata, i: Editor.InstanceHandle }).?;
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
        const actual_state = storage.getComponents(entity, SceneObject).?;
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
        const actual_state = storage.getComponents(entity, SceneObjectNoPos).?;
        try testing.expectEqual(transform, actual_state.transform);
        try testing.expectEqual(rotation, actual_state.rotation);
        try testing.expectEqual(scale, actual_state.scale);
        try testing.expectEqual(instance_handle, actual_state.instance_handle);
    }
}
