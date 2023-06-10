const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Type = std.builtin.Type;
const testing = std.testing;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const OpaqueArchetype = @import("OpaqueArchetype.zig");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityRef = entity_type.EntityRef;

const ecez_query = @import("query.zig");
const QueryBuilder = ecez_query.QueryBuilder;
const Query = ecez_query.Query;
const hashType = ecez_query.hashType;

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

const ecez_error = @import("error.zig");
const StorageError = ecez_error.StorageError;

pub fn FromComponents(comptime submitted_components: []const type) type {
    const ComponentInfo = struct {
        hash: u64,
        type: type,
        @"struct": Type.Struct,
    };
    const Sort = struct {
        hash: u64,
    };

    comptime var biggest_component_size: usize = 0;

    // get some inital type info from the submitted components, and verify that all are components
    const component_info: [submitted_components.len]ComponentInfo = blk: {
        comptime var info: [submitted_components.len]ComponentInfo = undefined;
        comptime var sort: [submitted_components.len]Sort = undefined;
        for (submitted_components, 0..) |Component, i| {
            const component_size = @sizeOf(Component);
            if (component_size > biggest_component_size) {
                biggest_component_size = component_size;
            }

            const type_info = @typeInfo(Component);
            if (type_info != .Struct) {
                @compileError("component " ++ @typeName(Component) ++ " is not of type struct");
            }
            info[i] = .{
                .hash = hashType(Component),
                .@"struct" = type_info.Struct,
                .type = Component,
            };
            sort[i] = .{ .hash = info[i].hash };
        }
        comptime ecez_query.sort(Sort, &sort);
        for (sort, 0..) |s, j| {
            for (info, 0..) |inf, k| {
                if (s.hash == inf.hash) {
                    std.mem.swap(ComponentInfo, &info[j], &info[k]);
                }
            }
        }

        break :blk info;
    };

    return struct {
        const ArcheContainer = @This();

        const void_index = 0;

        // A single integer that represent the full path of an opaque archetype
        pub const BitEncoding = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = submitted_components.len,
        } });

        pub const BitEncodingShift = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = std.math.log2_int_ceil(BitEncoding, submitted_components.len),
        } });

        const ArchetypeIndex = u32;

        allocator: Allocator,
        archetypes: ArrayList(OpaqueArchetype),
        bit_encodings: ArrayList(BitEncoding),
        entity_references: ArrayList(EntityRef),

        component_hashes: [submitted_components.len]u64,
        component_sizes: [submitted_components.len]u32,

        empty_bytes: [0]u8,

        pub fn init(allocator: Allocator) error{OutOfMemory}!ArcheContainer {
            const pre_alloc_amount = 32;

            var archetypes = try ArrayList(OpaqueArchetype).initCapacity(allocator, pre_alloc_amount);
            errdefer archetypes.deinit();

            var bit_encodings = try ArrayList(BitEncoding).initCapacity(allocator, pre_alloc_amount);
            errdefer bit_encodings.deinit();

            var entity_references = try ArrayList(EntityRef).initCapacity(allocator, pre_alloc_amount);
            errdefer entity_references.deinit();

            comptime var component_hashes: [submitted_components.len]u64 = undefined;
            comptime var component_sizes: [submitted_components.len]u32 = undefined;
            inline for (component_info, &component_hashes, &component_sizes) |info, *hash, *size| {
                hash.* = info.hash;
                size.* = @sizeOf(info.type);
            }

            const void_archetype = try OpaqueArchetype.init(allocator, &[0]u64{}, &[0]u32{});
            archetypes.appendAssumeCapacity(void_archetype);
            bit_encodings.appendAssumeCapacity(@as(BitEncoding, 0));

            return ArcheContainer{
                .allocator = allocator,
                .archetypes = archetypes,
                .bit_encodings = bit_encodings,
                .entity_references = entity_references,
                .component_hashes = component_hashes,
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
        }

        pub inline fn clearRetainingCapacity(self: *ArcheContainer) void {
            const zone = ztracy.ZoneNC(@src(), "Container clear", Color.arche_container);
            defer zone.End();

            // Do not clear node_bit_paths & bit_path_relation since archetypes persist
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

            // try to update component in current archetype
            self.archetypes.items[current_bit_index].setComponent(entity, component) catch |err| switch (err) {
                // component is not part of current archetype
                error.ComponentMissing => {
                    const new_component_global_index = comptime componentIndex(@TypeOf(component));

                    const old_bit_encoding = self.bit_encodings.items[current_bit_index];
                    const new_bit = @as(BitEncoding, 1 << new_component_global_index);
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

                        // get the type hashes and sizes
                        var type_hashes: [submitted_components.len]u64 = undefined;
                        var type_sizes: [submitted_components.len]u32 = undefined;
                        {
                            var encoding = new_encoding;
                            var assigned_components: u32 = 0;
                            var cursor: u32 = 0;
                            for (0..total_local_components) |component_index| {
                                const step = @intCast(BitEncodingShift, @ctz(encoding));
                                std.debug.assert(((encoding >> step) & 1) == 1);

                                cursor += step;
                                type_hashes[component_index] = self.component_hashes[cursor];
                                type_sizes[component_index] = self.component_sizes[cursor];
                                cursor += 1;

                                encoding = (encoding >> step) >> 1;
                                assigned_components += 1;
                            }

                            std.debug.assert(assigned_components == total_local_components);
                        }

                        var new_archetype = try OpaqueArchetype.init(
                            self.allocator,
                            type_hashes[0..total_local_components],
                            type_sizes[0..total_local_components],
                        );
                        errdefer new_archetype.deinit();

                        const opaque_archetype_index = self.archetypes.items.len;
                        try self.archetypes.append(new_archetype);
                        errdefer _ = self.archetypes.pop();

                        // register archetype bit encoding
                        try self.bit_encodings.append(new_encoding);
                        errdefer _ = self.node_bit_paths.pop();

                        std.debug.assert(self.bit_encodings.items.len == self.archetypes.items.len);

                        new_archetype_index = opaque_archetype_index;
                        break :maybe_create_archetype_blk true;
                    };

                    var data: [submitted_components.len][]u8 = undefined;
                    inline for (component_info, 0..) |_, i| {
                        var buf: [biggest_component_size]u8 = undefined;
                        data[i] = &buf;
                    }

                    // remove the entity and it's components from the old archetype
                    try self.archetypes.items[current_bit_index].rawSwapRemoveEntity(entity, data[0 .. total_local_components - 1]);

                    // insert the new component at it's correct location
                    var rhd = data[new_local_component_index..total_local_components];
                    std.mem.rotate([]u8, rhd, rhd.len - 1);
                    std.mem.copy(u8, data[new_local_component_index], std.mem.asBytes(&component));

                    const unwrapped_index = new_archetype_index.?;

                    // register the entity in the new archetype
                    try self.archetypes.items[unwrapped_index].rawRegisterEntity(entity, data[0..total_local_components]);

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

            var data: [submitted_components.len][]u8 = undefined;
            inline for (component_info, 0..) |_, i| {
                var buf: [biggest_component_size]u8 = undefined;
                data[i] = &buf;
            }

            // get old path and count how many components are stored in the entity
            const old_encoding = self.bit_encodings.items[old_archetype_index];
            const old_component_count = @popCount(old_encoding);

            // remove the entity and it's components from the old archetype
            try self.archetypes.items[old_archetype_index].rawSwapRemoveEntity(entity, data[0..old_component_count]);
            // TODO: handle error, this currently can lead to corrupt entities!

            const global_remove_component_index = comptime componentIndex(Component);
            const remove_bit = @as(BitEncoding, 1 << global_remove_component_index);
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

                // get the type hashes and sizes
                var type_hashes: [submitted_components.len]u64 = undefined;
                var type_sizes: [submitted_components.len]u32 = undefined;
                {
                    var encoding = new_encoding;
                    var cursor: u32 = 0;
                    for (0..new_component_count) |component_index| {
                        const step = @ctz(encoding);
                        std.debug.assert((encoding >> step) & 1 == 1);

                        cursor += @intCast(u32, step);
                        encoding = (encoding >> step) >> 1;

                        type_hashes[component_index] = self.component_hashes[cursor];
                        type_sizes[component_index] = self.component_sizes[cursor];

                        cursor += 1;
                    }
                }

                var new_archetype = try OpaqueArchetype.init(
                    self.allocator,
                    type_hashes[0..new_component_count],
                    type_sizes[0..new_component_count],
                );
                errdefer new_archetype.deinit();

                const opaque_archetype_index = self.archetypes.items.len;

                // register archetype bit encoding
                try self.bit_encodings.append(new_encoding);
                errdefer _ = self.bit_encodings.pop();

                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                std.debug.assert(self.bit_encodings.items.len == self.archetypes.items.len);

                new_archetype_index = opaque_archetype_index;
                break :archetype_create_blk true;
            };

            var rhd = data[local_remove_component_index..old_component_count];
            std.mem.rotate([]u8, rhd, 1);

            // register the entity in the new archetype
            const unwrapped_index = new_archetype_index.?;
            try self.archetypes.items[unwrapped_index].rawRegisterEntity(
                entity,
                data[0..new_component_count],
            );

            // update entity reference
            self.entity_references.items[entity.id] = @intCast(
                EntityRef,
                unwrapped_index,
            );

            return new_archetype_created;
        }

        pub inline fn encodingToArchetypeIndex(self: ArcheContainer, bit_encoding: BitEncoding) ?usize {
            for (self.bit_encodings.items, 0..) |bit_encoding_item, bit_encoding_index| {
                if (bit_encoding_item == bit_encoding) {
                    return bit_encoding_index;
                }
            }
            return null;
        }

        pub inline fn getTypeHashes(self: ArcheContainer, entity: Entity) []const u64 {
            const opaque_archetype_index = self.entity_references.items[entity.id];
            return self.archetypes.items[opaque_archetype_index].getTypeHashes();
        }

        pub inline fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            // verify that component exist in storage
            _ = comptime componentIndex(Component);

            const opaque_archetype_index = self.entity_references.items[entity.id];
            return self.archetypes.items[opaque_archetype_index].hasComponent(Component);
        }

        /// Query archetypes containing all components listed in component_hashes
        /// hashes must be sorted
        /// caller own the returned memory
        pub fn getArchetypesWithComponents(
            self: ArcheContainer,
            allocator: Allocator,
            include_component_hashes: []const u64,
            exclude_component_hashes: []const u64,
        ) error{OutOfMemory}![]*OpaqueArchetype {
            var include_bits: BitEncoding = 0;
            for (include_component_hashes, 0..) |include_hash, i| {
                include_bits |= blk: {
                    for (self.component_hashes[i..], i..) |stored_hash, step| {
                        if (include_hash == stored_hash) {
                            break :blk @as(BitEncoding, 1) << @intCast(BitEncodingShift, step);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            var exclude_bits: BitEncoding = 0;
            for (exclude_component_hashes, 0..) |exclude_hash, i| {
                exclude_bits |= blk: {
                    for (self.component_hashes[i..], i..) |stored_hash, step| {
                        if (exclude_hash == stored_hash) {
                            break :blk @as(BitEncoding, 1) << @intCast(BitEncodingShift, step);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            // caller should verify this
            std.debug.assert(include_bits & exclude_bits == 0);

            var resulting_archetypes = ArrayList(*OpaqueArchetype).init(allocator);
            errdefer resulting_archetypes.deinit();

            // TODO: implement inplace zero alloc binary traversal
            //       we can actually use stack array, biggest stack for traversal is submitted_component.len :)
            // TODO: benchmark between brute force and tree traversal
            // https://www.geeksforgeeks.org/inorder-tree-traversal-without-recursion/

            // brute force search of queried nodes which should be fast for smaller amount of nodes (limit of 1000-10000s of nodes)
            for (self.bit_encodings.items, 0..) |bit_path, path_index| {
                if ((bit_path & include_bits) == include_bits and (bit_path & exclude_bits == 0)) {
                    try resulting_archetypes.append(&self.archetypes.items[path_index]);
                }
            }

            return resulting_archetypes.toOwnedSlice();
        }

        pub fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) ecez_error.ArchetypeError!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
            defer zone.End();

            const opaque_archetype_index = self.entity_references.items[entity.id];

            const component_get_info = @typeInfo(Component);
            switch (component_get_info) {
                .Pointer => |ptr_info| {
                    if (@typeInfo(ptr_info.child) == .Struct) {
                        return self.archetypes.items[opaque_archetype_index].getComponent(entity, ptr_info.child);
                    }
                },
                .Struct => {
                    const component_ptr = try self.archetypes.items[opaque_archetype_index].getComponent(entity, Component);
                    return component_ptr.*;
                },
                else => {},
            }
            @compileError("Get component can only find a component which has to be struct, or pointer to struct");
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
            const initial_bit_encoding: BitEncoding = comptime bit_calc_blk: {
                var bits: BitEncoding = 0;
                outer_loop: inline for (sorted_initial_state_field_types, 0..) |initial_state_field_type, field_index| {
                    inline for (submitted_components[field_index..], field_index..) |Component, comp_index| {
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
                    inline for (sorted_initial_state_field_types, 0..) |sorted_type, sorted_index| {
                        if (initial_field.type == sorted_type) {
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
                    try self.archetypes.items[index].rawRegisterEntity(entity, &sorted_state_data);
                    break :regiser_entity_blk false;
                }

                comptime var type_hashes: [sorted_initial_state_field_types.len]u64 = undefined;
                comptime var type_sizes: [sorted_initial_state_field_types.len]u32 = undefined;
                inline for (&type_hashes, &type_sizes, sorted_initial_state_field_types) |*type_hash, *type_size, Component| {
                    type_hash.* = comptime ecez_query.hashType(Component);
                    type_size.* = comptime @sizeOf(Component);
                }

                var new_archetype = try OpaqueArchetype.init(self.allocator, &type_hashes, &type_sizes);
                errdefer new_archetype.deinit();

                const opaque_archetype_index = self.archetypes.items.len;
                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.bit_encodings.append(initial_bit_encoding);
                errdefer _ = self.bit_encodings.pop();

                try self.archetypes.items[opaque_archetype_index].rawRegisterEntity(entity, &sorted_state_data);
                // TODO: errdefer self.archetypes.items[opaque_archetype_index].removeEntity(); https://github.com/Avokadoen/ecez/issues/118

                new_archetype_index = opaque_archetype_index;
                break :regiser_entity_blk true;
            };

            // register a reference to able to locate entity
            self.entity_references.items[entity.id] = @intCast(EntityRef, new_archetype_index.?);

            return new_archetype_created;
        }

        inline fn componentIndex(comptime Component: type) comptime_int {
            inline for (component_info, 0..) |info, i| {
                if (Component == info.type) {
                    return i;
                }
            }
            @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
        }
    };
}

const TestContainer = FromComponents(&Testing.AllComponentsArr);

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

test "ArcheContainer getTypeHashes works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const initial_state = Testing.Archetype.AC{
        .a = Testing.Component.A{ .value = 1 },
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;

    try testing.expectEqualSlices(
        u64,
        &[_]u64{ ecez_query.hashType(Testing.Component.A), ecez_query.hashType(Testing.Component.C) },
        container.getTypeHashes(entity),
    );
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

test "ArcheContainer getArchetypesWithComponents returns matching archetypes" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const a_hash = comptime hashType(Testing.Component.A);
    const b_hash = comptime hashType(Testing.Component.B);
    const c_hash = comptime hashType(Testing.Component.C);
    if (a_hash > b_hash) {
        @compileError("hash function give unexpected result");
    }
    if (b_hash > c_hash) {
        @compileError("hash function give unexpected result");
    }

    const initial_state = Testing.Archetype.C{
        .c = Testing.Component.C{},
    };
    const entity = (try container.createEntity(initial_state)).entity;
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.A{});
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.B{});
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 3), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }

    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, c_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, b_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ b_hash, c_hash },
            &[0]u64{},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
}

test "ArcheContainer getArchetypesWithComponents can exclude archetypes" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const a_hash = comptime hashType(Testing.Component.A);
    const b_hash = comptime hashType(Testing.Component.B);
    const c_hash = comptime hashType(Testing.Component.C);
    if (a_hash > b_hash) {
        @compileError("hash function give unexpected result");
    }
    if (b_hash > c_hash) {
        @compileError("hash function give unexpected result");
    }

    // make sure the container have Archetype {A}, {B}, {C}, {AB}, {AC}, {ABC}
    _ = try container.createEntity(Testing.Archetype.A{});
    _ = try container.createEntity(Testing.Archetype.B{});
    _ = try container.createEntity(Testing.Archetype.C{});
    _ = try container.createEntity(Testing.Archetype.AB{});
    _ = try container.createEntity(Testing.Archetype.AC{});
    _ = try container.createEntity(Testing.Archetype.ABC{});

    // ask for A, excluding C
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[_]u64{c_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }

    // ask for A, excluding B, C
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{a_hash},
            &[_]u64{ b_hash, c_hash },
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    // ask for B, excluding A
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{b_hash},
            &[_]u64{a_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    // ask for C, excluding B
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{c_hash},
            &[_]u64{b_hash},
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
}
