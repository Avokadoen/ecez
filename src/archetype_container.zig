const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Type = std.builtin.Type;
const testing = std.testing;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const opaque_archetype = @import("opaque_archetype.zig");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityRef = entity_type.EntityRef;

const binary_tree = @import("binary_tree.zig");

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

const ecez_error = @import("error.zig");
const StorageError = ecez_error.StorageError;

pub fn FromComponents(comptime components: []const type, comptime BitMask: type) type {
    // search biggest component size and verify types are structs
    const biggest_component_size = comptime biggest_comp_search_blk: {
        var biggest_size = 0;
        for (components) |Component| {
            if (@sizeOf(Component) > biggest_size) {
                biggest_size = @sizeOf(Component);
            }

            const type_info = @typeInfo(Component);
            if (type_info != .Struct) {
                @compileError("component " ++ @typeName(Component) ++ " is not of type struct");
            }
        }
        break :biggest_comp_search_blk biggest_size;
    };

    return struct {
        pub const BinaryTree = binary_tree.FromConfig(components.len + 1, BitMask);
        pub const OpaqueArchetype = opaque_archetype.FromComponentMask(BitMask);

        const ArcheContainer = @This();

        const void_index = 0;

        const ArchetypeIndex = u32;

        allocator: Allocator,
        archetypes: ArrayList(OpaqueArchetype),
        entity_references: ArrayList(EntityRef),

        tree: BinaryTree,

        component_sizes: [components.len]u32,

        empty_bytes: [0]u8,

        pub fn init(allocator: Allocator) error{OutOfMemory}!ArcheContainer {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            const pre_alloc_amount = 32;

            var archetypes = try ArrayList(OpaqueArchetype).initCapacity(allocator, pre_alloc_amount);
            errdefer archetypes.deinit();

            const entity_references = try ArrayList(EntityRef).initCapacity(allocator, pre_alloc_amount);
            errdefer entity_references.deinit();

            const tree = try BinaryTree.init(allocator, pre_alloc_amount);
            errdefer tree.deinit();

            comptime var component_sizes: [components.len]u32 = undefined;
            inline for (components, &component_sizes) |Component, *size| {
                size.* = @sizeOf(Component);
            }

            const void_bitmask = @as(BitMask.Bits, 0);
            const void_archetype = try OpaqueArchetype.init(allocator, void_bitmask);
            archetypes.appendAssumeCapacity(void_archetype);

            return ArcheContainer{
                .allocator = allocator,
                .archetypes = archetypes,
                .entity_references = entity_references,
                .tree = tree,
                .component_sizes = component_sizes,
                .empty_bytes = .{},
            };
        }

        pub inline fn deinit(self: *ArcheContainer) void {
            for (self.archetypes.items) |*archetype| {
                archetype.deinit();
            }
            self.archetypes.deinit();
            self.entity_references.deinit();
            self.tree.deinit();
        }

        pub inline fn clearRetainingCapacity(self: *ArcheContainer) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            // Do not clear tree since archetypes persist
            //
            self.entity_references.clearRetainingCapacity();

            for (self.archetypes.items) |*archetype| {
                archetype.clearRetainingCapacity();
            }
        }

        pub const CreateEntityResult = struct {
            new_archetype_container: bool,
            entity: Entity,
        };
        /// create a new entity and supply it an initial state
        /// Parameters:
        ///     - inital_state: the initial components of the entity
        ///
        /// Returns: A bool indicating if a new archetype has been made, and the entity
        pub fn createEntity(self: *ArcheContainer, initial_state: anytype) error{OutOfMemory}!CreateEntityResult {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            // create new entity
            const entity = Entity{ .id = @as(u32, @intCast(self.entity_references.items.len)) };

            // allocate the entity reference item and let initializeEntityStorage assign it if it suceeds
            try self.entity_references.append(undefined);
            errdefer _ = self.entity_references.pop();

            // if some initial state, then we initialize the storage needed
            const new_archetype_created = try self.initializeEntityStorage(entity, initial_state);
            return CreateEntityResult{
                .new_archetype_container = new_archetype_created,
                .entity = entity,
            };
        }

        /// Assign the component value to an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub fn setComponent(self: *ArcheContainer, entity: Entity, component: anytype) error{ EntityMissing, OutOfMemory }!bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            const current_bit_index = self.entity_references.items[entity.id];

            const Component = @TypeOf(component);
            const new_component_global_index = comptime componentIndex(Component);

            const old_bit_encoding = self.archetypes.items[current_bit_index].component_bitmask;
            const new_bit = @as(BitMask.Bits, 1 << new_component_global_index);

            // try to update component in current archetype
            self.archetypes.items[current_bit_index].setComponent(entity, component, new_bit) catch |err| switch (err) {
                // component is not part of current archetype
                error.ComponentMissing => {
                    const new_encoding = old_bit_encoding | new_bit;

                    // we need the index of the new component in the sequence of components are tied to the entity
                    const new_local_component_index: usize = new_comp_index_calc_blk: {
                        // calculate mask that filters out most significant bits
                        const new_after_bits_mask = new_bit - 1;
                        const new_index = @popCount(old_bit_encoding & new_after_bits_mask);
                        break :new_comp_index_calc_blk new_index;
                    };

                    const total_local_components: u32 = @popCount(new_encoding);

                    var new_archetype_index = self.tree.getNodeDataIndex(new_encoding);

                    var new_archetype_created: bool = maybe_create_archetype_blk: {
                        // if the archetype already exist
                        if (new_archetype_index != null) {
                            break :maybe_create_archetype_blk false;
                        }

                        var new_archetype = try OpaqueArchetype.init(
                            self.allocator,
                            new_encoding,
                        );
                        errdefer new_archetype.deinit();

                        const opaque_archetype_index = @as(u32, @intCast(self.archetypes.items.len));
                        try self.archetypes.append(new_archetype);
                        errdefer _ = self.archetypes.pop();

                        try self.tree.appendChain(opaque_archetype_index, new_encoding);

                        new_archetype_index = opaque_archetype_index;
                        break :maybe_create_archetype_blk true;
                    };

                    // fetch a view of the component data
                    var data: [components.len][]u8 = undefined;
                    try self.archetypes.items[current_bit_index].fetchEntityComponentView(
                        entity,
                        self.component_sizes,
                        data[0 .. total_local_components - 1],
                    );

                    // move the data slices around to make room for the new component data
                    var rhd = data[new_local_component_index..total_local_components];
                    std.mem.rotate([]u8, rhd, rhd.len - 1);

                    // copy the new component bytes to a stack buffer and assing the datat entry to this buffer
                    var buf: [biggest_component_size]u8 = undefined;
                    @memcpy(buf[0..@sizeOf(Component)], std.mem.asBytes(&component));
                    data[new_local_component_index] = &buf;

                    const unwrapped_index = new_archetype_index.?;
                    // register the component bytes and entity to it's new archetype
                    try self.archetypes.items[unwrapped_index].registerEntity(entity, data[0..total_local_components], self.component_sizes);

                    // remove the entity and it's components from the old archetype, we know entity exist in old archetype because we called fetchEntityComponentView successfully
                    self.archetypes.items[current_bit_index].swapRemoveEntity(entity, self.component_sizes) catch unreachable;

                    // update entity reference
                    self.entity_references.items[entity.id] = @as(
                        EntityRef,
                        @intCast(unwrapped_index),
                    );

                    return new_archetype_created;
                },
                // if this happen, then the container is in an invalid state
                error.EntityMissing => unreachable,
            };

            return false;
        }

        /// Remove the Component type from an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub fn removeComponent(self: *ArcheContainer, entity: Entity, comptime Component: type) error{ EntityMissing, OutOfMemory }!bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            if (self.hasComponent(entity, Component) == false) {
                return false;
            }

            const old_archetype_index = self.entity_references.items[entity.id];

            // get old path and count how many components are stored in the entity
            const old_encoding = self.archetypes.items[old_archetype_index].component_bitmask;
            const old_component_count = @popCount(old_encoding);

            const global_remove_component_index = comptime componentIndex(Component);
            const remove_bit = @as(BitMask.Bits, 1 << global_remove_component_index);
            const new_encoding = old_encoding & ~remove_bit;

            var new_archetype_index = self.tree.getNodeDataIndex(new_encoding);

            var new_archetype_created = archetype_create_blk: {
                // if archetype already exist
                if (new_archetype_index != null) {
                    break :archetype_create_blk false;
                }

                var new_archetype = try OpaqueArchetype.init(self.allocator, new_encoding);
                errdefer new_archetype.deinit();

                const opaque_archetype_index = @as(u32, @intCast(self.archetypes.items.len));

                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.tree.appendChain(opaque_archetype_index, new_encoding);

                new_archetype_index = opaque_archetype_index;
                break :archetype_create_blk true;
            };

            var local_remove_component_index: usize = remove_index_calc_blk: {
                // calculate mask that filters out most significant bits
                const remove_after_bits_mask = remove_bit - 1;
                const remove_index = @popCount(old_encoding & remove_after_bits_mask);
                break :remove_index_calc_blk remove_index;
            };

            // fetch a view of the component data
            var data: [components.len][]u8 = undefined;
            try self.archetypes.items[old_archetype_index].fetchEntityComponentView(
                entity,
                self.component_sizes,
                data[0..old_component_count],
            );

            // move the data slices around to make room for the new component data
            var rhd = data[local_remove_component_index..old_component_count];
            std.mem.rotate([]u8, rhd, 1);

            const unwrapped_index = new_archetype_index.?;
            // register the component bytes and entity to it's new archetype
            try self.archetypes.items[unwrapped_index].registerEntity(entity, data[0 .. old_component_count - 1], self.component_sizes);

            // register the entity in the new archetype, we know entity exist in old archetype because we called fetchEntityComponentView successfully
            self.archetypes.items[old_archetype_index].swapRemoveEntity(entity, self.component_sizes) catch unreachable;

            // update entity reference
            self.entity_references.items[entity.id] = @as(
                EntityRef,
                @intCast(unwrapped_index),
            );

            return new_archetype_created;
        }

        pub inline fn getEntityBitEncoding(self: ArcheContainer, entity: Entity) BitMask.Bits {
            const encoding_index = self.entity_references.items[entity.id];
            return self.archetypes.items[encoding_index].component_bitmask;
        }

        pub fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            const component_bit = comptime comp_bit_blk: {
                const global_index = componentIndex(Component);
                break :comp_bit_blk (1 << global_index);
            };

            const opaque_archetype_index = self.entity_references.items[entity.id];
            return self.archetypes.items[opaque_archetype_index].hasComponents(component_bit);
        }

        pub fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) ecez_error.ArchetypeError!Component {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            const opaque_archetype_index = self.entity_references.items[entity.id];

            const component_get_info = @typeInfo(Component);
            switch (component_get_info) {
                .Pointer => |ptr_info| {
                    if (@typeInfo(ptr_info.child) == .Struct) {
                        const global_remove_component_index = comptime componentIndex(ptr_info.child);
                        const component_bit = 1 << global_remove_component_index;

                        return self.archetypes.items[opaque_archetype_index].getComponent(entity, component_bit, ptr_info.child);
                    }
                },
                .Struct => {
                    const global_remove_component_index = comptime componentIndex(Component);
                    const component_bit = 1 << global_remove_component_index;

                    const component_ptr = try self.archetypes.items[opaque_archetype_index].getComponent(entity, component_bit, Component);
                    return component_ptr.*;
                },
                else => {},
            }
            @compileError("Get component can only find a components (struct, or pointer to struct)");
        }

        /// This function can initialize the storage for the components of a given entity
        fn initializeEntityStorage(self: *ArcheContainer, entity: Entity, initial_state: anytype) error{OutOfMemory}!bool {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            const ArchetypeStruct = @TypeOf(initial_state);
            const arche_struct_info = blk: {
                const info = @typeInfo(ArchetypeStruct);
                if (info != .Struct) {
                    @compileError("expected initial_state to be of type struct");
                }
                break :blk info.Struct;
            };

            // produce flat array of field types
            const initial_state_field_types = comptime field_types_blk: {
                var field_types: [arche_struct_info.fields.len]type = undefined;
                inline for (&field_types, arche_struct_info.fields) |*field_type, field_info| {
                    field_type.* = field_info.type;
                }
                break :field_types_blk field_types;
            };

            // calculate the bits that describe the path to the archetype of this entity
            const initial_bit_encoding: BitMask.Bits = comptime bit_calc_blk: {
                var bits: BitMask.Bits = 0;
                outer_loop: inline for (initial_state_field_types, 0..) |initial_state_field_type, field_index| {
                    inline for (components[field_index..], field_index..) |Component, comp_index| {
                        if (initial_state_field_type == Component) {
                            bits |= 1 << comp_index;
                            continue :outer_loop;
                        }
                    }
                    @compileError(@typeName(initial_state_field_type) ++ " is not a Storage registered component type");
                }
                break :bit_calc_blk bits;
            };

            var state_data: [arche_struct_info.fields.len][]const u8 = undefined;
            inline for (&state_data, arche_struct_info.fields) |*state_data_field, initial_field_info| {
                if (@sizeOf(initial_field_info.type) > 0) {
                    const field = &@field(initial_state, initial_field_info.name);
                    state_data_field.* = std.mem.asBytes(field);
                } else {
                    state_data_field.* = &self.empty_bytes;
                }
            }

            var new_archetype_index = self.tree.getNodeDataIndex(initial_bit_encoding);

            var new_archetype_created: bool = regiser_entity_blk: {
                // if the archetype already exist
                if (new_archetype_index) |index| {
                    try self.archetypes.items[index].registerEntity(
                        entity,
                        &state_data,
                        self.component_sizes,
                    );
                    break :regiser_entity_blk false;
                }

                var new_archetype = try OpaqueArchetype.init(
                    self.allocator,
                    initial_bit_encoding,
                );
                errdefer new_archetype.deinit();

                const opaque_archetype_index = @as(u32, @intCast(self.archetypes.items.len));
                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.tree.appendChain(opaque_archetype_index, initial_bit_encoding);

                try self.archetypes.items[opaque_archetype_index].registerEntity(
                    entity,
                    &state_data,
                    self.component_sizes,
                );
                errdefer self.archetypes.items[opaque_archetype_index].removeEntity(entity, self.component_sizes) catch unreachable;

                new_archetype_index = opaque_archetype_index;
                break :regiser_entity_blk true;
            };

            // register a reference to able to locate entity
            self.entity_references.items[entity.id] = @as(EntityRef, @intCast(new_archetype_index.?));

            return new_archetype_created;
        }

        // Retrieve an archetype with the matching bitmask, this function will create an archetype if it does not exist
        pub fn setAndGetArchetypeIndexWithBitmap(self: *ArcheContainer, bitmap: BitMask.Bits) error{OutOfMemory}!usize {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.arche_container);
            defer zone.End();

            // if archetype alread exist
            if (self.tree.getNodeDataIndex(bitmap)) |index| {
                return index;
            }

            var new_archetype = try OpaqueArchetype.init(
                self.allocator,
                bitmap,
            );
            errdefer new_archetype.deinit();

            const opaque_archetype_index = @as(u32, @intCast(self.archetypes.items.len));
            try self.archetypes.append(new_archetype);
            errdefer _ = self.archetypes.pop();

            try self.tree.appendChain(opaque_archetype_index, bitmap);

            return opaque_archetype_index;
        }

        pub inline fn componentIndex(comptime Component: type) comptime_int {
            inline for (components, 0..) |SortComponent, i| {
                if (Component == SortComponent) {
                    return i;
                }
            }
            @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
        }

        pub inline fn getComponentHashes() [components.len]u64 {
            meta.comptimeOnlyFn();

            comptime var hashes: [components.len]u64 = undefined;
            inline for (&hashes, components) |*hash, Component| {
                hash.* = meta.hashType(Component);
            }

            return hashes;
        }
    };
}

const TestBitmask = meta.BitMaskFromComponents(&Testing.AllComponentsArr);
const TestContainer = FromComponents(&Testing.AllComponentsArr, TestBitmask);

test "ArcheContainer init + deinit is idempotent" {
    var container = try TestContainer.init(testing.allocator);
    container.deinit();
}

test "ArcheContainer createEntity & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.ABC{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
        .c = Testing.Component.C{},
    };

    const create_result = try container.createEntity(initial_state);
    const entity = create_result.entity;

    try testing.expectEqual(initial_state.a, try container.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(initial_state.b, try container.getComponent(entity, Testing.Component.B));
    try testing.expectEqual(initial_state.c, try container.getComponent(entity, Testing.Component.C));
}

test "ArcheContainer setComponent & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    const a = Testing.Component.A{ .value = 40 };
    _ = try container.setComponent(entity, a);
    try testing.expectEqual(a, try container.getComponent(entity, Testing.Component.A));

    const b = Testing.Component.B{ .value = 42 };
    _ = try container.setComponent(entity, b);
    try testing.expectEqual(b, try container.getComponent(entity, Testing.Component.B));
}

test "ArcheContainer removeComponent & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    _ = try container.removeComponent(entity, Testing.Component.C);
    try testing.expectEqual(initial_state.a, try container.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, container.hasComponent(entity, Testing.Component.C));
}

test "ArcheContainer getEntityBitEncoding works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    try testing.expectEqual(@as(TestBitmask.Bits, 0b101), container.getEntityBitEncoding(entity));
}

test "ArcheContainer hasComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    try testing.expectEqual(true, container.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, container.hasComponent(entity, Testing.Component.B));
    try testing.expectEqual(true, container.hasComponent(entity, Testing.Component.C));
}

test "ArcheContainer getComponentHashes works" {
    const expected_hashes = comptime [_]u64{
        meta.hashType(Testing.Component.A),
        meta.hashType(Testing.Component.B),
        meta.hashType(Testing.Component.C),
    };

    const actual_hashes = comptime TestContainer.getComponentHashes();

    try testing.expectEqualSlices(u64, &expected_hashes, &actual_hashes);
}
