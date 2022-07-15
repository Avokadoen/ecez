const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ztracy = @import("ztracy");

const SystemMetadata = @import("SystemMetadata.zig");
const ArcheTree = @import("ArcheTree.zig");
const Archetype = @import("Archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const query = @import("query.zig");
const Color = @import("misc.zig").Color;

/// Create a ecs instance. Systems are initially included into the World.
/// Parameters:
///     - systems: a tuple consisting of each system used by the world each frame
pub fn CreateWorld(comptime systems: anytype) type {
    const SystemsType = @TypeOf(systems);
    const systems_info = @typeInfo(SystemsType);
    if (systems_info != .Struct) {
        @compileError("CreateWorld expected tuple or struct argument, found " ++ @typeName(SystemsType));
    }

    const fields_info = systems_info.Struct.fields;
    @setEvalBranchQuota(10_000);
    comptime var systems_count = 0;
    // start by counting systems registered
    inline for (fields_info) |field_info, i| {
        switch (@typeInfo(field_info.field_type)) {
            .Fn => systems_count += 1,
            .Type => {
                switch (@typeInfo(systems[i])) {
                    .Struct => |stru| {
                        inline for (stru.decls) |decl| {
                            const DeclType = @TypeOf(@field(systems[i], decl.name));
                            switch (@typeInfo(DeclType)) {
                                .Fn => systems_count += 1,
                                else => {
                                    const err_msg = std.fmt.comptimePrint("CreateWorld expected type of functions, got member {s}", .{
                                        @typeName(DeclType),
                                    });
                                    @compileError(err_msg);
                                },
                            }
                        }
                    },
                    else => {
                        const err_msg = std.fmt.comptimePrint("CreateWorld expected struct type, got {s}", .{
                            @typeInfo(systems[i]),
                        });
                        @compileError(err_msg);
                    },
                }
            },
            else => {
                const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct, got {s}", .{
                    @typeName(field_info.field_type),
                });
                @compileError(err_msg);
            },
        }
    }

    // extrapolate system information from functions registrerd
    comptime var systems_metadata: [systems_count]SystemMetadata = undefined;
    // extrapolate system count in embedded structs
    comptime var system_functions: [systems_count]*const anyopaque = undefined;
    {
        comptime var i: usize = 0;
        inline for (fields_info) |field_info, j| {
            switch (@typeInfo(field_info.field_type)) {
                .Fn => |func| {
                    systems_metadata[i] = SystemMetadata.init(field_info.field_type, func);
                    system_functions[i] = field_info.default_value.?;
                    i += 1;
                },
                .Type => {
                    switch (@typeInfo(systems[j])) {
                        .Struct => |stru| {
                            inline for (stru.decls) |decl| {
                                const function = @field(systems[j], decl.name);
                                const DeclType = @TypeOf(function);
                                const decl_info = @typeInfo(DeclType);
                                switch (decl_info) {
                                    .Fn => |func| {
                                        // const err_msg = std.fmt.comptimePrint("{d}", .{func.args.len});
                                        // @compileError(err_msg);
                                        systems_metadata[i] = SystemMetadata.init(DeclType, func);
                                        system_functions[i] = &function;
                                        i += 1;
                                    },
                                    else => {
                                        const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                            @typeName(DeclType),
                                        });
                                        @compileError(err_msg);
                                    },
                                }
                            }
                        },
                        else => {
                            const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                @typeName(field_info.field_type),
                            });
                            @compileError(err_msg);
                        },
                    }
                },
                else => unreachable,
            }
        }
    }

    return struct {
        pub const SystemArchetypes = struct {
            valid: bool,
            archetypes: [systems_count][]*Archetype,
        };

        // TODO: Bump allocate data (instead of calling append)
        // TODO: Thread safety
        const World = @This();
        allocator: Allocator,

        // maps entity id with indices of the storage
        entity_references: std.ArrayList(EntityRef),
        archetree: ArcheTree,

        // Cached archetypes used by each system
        system_archetypes: SystemArchetypes,

        pub fn init(allocator: Allocator) !World {
            const zone = ztracy.ZoneNC(@src(), "World init", Color.world);
            defer zone.End();

            const archetree = try ArcheTree.init(allocator);
            errdefer archetree.deinit();

            var system_archetypes: SystemArchetypes = .{
                .valid = false,
                .archetypes = undefined,
            };

            return World{
                .allocator = allocator,
                .entity_references = std.ArrayList(EntityRef).init(allocator),
                .archetree = archetree,
                .system_archetypes = system_archetypes,
            };
        }

        pub fn deinit(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World deinit", Color.world);
            defer zone.End();

            self.entity_references.deinit();
            self.archetree.deinit();

            if (self.system_archetypes.valid) {
                inline for (systems_metadata) |_, i| {
                    self.allocator.free(self.system_archetypes.archetypes[i]);
                }
            }
        }

        /// Create an empty entity and returns the entity handle.
        /// Consider using buildEntity for a faster entity construction if you have
        /// compile-time entity component types
        pub fn createEntity(self: *World) !Entity {
            const zone = ztracy.ZoneNC(@src(), "World createEntity", Color.world);
            defer zone.End();

            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };
            var archetype = self.archetree.voidType();
            const empty: []const []const u8 = &.{};
            try archetype.registerEntity(entity, empty);
            try self.entity_references.append(EntityRef{
                .tree_node_index = 0,
            });
            return entity;
        }

        /// Get a entity builder. A builder has the advantage of not having to dynamically moved
        /// to different archetypes while being constructure compared with createEntity() + addComponent()
        pub fn entityBuilder(self: *World) !EntityBuilder {
            const zone = ztracy.ZoneNC(@src(), "World entityBuilder", Color.world);
            defer zone.End();

            return EntityBuilder.init(self.allocator);
        }

        /// initialize an entity using data supplied to a builder.
        /// The world struct takes ownership of the builder after this
        /// This means that the builder memory is invalidated afterwards
        pub fn fromEntityBuilder(self: *World, builder: *EntityBuilder) !Entity {
            const zone = ztracy.ZoneNC(@src(), "World fromEntityBuilder", Color.world);
            defer zone.End();

            var type_query = query.Runtime.fromOwnedSlices(
                self.allocator,
                builder.type_sizes.toOwnedSlice(),
                builder.type_hashes.toOwnedSlice(),
            );
            defer type_query.deinit();
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            self.maybeInvalidateSystemArchetypeCache(get_result);

            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };
            try self.entity_references.append(EntityRef{
                .tree_node_index = get_result.node_index,
            });
            errdefer _ = self.entity_references.pop();

            const components = builder.component_data.toOwnedSlice();
            defer {
                for (components) |component_bytes| {
                    builder.allocator.free(component_bytes);
                }
                builder.allocator.free(components);
            }
            // skip void entry
            try get_result.archetype.registerEntity(entity, components);

            return entity;
        }

        /// Assign a component to an entity
        pub fn setComponent(self: *World, entity: Entity, component: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World setComponent", Color.world);
            defer zone.End();

            const T = @TypeOf(component);
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            if (current_archetype.hasComponent(T)) {
                try current_archetype.setComponent(entity, T, component);
            }

            var type_query = try query.Runtime.fromSlicesAndTypes(
                self.allocator,
                current_archetype.type_sizes,
                current_archetype.type_hashes,
                &[_]type{T},
            );
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            self.maybeInvalidateSystemArchetypeCache(get_result);

            try current_archetype.moveEntity(entity, get_result.archetype);
            try get_result.archetype.setComponent(entity, T, component);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        /// Assign multiple components to an entity at once
        /// using this instead of mutliple setComponent calls is more effective
        pub fn setComponents(self: *World, entity: Entity, components: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World setComponents", Color.world);
            defer zone.End();

            const components_info = @typeInfo(@TypeOf(components));
            if (components_info != .Struct) {
                @compileError("expected struct or tuple of components, got " ++ @typeName(components));
            }
            const components_struct = components_info.Struct;
            if (components_struct.fields.len == 0) {
                @compileError("attempting to add 0 components");
            }

            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            var archetype_has_components = true;
            comptime var component_types: [components_struct.fields.len]type = undefined;
            inline for (components_struct.fields) |field, i| {
                if (@typeInfo(field.field_type) != .Struct) {
                    @compileError("components must be struct types");
                }
                component_types[i] = field.field_type;
                archetype_has_components = archetype_has_components and current_archetype.hasComponent(field.field_type);
            }

            // if all components already exist on archetype, then we can simply assign each new value
            if (archetype_has_components) {
                inline for (component_types) |T, i| {
                    try current_archetype.setComponent(entity, T, components[i]);
                }
                return;
            }

            var type_query = try query.Runtime.fromSlicesAndTypes(
                self.allocator,
                current_archetype.type_sizes,
                current_archetype.type_hashes,
                &component_types,
            );
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            self.maybeInvalidateSystemArchetypeCache(get_result);

            try current_archetype.moveEntity(entity, get_result.archetype);
            inline for (component_types) |T, i| {
                try get_result.archetype.setComponent(entity, T, components[i]);
            }

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        // Check if an entity has a given component
        pub fn hasComponent(self: World, entity: Entity, comptime T: type) bool {
            const zone = ztracy.ZoneNC(@src(), "World hasComponent", Color.world);
            defer zone.End();

            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            return current_archetype.hasComponent(T);
        }

        /// Fetch an entity's component data based on parameter T
        pub fn getComponent(self: *World, entity: Entity, comptime T: type) !T {
            const zone = ztracy.ZoneNC(@src(), "World getComponent", Color.world);
            defer zone.End();

            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            return current_archetype.getComponent(entity, T);
        }

        /// Remove an entity's component data based on parameter T
        pub fn removeComponent(self: *World, entity: Entity, comptime T: type) !void {
            const zone = ztracy.ZoneNC(@src(), "World removeComponent", Color.world);
            defer zone.End();

            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            const remove_type_index = try current_archetype.componentIndex(comptime query.hashType(T));

            // create a type query by filtering out the removed type
            var type_query: query.Runtime = blk: {
                if (remove_type_index == 0) {
                    break :blk try query.Runtime.fromSlices(
                        self.allocator,
                        current_archetype.type_sizes[1..],
                        current_archetype.type_hashes[1..],
                    );
                } else if (remove_type_index == current_archetype.type_count - 1) {
                    break :blk try query.Runtime.fromSlices(
                        self.allocator,
                        current_archetype.type_sizes[0..remove_type_index],
                        current_archetype.type_hashes[0..remove_type_index],
                    );
                }

                break :blk try query.Runtime.fromSliceSlices(
                    self.allocator,
                    &[2][]const usize{
                        current_archetype.type_sizes[0..remove_type_index],
                        current_archetype.type_sizes[remove_type_index + 1 ..],
                    },
                    &[2][]const u64{
                        current_archetype.type_hashes[0..remove_type_index],
                        current_archetype.type_hashes[remove_type_index + 1 ..],
                    },
                );
            };
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            self.maybeInvalidateSystemArchetypeCache(get_result);
            try current_archetype.moveEntity(entity, get_result.archetype);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        /// Remove multiple components from an entity at once
        /// using this instead of mutliple removeComponent calls is more effective
        pub fn removeComponents(self: *World, entity: Entity, component_types: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World removeComponents", Color.world);
            defer zone.End();

            const components_info = @typeInfo(@TypeOf(component_types));
            if (components_info != .Struct) {
                @compileError("expected struct or tuple of components, got " ++ @typeName(component_types));
            }
            const components_struct = components_info.Struct;
            if (components_struct.fields.len == 0) {
                @compileError("attempting to remove 0 components");
            }

            comptime var types: [components_struct.fields.len]type = undefined;
            inline for (components_struct.fields) |field, i| {
                if (@typeInfo(field.field_type) != .Type) {
                    @compileError("removeComponents expected component types, got " ++ @typeName(field.field_type));
                }
                types[i] = @ptrCast(*const type, field.default_value.?).*;
            }

            // find all indices that are to be removed
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            var component_indices: [components_struct.fields.len]usize = undefined;
            inline for (query.sortTypes(&types)) |T, i| {
                component_indices[i] = try current_archetype.componentIndex(comptime query.hashType(T));
            }

            // Sorry to anyone reading this code
            var prev_remove_index: usize = 0;
            var slice_count: usize = 0;
            var type_sizes: [components_struct.fields.len * 2][]const usize = undefined;
            var type_hashes: [components_struct.fields.len * 2][]const u64 = undefined;
            for (component_indices) |remove_type_index, i| {
                // assing prev index at the end of scope
                defer prev_remove_index = remove_type_index;

                // define start and end of any slice
                const start = prev_remove_index + 1;
                const end = if (i < component_indices.len - 1) component_indices[i + 1] else current_archetype.type_count;

                // if we remove first element in slice
                if (remove_type_index == 0) {
                    type_sizes[slice_count] = current_archetype.type_sizes[1..end];
                    type_hashes[slice_count] = current_archetype.type_hashes[1..end];
                    slice_count += 1;
                    // else if we remove last element in slice
                } else if (remove_type_index == current_archetype.type_count - 1) {
                    type_sizes[slice_count] = current_archetype.type_sizes[start..remove_type_index];
                    type_hashes[slice_count] = current_archetype.type_hashes[start..remove_type_index];
                    slice_count += 1;
                    // else if we remove element inbetween elements
                } else {
                    type_sizes[slice_count] = current_archetype.type_sizes[start..remove_type_index];
                    type_sizes[slice_count + 1] = current_archetype.type_sizes[remove_type_index + 1 .. end];
                    type_hashes[slice_count] = current_archetype.type_hashes[start..remove_type_index];
                    type_hashes[slice_count + 1] = current_archetype.type_hashes[remove_type_index + 1 .. end];
                    slice_count += 2;
                }
            }

            var type_query = try query.Runtime.fromSliceSlices(
                self.allocator,
                type_sizes[0..slice_count],
                type_hashes[0..slice_count],
            );
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            self.maybeInvalidateSystemArchetypeCache(get_result);
            try current_archetype.moveEntity(entity, get_result.archetype);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        /// Call all systems registered when calling CreateWorld
        pub fn dispatch(self: *World) !void {
            const zone = ztracy.ZoneNC(@src(), "World dispatch", Color.world);
            defer zone.End();

            // TODO: when/if a mechanism is introduced to create archetypes in systems,
            //       then this functionality will be invalid!
            // dispatch will always cache archetypes
            defer self.system_archetypes.valid = true;

            inline for (systems_metadata) |system_metadata, system_index| {
                const query_types = comptime system_metadata.queryArgTypes();
                const param_types = comptime system_metadata.paramArgTypes();

                var archetypes = blk: {
                    // if cache is invalid
                    if (self.system_archetypes.valid == false) {
                        // cache new values
                        const types = try self.archetree.getTypeSubsets(self.allocator, &query_types);
                        self.system_archetypes.archetypes[system_index] = types;
                        break :blk types;
                    }
                    // if cache is valid, returned cached value
                    break :blk self.system_archetypes.archetypes[system_index];
                };

                for (archetypes) |archetype| {
                    const components = try archetype.getComponentStorages(query_types.len, query_types);
                    var i: usize = 0;
                    while (i < components[components.len - 1]) : (i += 1) {
                        var component: std.meta.Tuple(&param_types) = undefined;
                        inline for (param_types) |Param, j| {
                            if (@sizeOf(Param) > 0) {
                                switch (system_metadata.args[j]) {
                                    .value => component[j] = components[j][i],
                                    .ptr => component[j] = &components[j][i],
                                }
                            } else {
                                switch (system_metadata.args[j]) {
                                    .value => component[j] = Param{},
                                    .ptr => component[j] = &Param{},
                                }
                            }
                        }

                        const system_ptr = @ptrCast(*const system_metadata.function_type, system_functions[system_index]);
                        // call either a failable system, or a normal void system
                        if (comptime system_metadata.canReturnError()) {
                            try failableCallWrapper(system_ptr.*, component);
                        } else {
                            callWrapper(system_ptr.*, component);
                        }
                    }
                }
            }
        }

        /// this should be called after calling any ArcheTree.getArchetypeX functions to update
        /// the systems archetypes lists
        fn maybeInvalidateSystemArchetypeCache(self: *World, get_result: ArcheTree.GetArchetypeResult) void {
            const zone = ztracy.ZoneNC(@src(), "World update archetype cache", Color.world);
            defer zone.End();

            // if nothing has changed
            if (get_result.created_archetype == false or self.system_archetypes.valid == false) return;

            inline for (systems_metadata) |_, i| {
                self.allocator.free(self.system_archetypes.archetypes[i]);
            }
            self.system_archetypes.valid = false;
        }
    };
}

// Workaround see issue #5170 : https://github.com/ziglang/zig/issues/5170
fn callWrapper(func: anytype, args: anytype) void {
    @call(.{}, func, args);
}

// Workaround see issue #5170 : https://github.com/ziglang/zig/issues/5170
fn failableCallWrapper(func: anytype, args: anytype) !void {
    try @call(.{}, func, args);
}

pub const EntityBuilder = struct {
    allocator: Allocator,
    type_count: usize,
    type_sizes: std.ArrayList(usize),
    type_hashes: std.ArrayList(u64),
    component_data: std.ArrayList([]u8),

    /// Initialize a EntityBuilder, should only be called from World.zig
    pub fn init(allocator: Allocator) !EntityBuilder {
        const zone = ztracy.ZoneNC(@src(), "EntityBuilder init", Color.entity_builder);
        defer zone.End();

        // init by registering the void type
        return EntityBuilder{
            .allocator = allocator,
            .type_count = 0,
            .type_sizes = std.ArrayList(usize).init(allocator),
            .type_hashes = std.ArrayList(u64).init(allocator),
            .component_data = std.ArrayList([]u8).init(allocator),
        };
    }

    /// Add component to entity
    pub fn addComponent(self: *EntityBuilder, component: anytype) !void {
        const zone = ztracy.ZoneNC(@src(), "EntityBuilder addComponent", Color.entity_builder);
        defer zone.End();

        const T = @TypeOf(component);
        const type_hash = query.hashType(T);
        const type_size = @sizeOf(T);

        var type_index: ?usize = null;
        for (self.type_hashes.items) |hash, i| {
            if (type_hash < hash) {
                type_index = i;
                break;
            }
            if (type_hash == hash) return error.ComponentAlreadyExist;
        }

        const component_bytes = blk: {
            const bytes = std.mem.asBytes(&component);
            break :blk try self.allocator.dupe(u8, bytes);
        };
        errdefer self.allocator.free(component_bytes);

        try self.component_data.resize(self.component_data.items.len + 1);
        errdefer self.component_data.shrinkAndFree(self.component_data.items.len - 1);

        try self.type_hashes.append(type_hash);
        errdefer _ = self.type_hashes.popOrNull();

        try self.type_sizes.append(type_size);
        errdefer _ = self.type_sizes.popOrNull();

        self.component_data.items[self.type_count] = component_bytes;
        self.type_count += 1;
        errdefer self.type_count -= 1;

        // if we should move component order
        if (type_index) |index| {
            std.mem.rotate(u64, self.type_hashes.items[index..self.type_count], self.type_count - index - 1);
            std.mem.rotate(usize, self.type_sizes.items[index..self.type_count], self.type_count - index - 1);
            std.mem.rotate([]u8, self.component_data.items[index..self.type_count], self.type_count - index - 1);
        }
    }
};

// world without systems
const StateWorld = CreateWorld(.{});

test "create() entity works" {
    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity0 = try world.createEntity();
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try world.createEntity();
    try testing.expectEqual(entity1.id, 1);
}

test "setComponent() component moves entity to correct archetype" {
    const A = struct { some_value: u32 };
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{ .some_value = 123 };
    try world.setComponent(entity1, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, b);
    // entity is now of archetype (A B)

    const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
    const stored_a = try entity_archetype.getComponent(entity1, A);
    try testing.expectEqual(a, stored_a);
    const stored_b = try entity_archetype.getComponent(entity1, B);
    try testing.expectEqual(b, stored_b);
}

test "hasComponent() responds as expected" {
    const A = struct {};
    const B = struct {};

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponent(entity, A{});

    try testing.expectEqual(true, world.hasComponent(entity, A));
    try testing.expectEqual(false, world.hasComponent(entity, B));
}

test "getComponent() retrieve component value" {
    const A = struct { some_value: u32 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    try world.setComponent(try world.createEntity(), A{ .some_value = 0 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 1 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 2 });

    const entity = try world.createEntity();
    const a = A{ .some_value = 123 };
    try world.setComponent(entity, a);

    try world.setComponent(try world.createEntity(), A{ .some_value = 3 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 4 });

    try testing.expectEqual(a, try world.getComponent(entity, A));
}

test "removeComponent() component moves entity to correct archetype" {
    const A = struct {};
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{};
    try world.setComponent(entity1, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, b);
    // entity is now of archetype (A B)

    try world.removeComponent(entity1, A);
    // entity is now of archetype (B)

    const entity_archetype = try world.archetree.getArchetype(&[_]type{B});
    const stored_b = try entity_archetype.getComponent(entity1, B);
    try testing.expectEqual(b, stored_b);
}

test "setComponents() add multiple components" {
    const A = struct { a: u8 };
    const B = struct { b: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const a = A{ .a = 1 };
    const b = B{ .b = 2 };
    const entity = try world.createEntity();
    try world.setComponents(entity, .{ a, b });

    try testing.expectEqual(a, try world.getComponent(entity, A));
    try testing.expectEqual(b, try world.getComponent(entity, B));
}

test "setComponents() reassign multiple components" {
    const A = struct { a: u8 };
    const B = struct { b: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponents(entity, .{ A{ .a = 240 }, B{ .b = 250 } });

    const a = A{ .a = 1 };
    const b = B{ .b = 2 };
    try world.setComponents(entity, .{ a, b });
    try testing.expectEqual(a, try world.getComponent(entity, A));
    try testing.expectEqual(b, try world.getComponent(entity, B));
}

test "removeComponents() remove multiple components" {
    const A = struct {};
    const B = struct {};

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const a = A{};
    const b = B{};
    const entity = try world.createEntity();
    try world.setComponents(entity, .{ a, b });

    try testing.expectEqual(a, try world.getComponent(entity, A));
    try testing.expectEqual(b, try world.getComponent(entity, B));

    try world.removeComponents(entity, .{ A, B });

    try testing.expectEqual(false, world.hasComponent(entity, A));
    try testing.expectEqual(false, world.hasComponent(entity, B));
}

test "world build entity using EntityBuilder" {
    const A = struct {};
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    // build a entity using a builder
    var builder = try world.entityBuilder();
    try builder.addComponent(A{});
    try builder.addComponent(B{ .some_value = 42 });
    const entity = try world.fromEntityBuilder(&builder);

    // get expected archetype
    const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
    const entity_b = try entity_archetype.getComponent(entity, B);
    try testing.expectEqual(B{ .some_value = 42 }, entity_b);
}

test "EntityBuilder addComponent() gradually sort" {
    const A = struct { i: usize };
    const B = struct {
        i: usize,
        @"1": usize = 0,
    };
    const C = struct {
        i: usize,
        @"1": usize = 0,
        @"2": usize = 0,
    };
    const D = struct {
        i: usize,
        @"1": usize = 0,
        @"3": usize = 0,
    };
    const E = struct {
        i: usize,
        @"1": usize = 0,
        @"3": usize = 0,
        @"4": usize = 0,
    };
    const types = [_]type{ A, B, C, D, E };

    var builder = try EntityBuilder.init(testing.allocator);
    defer {
        builder.type_sizes.deinit();
        builder.type_hashes.deinit();
        for (builder.component_data.items) |component_bytes| {
            builder.allocator.free(component_bytes);
        }
        builder.component_data.deinit();
    }
    inline for (types) |T, i| {
        try builder.addComponent(T{ .i = i });
    }

    try testing.expectEqual(builder.type_count, types.len);
    inline for (query.sortTypes(&types)) |T, i| {
        try testing.expectEqual(builder.type_hashes.items[i], query.hashType(T));
        try testing.expectEqual(builder.type_sizes.items[i], @sizeOf(T));
        try testing.expectEqual(builder.component_data.items[i].len, @sizeOf(T));
    }
}

test "systems can fail" {
    const A = struct { str: []const u8 };
    const B = struct { some_value: u8 };

    const SystemStruct = struct {
        fn aSystem(a: A) !void {
            try testing.expectEqual(a, .{ .str = "hello world!" });
        }

        fn bSystem(b: B) !void {
            _ = b;
            return error.SomethingWentVeryWrong;
        }
    };

    var world = try CreateWorld(.{
        SystemStruct.aSystem,
        SystemStruct.bSystem,
    }).init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponent(entity, A{ .str = "hello world!" });
    try world.setComponent(entity, B{ .some_value = 42 });

    try testing.expectError(error.SomethingWentVeryWrong, world.dispatch());
}

test "systems can mutate values" {
    const A = struct { position: u8 };
    const B = struct { velocity: u8 };

    const SystemStruct = struct {
        fn moveSystem(a: *A, b: B) void {
            a.position += b.velocity;
        }
    };

    var world = try CreateWorld(.{
        SystemStruct.moveSystem,
    }).init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponent(entity, A{ .position = 10 });
    try world.setComponent(entity, B{ .velocity = 9 });

    try world.dispatch();

    try testing.expectEqual(A{ .position = 19 }, try world.getComponent(entity, A));
}

test "systems cache works" {
    const A = struct { system_call_count: *u8 };
    const B = struct {};

    const SystemStruct = struct {
        fn systemOne(a: *A) void {
            a.system_call_count.* += 1;
        }

        fn systemTwo(a: *A, b: B) void {
            _ = b;
            a.system_call_count.* += 1;
        }
    };

    var world = try CreateWorld(.{
        SystemStruct.systemOne,
        SystemStruct.systemTwo,
    }).init(testing.allocator);
    defer world.deinit();

    var call_count: *u8 = try testing.allocator.create(u8);
    defer testing.allocator.destroy(call_count);
    call_count.* = 0;

    const entity1 = try world.createEntity();
    try world.setComponent(entity1, A{ .system_call_count = call_count });

    try world.dispatch();

    const entity2 = try world.createEntity();
    try world.setComponent(entity2, A{ .system_call_count = call_count });
    try world.setComponent(entity2, B{});

    try world.dispatch();

    try testing.expectEqual(@as(u8, 3), call_count.*);
}

test "systems can be registered through a struct" {
    const A = struct { v: u8 };
    const B = struct { v: u8 };
    const C = struct { v: u8 };
    const D = struct { v: u8 };
    const E = struct { v: u8 };

    // define a system function
    const systemOne = struct {
        fn func(a: *A) !void {
            try testing.expectEqual(@as(u8, 0), a.v);
            a.v += 1;
        }
    }.func;

    // define a system type
    const SystemType = struct {
        fn systemTwo(b: *B) !void {
            try testing.expectEqual(@as(u8, 1), b.v);
            b.v += 1;
        }
        fn systemThree(c: *C) !void {
            try testing.expectEqual(@as(u8, 2), c.v);
            c.v += 1;
        }
        fn systemFour(d: *D) !void {
            try testing.expectEqual(@as(u8, 3), d.v);
            d.v += 1;
        }
    };

    // define a system struct
    const systemTwo = struct {
        fn func(e: *E) !void {
            try testing.expectEqual(@as(u8, 4), e.v);
            e.v += 1;
        }
    }.func;

    var world = try CreateWorld(.{ systemOne, SystemType, systemTwo }).init(testing.allocator);
    defer world.deinit();

    const types = [_]type{ A, B, C, D, E };

    var entities: [5]Entity = undefined;
    inline for (types) |T, i| {
        entities[i] = try world.createEntity();
        try world.setComponent(entities[i], T{ .v = i });
    }

    try world.dispatch();

    inline for (types) |T, i| {
        const comp = try world.getComponent(entities[i], T);
        try testing.expectEqual(@as(u8, i + 1), comp.v);
    }
}
