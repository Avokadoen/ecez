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

const ecez_query = @import("query.zig");
const QueryBuilder = ecez_query.QueryBuilder;
const Query = ecez_query.Query;
const binary_tree = @import("binary_tree.zig");

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

const ecez_error = @import("error.zig");
const StorageError = ecez_error.StorageError;

pub fn FromComponents(comptime sorted_components: []const type, comptime BitMask: type) type {
    // search biggest component size and verify types are structs
    const biggest_component_size = comptime biggest_comp_search_blk: {
        var biggest_size = 0;
        for (sorted_components) |Component| {
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
        pub const BinaryTree = binary_tree.FromConfig(sorted_components.len + 1, BitMask);
        pub const OpaqueArchetype = opaque_archetype.FromComponentMask(BitMask);

        const ArcheContainer = @This();

        const void_index = 0;

        const ArchetypeIndex = u32;

        allocator: Allocator,
        archetypes: ArrayList(OpaqueArchetype),
        bit_encodings: ArrayList(BitMask.Bits),
        entity_references: ArrayList(EntityRef),

        tree: BinaryTree,

        component_sizes: [sorted_components.len]u32,

        empty_bytes: [0]u8,

        pub fn init(allocator: Allocator) error{OutOfMemory}!ArcheContainer {
            const pre_alloc_amount = 32;

            var archetypes = try ArrayList(OpaqueArchetype).initCapacity(allocator, pre_alloc_amount);
            errdefer archetypes.deinit();

            // TODO: no longer need (stored in the archetype)
            var bit_encodings = try ArrayList(BitMask.Bits).initCapacity(allocator, pre_alloc_amount);
            errdefer bit_encodings.deinit();

            const entity_references = try ArrayList(EntityRef).initCapacity(allocator, pre_alloc_amount);
            errdefer entity_references.deinit();

            const tree = try BinaryTree.init(allocator, pre_alloc_amount);
            errdefer tree.deinit();

            comptime var component_sizes: [sorted_components.len]u32 = undefined;
            inline for (sorted_components, &component_sizes) |Component, *size| {
                size.* = @sizeOf(Component);
            }

            const void_bitmask = @as(BitMask.Bits, 0);
            const void_archetype = try OpaqueArchetype.init(allocator, void_bitmask);
            archetypes.appendAssumeCapacity(void_archetype);
            bit_encodings.appendAssumeCapacity(void_bitmask);

            return ArcheContainer{
                .allocator = allocator,
                .archetypes = archetypes,
                .bit_encodings = bit_encodings,
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
            self.bit_encodings.deinit();
            self.entity_references.deinit();
            self.tree.deinit();
        }

        pub inline fn clearRetainingCapacity(self: *ArcheContainer) void {
            const zone = ztracy.ZoneNC(@src(), "Container clear", Color.arche_container);
            defer zone.End();

            // Do not clear bit_encodings or tree since archetypes persist
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
            const zone = ztracy.ZoneNC(@src(), "Container createEntity", Color.arche_container);
            defer zone.End();

            // create new entity
            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };

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
            const zone = ztracy.ZoneNC(@src(), "Container setComponent", Color.arche_container);
            defer zone.End();

            const current_bit_index = self.entity_references.items[entity.id];

            const new_component_global_index = comptime componentIndex(@TypeOf(component));

            const old_bit_encoding = self.bit_encodings.items[current_bit_index];
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

                    var new_archetype_index = self.encodingToArchetypeIndex(new_encoding);

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

                        const opaque_archetype_index = self.archetypes.items.len;
                        try self.archetypes.append(new_archetype);
                        errdefer _ = self.archetypes.pop();

                        // register archetype bit encoding
                        try self.bit_encodings.append(new_encoding);
                        errdefer _ = self.bit_encodings.pop();

                        try self.tree.appendChain(@intCast(u32, opaque_archetype_index), new_encoding);

                        std.debug.assert(self.bit_encodings.items.len == self.archetypes.items.len);

                        new_archetype_index = opaque_archetype_index;
                        break :maybe_create_archetype_blk true;
                    };

                    var data: [sorted_components.len][]u8 = undefined;
                    inline for (&data) |*data_entry| {
                        var buf: [biggest_component_size]u8 = undefined;
                        data_entry.* = &buf;
                    }

                    // remove the entity and it's components from the old archetype
                    try self.archetypes.items[current_bit_index].swapRemoveEntity(
                        entity,
                        data[0 .. total_local_components - 1],
                        self.component_sizes,
                    );

                    // insert the new component at it's correct location
                    var rhd = data[new_local_component_index..total_local_components];
                    std.mem.rotate([]u8, rhd, rhd.len - 1);
                    std.mem.copy(u8, data[new_local_component_index], std.mem.asBytes(&component));

                    const unwrapped_index = new_archetype_index.?;

                    // register the entity in the new archetype
                    try self.archetypes.items[unwrapped_index].registerEntity(entity, data[0..total_local_components], self.component_sizes);

                    // update entity reference
                    self.entity_references.items[entity.id] = @intCast(
                        EntityRef,
                        unwrapped_index,
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
            if (self.hasComponent(entity, Component) == false) {
                return false;
            }

            const old_archetype_index = self.entity_references.items[entity.id];

            var data: [sorted_components.len][]u8 = undefined;
            inline for (&data) |*data_entry| {
                var buf: [biggest_component_size]u8 = undefined;
                data_entry.* = &buf;
            }

            // get old path and count how many components are stored in the entity
            const old_encoding = self.bit_encodings.items[old_archetype_index];
            const old_component_count = @popCount(old_encoding);

            // remove the entity and it's components from the old archetype
            try self.archetypes.items[old_archetype_index].swapRemoveEntity(
                entity,
                data[0..old_component_count],
                self.component_sizes,
            );
            // TODO: handle error, this currently can lead to corrupt entities!

            const global_remove_component_index = comptime componentIndex(Component);
            const remove_bit = @as(BitMask.Bits, 1 << global_remove_component_index);
            const new_encoding = old_encoding & ~remove_bit;

            var local_remove_component_index: usize = remove_index_calc_blk: {
                // calculate mask that filters out most significant bits
                const remove_after_bits_mask = remove_bit - 1;
                const remove_index = @popCount(old_encoding & remove_after_bits_mask);
                break :remove_index_calc_blk remove_index;
            };

            var new_archetype_index = self.encodingToArchetypeIndex(new_encoding);

            const new_component_count = old_component_count - 1;
            var new_archetype_created = archetype_create_blk: {
                // if archetype already exist
                if (new_archetype_index != null) {
                    break :archetype_create_blk false;
                }

                var new_archetype = try OpaqueArchetype.init(self.allocator, new_encoding);
                errdefer new_archetype.deinit();

                const opaque_archetype_index = self.archetypes.items.len;

                // register archetype bit encoding
                try self.bit_encodings.append(new_encoding);
                errdefer _ = self.bit_encodings.pop();

                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.tree.appendChain(@intCast(u32, opaque_archetype_index), new_encoding);

                std.debug.assert(self.bit_encodings.items.len == self.archetypes.items.len);

                new_archetype_index = opaque_archetype_index;
                break :archetype_create_blk true;
            };

            var rhd = data[local_remove_component_index..old_component_count];
            std.mem.rotate([]u8, rhd, 1);

            // register the entity in the new archetype
            const unwrapped_index = new_archetype_index.?;
            try self.archetypes.items[unwrapped_index].registerEntity(
                entity,
                data[0..new_component_count],
                self.component_sizes,
            );

            // update entity reference
            self.entity_references.items[entity.id] = @intCast(
                EntityRef,
                unwrapped_index,
            );

            return new_archetype_created;
        }

        pub inline fn encodingToArchetypeIndex(self: ArcheContainer, bit_encoding: BitMask.Bits) ?usize {
            for (self.bit_encodings.items, 0..) |bit_encoding_item, bit_encoding_index| {
                if (bit_encoding_item == bit_encoding) {
                    return bit_encoding_index;
                }
            }
            return null;
        }

        pub inline fn getEntityBitEncoding(self: ArcheContainer, entity: Entity) BitMask.Bits {
            const encoding_index = self.entity_references.items[entity.id];
            return self.bit_encodings.items[encoding_index];
        }

        pub inline fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            const component_bit = comptime comp_bit_blk: {
                const global_index = componentIndex(Component);
                break :comp_bit_blk (1 << global_index);
            };

            const opaque_archetype_index = self.entity_references.items[entity.id];
            return self.archetypes.items[opaque_archetype_index].hasComponents(component_bit);
        }

        pub fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) ecez_error.ArchetypeError!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
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
            const zone = ztracy.ZoneNC(@src(), "Container createEntity", Color.arche_container);
            defer zone.End();

            const ArchetypeStruct = @TypeOf(initial_state);
            const arche_struct_info = blk: {
                const info = @typeInfo(ArchetypeStruct);
                if (info != .Struct) {
                    @compileError("expected initial_state to be of type struct");
                }
                break :blk info.Struct;
            };

            // sort the types in the inital state to produce a valid binary path
            const sorted_initial_state_field_types = comptime sort_fields_blk: {
                var field_types: [arche_struct_info.fields.len]type = undefined;
                inline for (&field_types, arche_struct_info.fields) |*field_type, field_info| {
                    field_type.* = field_info.type;
                }
                // TODO: in-place sort instead
                break :sort_fields_blk ecez_query.sortTypes(&field_types);
            };

            // calculate the bits that describe the path to the archetype of this entity
            const initial_bit_encoding: BitMask.Bits = comptime bit_calc_blk: {
                var bits: BitMask.Bits = 0;
                outer_loop: inline for (sorted_initial_state_field_types, 0..) |initial_state_field_type, field_index| {
                    inline for (sorted_components[field_index..], field_index..) |Component, comp_index| {
                        if (initial_state_field_type == Component) {
                            bits |= 1 << comp_index;
                            continue :outer_loop;
                        }
                    }
                    @compileError(@typeName(initial_state_field_type) ++ " is not a World registered component type");
                }
                break :bit_calc_blk bits;
            };

            // generate a map from initial state to the internal storage order so we store binary data in the correct location
            // the map goes as followed: field_map[initial_state_index] => internal_storage_index
            const field_map = comptime field_map_blk: {
                var map: [arche_struct_info.fields.len]usize = undefined;
                inline for (&map, arche_struct_info.fields) |*map_entry, initial_field| {
                    inline for (sorted_initial_state_field_types, 0..) |SortedType, sorted_index| {
                        if (initial_field.type == SortedType) {
                            map_entry.* = sorted_index;
                            break;
                        }
                    }
                }

                break :field_map_blk map;
            };

            // create a component byte data view (sort initial state according to type)
            var sorted_state_data: [arche_struct_info.fields.len][]const u8 = undefined;
            inline for (arche_struct_info.fields, field_map) |initial_field_info, data_index| {
                if (@sizeOf(initial_field_info.type) > 0) {
                    const field = &@field(initial_state, initial_field_info.name);
                    sorted_state_data[data_index] = std.mem.asBytes(field);
                } else {
                    sorted_state_data[data_index] = &self.empty_bytes;
                }
            }

            var new_archetype_index = self.encodingToArchetypeIndex(initial_bit_encoding);

            var new_archetype_created: bool = regiser_entity_blk: {
                // if the archetype already exist
                if (new_archetype_index) |index| {
                    try self.archetypes.items[index].registerEntity(
                        entity,
                        &sorted_state_data,
                        self.component_sizes,
                    );
                    break :regiser_entity_blk false;
                }

                var new_archetype = try OpaqueArchetype.init(
                    self.allocator,
                    initial_bit_encoding,
                );
                errdefer new_archetype.deinit();

                const opaque_archetype_index = self.archetypes.items.len;
                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.bit_encodings.append(initial_bit_encoding);
                errdefer _ = self.bit_encodings.pop();

                try self.tree.appendChain(@intCast(u32, opaque_archetype_index), initial_bit_encoding);

                try self.archetypes.items[opaque_archetype_index].registerEntity(
                    entity,
                    &sorted_state_data,
                    self.component_sizes,
                );
                errdefer self.archetypes.items[opaque_archetype_index].removeEntity(entity, self.component_sizes) catch unreachable;

                new_archetype_index = opaque_archetype_index;
                break :regiser_entity_blk true;
            };

            // register a reference to able to locate entity
            self.entity_references.items[entity.id] = @intCast(EntityRef, new_archetype_index.?);

            return new_archetype_created;
        }

        pub inline fn componentIndex(comptime Component: type) comptime_int {
            inline for (sorted_components, 0..) |SortComponent, i| {
                if (Component == SortComponent) {
                    return i;
                }
            }
            @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
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
