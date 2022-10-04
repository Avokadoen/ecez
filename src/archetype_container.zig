const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Type = std.builtin.Type;
const testing = std.testing;

const ztracy = @import("ztracy");
const Color = @import("misc.zig").Color;

const archetype = @import("archetype.zig");
const OpaqueArchetype = @import("OpaqueArchetype.zig");

const IArchetype = @import("IArchetype.zig");
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityRef = entity_type.EntityRef;
const iterator = @import("iterator.zig");

const ecez_query = @import("query.zig");
const QueryBuilder = ecez_query.QueryBuilder;
const Query = ecez_query.Query;
const hashType = ecez_query.hashType;

const meta = @import("meta.zig");
const Testing = @import("Testing.zig");

pub const Error = IArchetype.Error;

pub fn FromComponents(comptime submitted_components: []const type) type {
    const len = submitted_components.len;

    const ComponentInfo = struct {
        hash: u64,
        @"type": type,
        @"struct": Type.Struct,
    };
    const Sort = struct {
        hash: u64,
    };

    comptime var biggest_component_size: usize = 0;

    // get some inital type info from the submitted components, and verify that all are components
    const component_info: [len]ComponentInfo = blk: {
        comptime var info: [len]ComponentInfo = undefined;
        comptime var sort: [len]Sort = undefined;
        for (submitted_components) |Component, i| {
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
                .@"type" = Component,
            };
            sort[i] = .{ .hash = info[i].hash };
        }
        comptime ecez_query.sort(Sort, &sort);
        for (sort) |s, j| {
            for (info) |inf, k| {
                if (s.hash == inf.hash) {
                    std.mem.swap(ComponentInfo, &info[j], &info[k]);
                }
            }
        }

        break :blk info;
    };

    const Node = struct {
        const Self = @This();

        pub const Arch = struct {
            path_index: usize,
            struct_bytes: []u8,
            interface: IArchetype,
        };

        archetypes: []?Arch,
        children: []?Self,
        // index to current node's path
        path_index: usize,

        pub fn init(allocator: Allocator, count: usize, path_index: usize) !Self {
            std.debug.assert(len >= count);

            var archetypes = try allocator.alloc(?Arch, count);
            errdefer allocator.free(archetypes);
            std.mem.set(?Arch, archetypes, null);

            var children = try allocator.alloc(?Self, count);
            errdefer children.free(children);
            std.mem.set(?Self, children, null);

            return Self{
                .archetypes = archetypes,
                .children = children,
                .path_index = path_index,
            };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            for (self.children) |maybe_child| {
                if (maybe_child) |child| {
                    child.deinit(allocator);
                }
            }
            allocator.free(self.children);

            for (self.archetypes) |arche| {
                if (arche) |some| {
                    some.interface.deinit();
                    allocator.free(some.struct_bytes);
                }
            }
            allocator.free(self.archetypes);
        }

        /// retrieve all archetype interfaces that are at the path destination and all children of the destination
        pub inline fn getIArchetypesWithComponents(self: Self, path: ?[]u16, result: *ArrayList(IArchetype), depth: usize) Allocator.Error!void {
            // if we have not found nodes with our requirements
            if (path) |some_path| {
                std.debug.assert(some_path.len > 0);

                if (some_path.len > 1) {
                    for (self.children) |maybe_child, i| {
                        if (maybe_child) |child| {
                            const from: usize = if ((some_path[0] - depth) == i) 1 else 0;
                            try child.getIArchetypesWithComponents(some_path[from..], result, depth + 1);
                        }
                    }
                } else {
                    const arche_index = some_path[0] - depth;
                    // store the initial archetype meeting our requirement
                    if (self.archetypes[arche_index]) |arche| {
                        try result.append(arche.interface);
                    }

                    const next_depth = depth + 1;

                    // if any of the steps are less than the depth then it means we are in a
                    // branch that does not contain any matches
                    const skip_searching_siblings = blk: {
                        for (some_path) |step| {
                            if (step < next_depth) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };

                    if (skip_searching_siblings) {
                        for (self.children) |maybe_child, i| {
                            if (maybe_child) |child| {
                                if (i == arche_index) {
                                    // record all defined archetypes in the child as well since they also only have suitable archetypes
                                    try child.getIArchetypesWithComponents(null, result, next_depth);
                                }
                            }
                        }
                    } else {
                        for (self.children) |maybe_child, i| {
                            if (maybe_child) |child| {
                                if (i == arche_index) {
                                    // record all defined archetypes in the child as well since they also only have suitable archetypes
                                    try child.getIArchetypesWithComponents(null, result, next_depth);
                                } else {
                                    // look for matching component in the other children
                                    try child.getIArchetypesWithComponents(some_path, result, next_depth);
                                }
                            }
                        }
                    }
                }
            } else {
                // all archetypes should be fitting our requirement
                for (self.archetypes) |maybe_arche| {
                    if (maybe_arche) |arche| {
                        try result.append(arche.interface);
                    }
                }

                // record all defined archetypes in the children as well since they also only have suitable archetypes
                for (self.children) |maybe_child| {
                    if (maybe_child) |child| {
                        try child.getIArchetypesWithComponents(null, result, depth + 1);
                    }
                }
            }
        }
    };

    return struct {
        const ArcheContainer = @This();

        // contains the indices to find a given archetype
        pub const ArchetypePath = struct {
            len: usize,
            indices: [len]u16,
        };
        allocator: Allocator,
        archetype_paths: ArrayList(ArchetypePath),
        entity_references: ArrayList(EntityRef),
        root_node: Node,

        component_hashes: [len]u64,
        component_sizes: [len]usize,

        empty_bytes: [0]u8,

        pub inline fn init(allocator: Allocator) !ArcheContainer {
            var archetype_paths = ArrayList(ArchetypePath).init(allocator);
            try archetype_paths.append(ArchetypePath{ .len = 0, .indices = undefined });
            errdefer archetype_paths.deinit();

            const root_node = try Node.init(allocator, len, 0);
            errdefer root_node.deinit(allocator);

            comptime var component_hashes: [len]u64 = undefined;
            comptime var component_sizes: [len]usize = undefined;
            inline for (component_info) |info, i| {
                component_hashes[i] = info.hash;
                component_sizes[i] = @sizeOf(info.@"type");
            }

            return ArcheContainer{
                .allocator = allocator,
                .archetype_paths = archetype_paths,
                .entity_references = ArrayList(EntityRef).init(allocator),
                .root_node = root_node,
                .component_hashes = component_hashes,
                .component_sizes = component_sizes,
                .empty_bytes = .{},
            };
        }

        pub inline fn deinit(self: ArcheContainer) void {
            self.archetype_paths.deinit();
            self.entity_references.deinit();
            self.root_node.deinit(self.allocator);
        }

        /// create a new entity and supply it an initial state
        /// Parameters:
        ///     - inital_state: the initial state of the entity, this must be a registered archetype
        ///
        /// Returns: A bool indicating if a new archetype have been made, and the entity
        pub inline fn createEntity(self: *ArcheContainer, initial_state: anytype) !std.meta.Tuple(&[_]type{ bool, Entity }) {
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

            const TypeMap = struct {
                hash: u64,
                state_index: usize,
                component_index: u16,
            };

            const index_path = comptime blk1: {
                var path: [arche_struct_info.fields.len]TypeMap = undefined;
                var sort: [arche_struct_info.fields.len]Sort = undefined;
                inline for (arche_struct_info.fields) |field, i| {
                    // find index of field in outer component array
                    const component_index = blk2: {
                        inline for (component_info) |component, j| {
                            if (field.field_type == component.@"type") {
                                break :blk2 @intCast(u15, j);
                            }
                        }
                        @compileError(@typeName(field.field_type) ++ " is not a registered component type");
                    };

                    path[i] = TypeMap{
                        .hash = hashType(field.field_type),
                        .state_index = i,
                        .component_index = component_index,
                    };
                    sort[i] = .{ .hash = path[i].hash };
                }
                // sort based on hash
                ecez_query.sort(Sort, &sort);

                // sort path based on hash
                for (sort) |s, j| {
                    for (path) |p, k| {
                        if (s.hash == p.hash) {
                            std.mem.swap(TypeMap, &path[j], &path[k]);
                        }
                    }
                }
                break :blk1 path;
            };

            // TODO: errdefer deinit allocations!
            // get the node that will store the new entity
            var entity_node = blk: {
                var current_node = self.root_node;
                for (index_path[0 .. index_path.len - 1]) |path, depth| {
                    const index = path.component_index - depth;
                    // see if our new node exist
                    if (current_node.children[index]) |child| {
                        // set target child node as current node
                        current_node = child;
                    } else {
                        // create new node and set it as current node
                        current_node.children[index] = try Node.init(
                            self.allocator,
                            current_node.children.len - 1,
                            self.archetype_paths.items.len,
                        );
                        current_node = current_node.children[index].?;

                        // register new node path
                        var archetype_path = ArchetypePath{
                            .len = depth + 1,
                            .indices = undefined,
                        };
                        for (index_path[0..archetype_path.len]) |sub_path, i| {
                            archetype_path.indices[i] = sub_path.component_index - @intCast(u15, i);
                        }
                        try self.archetype_paths.append(archetype_path);
                    }
                }
                break :blk current_node;
            };

            // create a component byte data view
            var data: [arche_struct_info.fields.len][]const u8 = undefined;
            inline for (index_path) |path, i| {
                if (@sizeOf(@TypeOf(initial_state[path.state_index])) > 0) {
                    data[i] = std.mem.asBytes(&initial_state[path.state_index]);
                } else {
                    data[i] = &self.empty_bytes;
                }
            }

            // create new entity
            const entity = Entity{ .id = self.entity_references.items.len };
            var new_archetype: bool = undefined;

            // get the index of the archetype in the node
            const archetype_index = index_path[index_path.len - 1].component_index - (index_path.len - 1);
            const path_index = blk1: {
                if (entity_node.archetypes[archetype_index]) |arche| {
                    try arche.interface.registerEntity(entity, &data);
                    new_archetype = false;
                    break :blk1 arche.path_index;
                } else {
                    // register path
                    const arche_path_index = blk2: {
                        const index = self.archetype_paths.items.len;
                        var archetype_path = ArchetypePath{
                            .len = index_path.len,
                            .indices = undefined,
                        };
                        for (index_path) |sub_path, i| {
                            archetype_path.indices[i] = sub_path.component_index - @intCast(u15, i);
                        }
                        try self.archetype_paths.append(archetype_path);
                        break :blk2 index;
                    };

                    comptime var components_arr: [index_path.len]type = undefined;
                    inline for (index_path) |path, i| {
                        components_arr[i] = @TypeOf(initial_state[path.state_index]);
                    }
                    const Archetype = archetype.FromTypesArray(&components_arr);
                    var archetype_byte_location = try self.allocator.create(Archetype);
                    archetype_byte_location.* = Archetype.init(self.allocator);

                    const i_archetype = archetype_byte_location.archetypeInterface();
                    try i_archetype.registerEntity(entity, &data);
                    entity_node.archetypes[archetype_index] = Node.Arch{
                        .path_index = arche_path_index,
                        .struct_bytes = std.mem.asBytes(archetype_byte_location),
                        .interface = i_archetype,
                    };

                    new_archetype = true;
                    break :blk1 arche_path_index;
                }
            };

            // register a new component reference to able to locate entity
            try self.entity_references.append(EntityRef{
                .type_index = @intCast(u15, path_index),
            });
            errdefer _ = self.entity_references.pop();

            return std.meta.Tuple(&[_]type{ bool, Entity }){ new_archetype, entity };
        }

        /// Assign the component value to an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub inline fn setComponent(self: *ArcheContainer, entity: Entity, component: anytype) IArchetype.Error!bool {
            const zone = ztracy.ZoneNC(@src(), "Container setComponent", Color.arche_container);
            defer zone.End();

            const component_index = comptime componentIndex(@TypeOf(component));

            // get the archetype of the entity
            if (self.getArchetypeWithEntity(entity)) |arche| {
                // try to update component in current archetype
                if (arche.interface.setComponent(entity, component)) |ok| {
                    // ok we don't need to do anymore
                    _ = ok;
                } else |err| {
                    switch (err) {
                        // component is not part of current archetype
                        error.ComponentMissing => {
                            const old_path = self.archetype_paths.items[arche.path_index];
                            var new_component_index: usize = 0;
                            const new_path = blk1: {
                                // the new path of the entity will be based on its current path
                                var path = ArchetypePath{
                                    .len = old_path.len + 1,
                                    .indices = undefined,
                                };
                                std.mem.copy(u16, &path.indices, old_path.indices[0..old_path.len]);

                                // loop old path and find the correct order to insert the new component
                                new_component_index = blk2: {
                                    for (path.indices[0..old_path.len]) |step, depth| {
                                        const existing_component_index = step + depth;
                                        if (existing_component_index > component_index) {
                                            break :blk2 depth;
                                        }
                                    }
                                    // component is the last component
                                    break :blk2 old_path.len;
                                };

                                path.indices[new_component_index] = @intCast(u15, component_index - new_component_index);
                                for (old_path.indices[new_component_index..old_path.len]) |step, i| {
                                    const index = new_component_index + i + 1;
                                    path.indices[index] = step - 1;
                                }

                                break :blk1 path;
                            };

                            var new_archetype_created: bool = undefined;
                            const new_arche: Node.Arch = blk1: {
                                var arche_node = blk: {
                                    var current_node: Node = self.root_node;
                                    for (new_path.indices[0 .. new_path.len - 1]) |step, depth| {
                                        if (current_node.children[step]) |some| {
                                            current_node = some;
                                        } else {
                                            // create new node and set it as current node
                                            current_node.children[step] = try Node.init(
                                                self.allocator,
                                                current_node.children.len - 1,
                                                self.archetype_paths.items.len,
                                            );
                                            current_node = current_node.children[step].?;

                                            // register new node path
                                            var archetype_path = ArchetypePath{
                                                .len = depth + 1,
                                                .indices = undefined,
                                            };
                                            for (new_path.indices[0..archetype_path.len]) |sub_path, i| {
                                                archetype_path.indices[i] = sub_path;
                                            }
                                            try self.archetype_paths.append(archetype_path);
                                        }
                                    }
                                    break :blk current_node;
                                };

                                const archetype_index = new_path.indices[new_path.len - 1];
                                if (arche_node.archetypes[archetype_index]) |some| {
                                    new_archetype_created = false;
                                    break :blk1 some;
                                } else {
                                    var type_hashes: [len]u64 = undefined;
                                    var type_sizes: [len]usize = undefined;
                                    for (new_path.indices[0..new_path.len]) |step, i| {
                                        type_hashes[i] = self.component_hashes[step + i];
                                        type_sizes[i] = self.component_sizes[step + i];
                                    }

                                    // register archetype path
                                    try self.archetype_paths.append(new_path);

                                    // create new opaque archetype
                                    var archetype_address = try self.allocator.create(OpaqueArchetype);
                                    archetype_address.* = OpaqueArchetype.init(self.allocator, type_hashes[0..new_path.len], type_sizes[0..new_path.len]) catch {
                                        return IArchetype.Error.OutOfMemory;
                                    };

                                    const i_archetype = archetype_address.archetypeInterface();
                                    arche_node.archetypes[archetype_index] = Node.Arch{
                                        .path_index = self.archetype_paths.items.len - 1,
                                        .struct_bytes = std.mem.asBytes(archetype_address),
                                        .interface = i_archetype,
                                    };

                                    new_archetype_created = true;
                                    break :blk1 arche_node.archetypes[archetype_index].?;
                                }
                            };

                            var data: [len][]u8 = undefined;
                            inline for (component_info) |_, i| {
                                var buf: [biggest_component_size]u8 = undefined;
                                data[i] = &buf;
                            }

                            // remove the entity and it's components from the old archetype
                            try arche.interface.swapRemoveEntity(entity, data[0..old_path.len]);

                            // insert the new component at it's correct location
                            var rhd = data[new_component_index..new_path.len];
                            std.mem.rotate([]u8, rhd, rhd.len);
                            data[new_component_index] = &std.mem.toBytes(component);

                            // register the entity in the new archetype
                            try new_arche.interface.registerEntity(entity, data[0..new_path.len]);

                            // update entity reference
                            self.entity_references.items[entity.id] = EntityRef{
                                .type_index = @intCast(u15, new_arche.path_index),
                            };

                            return new_archetype_created;
                        },
                        error.OutOfMemory => return IArchetype.Error.OutOfMemory,
                        // if this happen, then the container is in an invalid state
                        error.EntityMissing => {
                            unreachable;
                        },
                    }
                }
            }
            return false;
        }

        /// Remove the Component type from an entity
        /// Errors:
        ///     - EntityMissing: if the entity does not exist
        ///     - OutOfMemory: if OOM
        /// Return:
        ///     True if a new archetype was created for this operation
        pub inline fn removeComponent(self: *ArcheContainer, entity: Entity, comptime Component: type) !bool {
            if (self.hasComponent(entity, Component) == false) {
                return false;
            }

            // we know that archetype exist because hasComponent can only return if it does
            const old_arche = self.getArchetypeWithEntity(entity).?;
            const old_path = self.archetype_paths.items[old_arche.path_index];

            var data: [len][]u8 = undefined;
            inline for (component_info) |_, i| {
                var buf: [biggest_component_size]u8 = undefined;
                data[i] = &buf;
            }
            // remove the entity and it's components from the old archetype
            try old_arche.interface.swapRemoveEntity(entity, data[0..old_path.len]);

            if (old_path.len <= 1) {
                // update entity reference
                self.entity_references.items[entity.id] = EntityRef.@"void";
                return false;
            }

            var remove_component_index: usize = undefined;
            const new_path = blk: {
                const component_hash = comptime hashType(Component);

                var path = ArchetypePath{
                    .len = 0,
                    .indices = undefined,
                };

                var removed_step: bool = false;
                for (old_path.indices[0..old_path.len]) |step, i| {
                    const component_index = step + i;
                    if (self.component_hashes[component_index] != component_hash) {
                        path.indices[path.len] = if (removed_step) step + 1 else step;
                        path.len += 1;
                    } else {
                        remove_component_index = i;
                        removed_step = true;
                    }
                }

                break :blk path;
            };

            var arche_node = blk: {
                var current_node: Node = self.root_node;
                for (new_path.indices[0 .. new_path.len - 1]) |step, depth| {
                    if (current_node.children[step]) |some| {
                        current_node = some;
                    } else {
                        // create new node and set it as current node
                        current_node.children[step] = try Node.init(
                            self.allocator,
                            current_node.children.len - 1,
                            self.archetype_paths.items.len,
                        );
                        current_node = current_node.children[step].?;

                        // register new node path
                        var archetype_path = ArchetypePath{
                            .len = depth + 1,
                            .indices = undefined,
                        };
                        for (new_path.indices[0..archetype_path.len]) |sub_path, i| {
                            archetype_path.indices[i] = sub_path;
                        }
                        try self.archetype_paths.append(archetype_path);
                    }
                }
                break :blk current_node;
            };

            var new_archetype_created: bool = undefined;
            var new_archetype = blk: {
                const archetype_index = new_path.indices[new_path.len - 1];
                if (arche_node.archetypes[archetype_index]) |some| {
                    new_archetype_created = false;
                    break :blk some;
                } else {
                    var type_hashes: [len]u64 = undefined;
                    var type_sizes: [len]usize = undefined;
                    for (new_path.indices[0..new_path.len]) |step, i| {
                        type_hashes[i] = self.component_hashes[step + i];
                        type_sizes[i] = self.component_sizes[step + i];
                    }

                    // register archetype path
                    try self.archetype_paths.append(new_path);

                    // create new opaque archetype
                    var archetype_address = try self.allocator.create(OpaqueArchetype);
                    archetype_address.* = OpaqueArchetype.init(self.allocator, type_hashes[0..new_path.len], type_sizes[0..new_path.len]) catch {
                        return IArchetype.Error.OutOfMemory;
                    };

                    const i_archetype = archetype_address.archetypeInterface();
                    arche_node.archetypes[archetype_index] = Node.Arch{
                        .path_index = self.archetype_paths.items.len - 1,
                        .struct_bytes = std.mem.asBytes(archetype_address),
                        .interface = i_archetype,
                    };

                    new_archetype_created = true;
                    break :blk arche_node.archetypes[archetype_index].?;
                }
            };

            // remove the component if it is not the last element
            if (remove_component_index < new_path.len - 1) {
                var rhd = data[remove_component_index + 1 .. new_path.len];
                std.mem.copy([]u8, data[remove_component_index..], rhd);
            }

            // register the entity in the new archetype
            try new_archetype.interface.registerEntity(entity, data[0..new_path.len]);

            // update entity reference
            self.entity_references.items[entity.id] = EntityRef{
                .type_index = @intCast(u15, new_archetype.path_index),
            };

            return new_archetype_created;
        }

        pub inline fn getTypeHashes(self: ArcheContainer, entity: Entity) ?[]u64 {
            const ref = switch (self.entity_references.items[entity.id]) {
                EntityRef.@"void" => return null,
                EntityRef.type_index => |index| index,
            };
            const path = self.archetype_paths.items[ref];

            var hashes: [len]u64 = undefined;
            for (path.indices[0..path.len]) |step, i| {
                hashes[i] = self.component_hashes[step + i];
            }

            // TODO: Returning stack memory ok for inline?
            return hashes[0..path.len];
        }

        pub inline fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            // verify that component exist in storage
            _ = comptime componentIndex(Component);
            // get the archetype of the entity
            const arche = self.getArchetypeWithEntity(entity) orelse return false;
            return arche.interface.hasComponent(Component);
        }

        /// Query archetypes containing all components listed in component_hashes
        /// caller own the returned memory
        pub inline fn getArchetypesWithComponents(self: ArcheContainer, allocator: Allocator, component_hashes: []const u64) Allocator.Error![]IArchetype {
            var path: [len]u16 = undefined;
            for (component_hashes) |requested_hash, i| {
                path[i] = blk: {
                    for (self.component_hashes[i..]) |stored_hash, step| {
                        if (requested_hash == stored_hash) {
                            break :blk @intCast(u15, step + i);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }
            var resulting_archetypes = ArrayList(IArchetype).init(allocator);
            try self.root_node.getIArchetypesWithComponents(path[0..component_hashes.len], &resulting_archetypes, 0);

            return resulting_archetypes.toOwnedSlice();
        }

        pub inline fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) IArchetype.Error!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
            defer zone.End();
            const arche = self.getArchetypeWithEntity(entity) orelse return IArchetype.Error.ComponentMissing;
            return arche.interface.getComponent(entity, Component);
        }

        inline fn getArchetypeWithEntity(self: ArcheContainer, entity: Entity) ?*Node.Arch {
            const ref = switch (self.entity_references.items[entity.id]) {
                EntityRef.@"void" => return null,
                EntityRef.type_index => |index| index,
            };
            const path = self.archetype_paths.items[ref];

            var entity_node = self.getNodeWithPath(path);

            // if entity is not spoofed, then this is always defined
            return &entity_node.archetypes[path.indices[path.len - 1]].?;
        }

        inline fn getNodeWithPath(self: ArcheContainer, path: ArchetypePath) Node {
            var current_node: Node = self.root_node;
            for (path.indices[0 .. path.len - 1]) |step| {
                // if node is null, then entity has been modified externally, or there is a
                // bug in ecez
                current_node = current_node.children[step].?;
            }
            return current_node;
        }

        inline fn componentIndex(comptime Component: type) comptime_int {
            inline for (component_info) |info, i| {
                if (Component == info.@"type") {
                    return i;
                }
            }
            @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
        }
    };
}

const TestContainer = FromComponents(&Testing.AllComponentsArr);

test "ArcheContainer init + deinit is idempotent" {
    const container = try TestContainer.init(testing.allocator);
    container.deinit();
}

test "ArcheContainer createEntity & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const a = Testing.Component.A{ .value = 1 };
    const b = Testing.Component.B{ .value = 2 };
    const c = Testing.Component.C{};
    const entity = (try container.createEntity(.{ a, b, c }))[1];

    try testing.expectEqual(a, try container.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(b, try container.getComponent(entity, Testing.Component.B));
    try testing.expectEqual(c, try container.getComponent(entity, Testing.Component.C));
}

test "ArcheContainer setComponent & getComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const entity = (try container.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.C{},
    }))[1];

    const a = Testing.Component.A{ .value = 40 };
    _ = try container.setComponent(entity, a);
    try testing.expectEqual(a, try container.getComponent(entity, Testing.Component.A));

    const b = Testing.Component.B{ .value = 42 };
    _ = try container.setComponent(entity, b);
    try testing.expectEqual(b, try container.getComponent(entity, Testing.Component.B));
}

test "ArcheContainer getTypeHashes works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const entity = (try container.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.C{},
    }))[1];

    try testing.expectEqualSlices(
        u64,
        &[_]u64{ ecez_query.hashType(Testing.Component.A), ecez_query.hashType(Testing.Component.C) },
        container.getTypeHashes(entity).?,
    );
}

test "ArcheContainer hasComponent works" {
    var container = try TestContainer.init(testing.allocator);
    defer container.deinit();

    const entity = (try container.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.C{},
    }))[1];

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

    const entity = (try container.createEntity(.{Testing.Component.C{}}))[1];
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{c_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{b_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{a_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.A{});
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{c_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{b_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 0), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{a_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }

    _ = try container.setComponent(entity, Testing.Component.B{});
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{c_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 3), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{b_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(testing.allocator, &[_]u64{a_hash});
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }

    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, c_hash },
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 2), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ a_hash, b_hash },
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
    {
        const arch = try container.getArchetypesWithComponents(
            testing.allocator,
            &[_]u64{ b_hash, c_hash },
        );
        defer testing.allocator.free(arch);
        try testing.expectEqual(@as(usize, 1), arch.len);
    }
}
