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
                .hash = ecez_query.hashType(Component),
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
        pub inline fn createEntity(self: *ArcheContainer, initial_state: anytype) !Entity {
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
                                break :blk2 @intCast(u16, j);
                            }
                        }
                        @compileError(@typeName(field.field_type) ++ " is not a registered component type");
                    };

                    path[i] = TypeMap{
                        .hash = ecez_query.hashType(field.field_type),
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
                            archetype_path.indices[i] = sub_path.component_index - @intCast(u16, i);
                        }
                        try self.archetype_paths.append(archetype_path);
                    }
                }
                break :blk current_node;
            };

            // create a component byte data view
            var data: [arche_struct_info.fields.len][]const u8 = undefined;
            inline for (index_path) |path, i| {
                data[i] = std.mem.asBytes(&initial_state[path.state_index]);
            }

            // create new entity
            const entity = Entity{ .id = self.entity_references.items.len };

            // get the index of the archetype in the node
            const archetype_index = index_path[index_path.len - 1].component_index - (index_path.len - 1);
            const path_index = blk1: {
                if (entity_node.archetypes[archetype_index]) |arche| {
                    try arche.interface.registerEntity(entity, &data);
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
                            archetype_path.indices[i] = sub_path.component_index - @intCast(u16, i);
                        }
                        try self.archetype_paths.append(archetype_path);
                        break :blk2 index;
                    };

                    comptime var components_arr: [index_path.len]type = undefined;
                    inline for (index_path) |path, i| {
                        components_arr[i] = @TypeOf(initial_state[path.state_index]);
                    }
                    const Archetype = archetype.FromTypesArray(&components_arr);
                    var archetype_byte_location = try self.allocator.alloc(u8, @sizeOf(Archetype));
                    var new_archetype = Archetype.init(self.allocator);
                    std.mem.copy(u8, archetype_byte_location, std.mem.asBytes(&new_archetype));

                    const i_archetype = new_archetype.archetypeInterface();
                    try i_archetype.registerEntity(entity, &data);
                    entity_node.archetypes[archetype_index] = Node.Arch{
                        .path_index = arche_path_index,
                        .struct_bytes = archetype_byte_location,
                        .interface = i_archetype,
                    };

                    break :blk1 arche_path_index;
                }
            };

            // register a new component reference to able to locate entity
            try self.entity_references.append(EntityRef{
                .type_path_index = @intCast(u16, path_index),
            });
            errdefer _ = self.entity_references.pop();

            return entity;
        }

        pub inline fn setComponent(self: *ArcheContainer, entity: Entity, component: anytype) IArchetype.Error!void {
            const zone = ztracy.ZoneNC(@src(), "Container setComponent", Color.arche_container);
            defer zone.End();

            const Component = @TypeOf(component);
            const component_index = blk: {
                inline for (component_info) |info, i| {
                    if (Component == info.@"type") {
                        break :blk i;
                    }
                }
                @compileError("component type " ++ @typeName(Component) ++ " is not a registered component type");
            };

            // get the archetype of the entity
            const arche = self.getArchetypeWithEntity(entity);

            // try to update component in current archetype
            if (arche.interface.setComponent(entity, component)) |ok| {
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

                            path.indices[new_component_index] = @intCast(u16, component_index - new_component_index);
                            for (old_path.indices[new_component_index..old_path.len]) |step, i| {
                                const index = new_component_index + i + 1;
                                path.indices[index] = step - 1;
                            }

                            break :blk1 path;
                        };

                        var arche_path_index: usize = undefined;
                        const new_arche: Node.Arch = blk1: {
                            const archetype_index = new_path.indices[new_path.len - 1];

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

                            if (arche_node.archetypes[archetype_index]) |some| {
                                break :blk1 some;
                            } else {
                                var type_hashes: [len]u64 = undefined;
                                var type_sizes: [len]usize = undefined;
                                for (new_path.indices[0..new_path.len]) |step, i| {
                                    type_hashes[i] = self.component_hashes[step + i];
                                    type_sizes[i] = self.component_sizes[step + i];
                                }

                                // register archetype path
                                arche_path_index = self.archetype_paths.items.len;
                                try self.archetype_paths.append(new_path);

                                // create new opaque archetype
                                var archetype_address = try self.allocator.create(OpaqueArchetype);
                                archetype_address.* = OpaqueArchetype.init(self.allocator, type_hashes[0..new_path.len], type_sizes[0..new_path.len]) catch {
                                    return IArchetype.Error.OutOfMemory;
                                };

                                const i_archetype = archetype_address.archetypeInterface();
                                arche_node.archetypes[archetype_index] = Node.Arch{
                                    .path_index = arche_path_index,
                                    .struct_bytes = std.mem.asBytes(archetype_address),
                                    .interface = i_archetype,
                                };

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
                            .type_path_index = @intCast(u16, arche_path_index),
                        };
                    },
                    error.OutOfMemory => return IArchetype.Error.OutOfMemory,
                    // if this happen, then the container is in an invalid state
                    error.EntityMissing => {
                        unreachable;
                    },
                }
            }
        }

        pub inline fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) IArchetype.Error!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
            defer zone.End();

            return self.getArchetypeWithEntity(entity).interface.getComponent(entity, Component);
        }

        inline fn getArchetypeWithEntity(self: ArcheContainer, entity: Entity) *Node.Arch {
            const ref = self.entity_references.items[entity.id];
            const path = self.archetype_paths.items[ref.type_path_index];

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
    };
}

test "ArcheContainer init + deinit is idempotent" {
    const Container = FromComponents(&Testing.AllComponentsArr);
    const container = try Container.init(testing.allocator);
    container.deinit();
}

test "ArcheContainer createEntity & getComponent works" {
    const Container = FromComponents(&Testing.AllComponentsArr);
    var container = try Container.init(testing.allocator);
    defer container.deinit();

    const a = Testing.Component.A{ .value = 1 };
    const b = Testing.Component.B{ .value = 2 };
    const c = Testing.Component.C{};
    const entity = try container.createEntity(.{ a, b, c });

    try testing.expectEqual(a, try container.getComponent(entity, Testing.Component.A));
    try testing.expectEqual(b, try container.getComponent(entity, Testing.Component.B));
    try testing.expectEqual(c, try container.getComponent(entity, Testing.Component.C));
}

test "ArcheContainer setComponent & getComponent works" {
    const Container = FromComponents(&Testing.AllComponentsArr);
    var container = try Container.init(testing.allocator);
    defer container.deinit();

    const entity0 = try container.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.C{},
    });

    const a = Testing.Component.A{ .value = 40 };
    try container.setComponent(entity0, a);
    try testing.expectEqual(a, try container.getComponent(entity0, Testing.Component.A));

    const b = Testing.Component.B{ .value = 42 };
    try container.setComponent(entity0, b);
    try testing.expectEqual(b, try container.getComponent(entity0, Testing.Component.B));
}
