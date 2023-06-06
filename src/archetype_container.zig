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

    const Step = enum(u1) {
        left = 0,
        right = 1,
    };
    const NodeType = enum(u1) {
        root,
        not_root,
    };
    // TODO: rename bitnode
    // TODO: type safety: 2 nodes, a OneNode and ZeroNode where ZeroNode does not have bidirectional_ref: ?BidirectRef,
    // A single node in the binary tree
    const BinaryNode = struct {
        pub const BidirectRef = struct {
            bit_path_index: u32,
            opaque_arcehetype_index: u32,
        };
        const Ref = struct {
            type: NodeType,
            self_index: u31,
        };

        const Node = @This();

        ref: Ref,
        bit_offset: u32,
        child_indices: [2]?u32,
        bidirectional_ref: ?BidirectRef,

        pub fn root() Node {
            return Node{
                .ref = .{ .type = .root, .self_index = 0 },
                .bit_offset = 0,
                .child_indices = .{ null, null },
                .bidirectional_ref = null,
            };
        }

        pub fn empty(self_index: usize, bit_offset: u32) Node {
            return Node{
                .ref = .{ .type = .not_root, .self_index = @intCast(u31, self_index) },
                .bit_offset = bit_offset,
                .child_indices = .{ null, null },
                .bidirectional_ref = null,
            };
        }
    };

    return struct {
        const ArcheContainer = @This();

        const void_index = 0;

        // A single integer that represent the full path of an opaque archetype
        pub const BitPath = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = submitted_components.len,
        } });

        pub const BitPathShift = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = std.math.log2_int_ceil(BitPath, submitted_components.len),
        } });

        allocator: Allocator,
        node_bit_paths: ArrayList(BitPath),
        entity_references: ArrayList(EntityRef),
        archetypes: ArrayList(OpaqueArchetype),
        nodes: ArrayList(BinaryNode),

        component_hashes: [submitted_components.len]u64,
        component_sizes: [submitted_components.len]usize,

        empty_bytes: [0]u8,

        pub fn init(allocator: Allocator) error{OutOfMemory}!ArcheContainer {
            const pre_alloc_amount = 32;

            var node_bit_paths = try ArrayList(BitPath).initCapacity(allocator, pre_alloc_amount);
            errdefer node_bit_paths.deinit();

            // append special "void" path
            try node_bit_paths.append(0);

            var nodes = try ArrayList(BinaryNode).initCapacity(allocator, pre_alloc_amount);
            errdefer nodes.deinit();
            // we append a "void" node that should always exist
            nodes.appendAssumeCapacity(BinaryNode.root());

            comptime var component_hashes: [submitted_components.len]u64 = undefined;
            comptime var component_sizes: [submitted_components.len]usize = undefined;
            inline for (component_info, &component_hashes, &component_sizes) |info, *hash, *size| {
                hash.* = info.hash;
                size.* = @sizeOf(info.type);
            }

            var entity_references = try ArrayList(EntityRef).initCapacity(allocator, pre_alloc_amount);
            errdefer entity_references.deinit();

            var archetypes = try ArrayList(OpaqueArchetype).initCapacity(allocator, pre_alloc_amount);
            errdefer archetypes.deinit();

            return ArcheContainer{
                .allocator = allocator,
                .node_bit_paths = node_bit_paths,
                .entity_references = entity_references,
                .archetypes = archetypes,
                .nodes = nodes,
                .component_hashes = component_hashes,
                .component_sizes = component_sizes,
                .empty_bytes = .{},
            };
        }

        pub inline fn deinit(self: *ArcheContainer) void {
            self.node_bit_paths.deinit();
            self.entity_references.deinit();
            self.nodes.deinit();

            for (self.archetypes.items) |*archetype| {
                archetype.deinit();
            }
            self.archetypes.deinit();
        }

        pub inline fn clearRetainingCapacity(self: *ArcheContainer) void {
            const zone = ztracy.ZoneNC(@src(), "Container clear", Color.arche_container);
            defer zone.End();

            self.entity_references.clearRetainingCapacity();
            self.entity_references.appendAssumeCapacity(undefined);

            for (&self.archetypes.items) |*archetype| {
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

            const ArchetypeStruct = @TypeOf(initial_state);
            const arche_struct_info = blk: {
                const info = @typeInfo(ArchetypeStruct);
                if (info != .Struct) {
                    @compileError("expected initial_state to be of type struct");
                }
                break :blk info.Struct;
            };

            // create new entity
            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };

            // if no initial_state
            if (arche_struct_info.fields.len == 0) {
                // register a void reference to able to locate empty entity
                try self.entity_references.append(void_index);
                return CreateEntityResult{
                    .new_archetype_container = false,
                    .entity = entity,
                };
            }

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

            // get the archetype of the entity
            if (self.entityToBinaryNodeIndex(entity)) |node_index| {
                const current_entity_node: BinaryNode = self.nodes.items[node_index];
                const node_bidirect_ref: BinaryNode.BidirectRef = current_entity_node.bidirectional_ref.?;

                // try to update component in current archetype
                if (self.archetypes.items[node_bidirect_ref.opaque_arcehetype_index].setComponent(entity, component)) |ok| {
                    // ok we don't need to do anymore
                    _ = ok;
                } else |err| {
                    switch (err) {
                        // component is not part of current archetype
                        error.ComponentMissing => {
                            const new_component_global_index = comptime componentIndex(@TypeOf(component));

                            const old_bit_path = self.node_bit_paths.items[node_bidirect_ref.bit_path_index];
                            const new_path = old_bit_path | (1 << new_component_global_index);

                            var total_local_components: u32 = 0;
                            var new_node: *BinaryNode = node_search_blk: {
                                var state_path_bits = new_path;
                                var current_node = &self.nodes.items[0];
                                var loop_iter: u32 = 0;

                                // TODO: use @ctz
                                while (state_path_bits != 0) : (state_path_bits >>= 1) {
                                    const step = @intCast(usize, state_path_bits & 1);
                                    if (current_node.child_indices[step]) |index| {
                                        current_node = &self.nodes.items[index];
                                    } else {
                                        const child_index = self.nodes.items.len;
                                        try self.nodes.append(BinaryNode.empty(child_index, loop_iter));

                                        current_node.child_indices[step] = @intCast(u32, child_index);
                                        current_node = &self.nodes.items[child_index];

                                        loop_iter += 1;
                                    }

                                    total_local_components += 1;
                                }

                                break :node_search_blk current_node;
                            };

                            // TODO: use same logic as in remove
                            // we need the index of the new component in the sequence of components are tied to the entity
                            var new_component_local_index: ?usize = null;

                            var new_archetype_created: bool = maybe_create_archetype_blk: {
                                // if the archetype already exist
                                if (new_node.bidirectional_ref != null) {
                                    break :maybe_create_archetype_blk false;
                                }

                                // register archetype bit path
                                try self.node_bit_paths.append(new_path);
                                errdefer _ = self.node_bit_paths.pop();

                                // get the type hashes and sizes
                                var type_hashes: [submitted_components.len]u64 = undefined;
                                var type_sizes: [submitted_components.len]usize = undefined;
                                {
                                    var path = new_path;
                                    var assigned_components: u32 = 0;
                                    var cursor: u32 = 0;
                                    for (0..total_local_components) |component_index| {
                                        const step = @intCast(BitPathShift, @ctz(path));
                                        std.debug.assert((path & 1) == 1);

                                        type_hashes[component_index] = self.component_hashes[cursor];
                                        type_sizes[component_index] = self.component_sizes[cursor];
                                        if (new_component_local_index == null and cursor == new_component_global_index) {
                                            new_component_local_index = component_index;
                                        }

                                        cursor += step + 1;
                                        path = (path >> step) >> 1;
                                        assigned_components += 1;
                                    }

                                    std.debug.assert(assigned_components == total_local_components);
                                    std.debug.assert(new_component_local_index != null);
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

                                const bit_path_index = self.node_bit_paths.items.len;
                                try self.node_bit_paths.append(new_path);
                                errdefer _ = self.node_bit_paths.pop();

                                // update this entity's node to contain the new archetype
                                new_node.bidirectional_ref = BinaryNode.BidirectRef{
                                    .bit_path_index = @intCast(u32, bit_path_index),
                                    .opaque_arcehetype_index = @intCast(u32, opaque_archetype_index),
                                };

                                break :maybe_create_archetype_blk true;
                            };

                            var data: [submitted_components.len][]u8 = undefined;
                            inline for (component_info, 0..) |_, i| {
                                var buf: [biggest_component_size]u8 = undefined;
                                data[i] = &buf;
                            }

                            const old_node_index = self.bitPathToBinaryNodeIndex(old_bit_path);
                            const old_node = self.nodes.items[old_node_index];
                            const old_archetype_index = old_node.bidirectional_ref.?.opaque_arcehetype_index;

                            // remove the entity and it's components from the old archetype
                            try self.archetypes.items[old_archetype_index].rawSwapRemoveEntity(entity, data[0 .. total_local_components - 1]);

                            // insert the new component at it's correct location
                            const new_component_local_index_unwrapped = new_component_local_index.?;
                            var rhd = data[new_component_local_index_unwrapped..total_local_components];
                            std.mem.rotate([]u8, rhd, rhd.len - 1);
                            std.mem.copy(u8, data[new_component_local_index_unwrapped], std.mem.asBytes(&component));

                            // register the entity in the new archetype
                            const new_archetype_index = new_node.bidirectional_ref.?.opaque_arcehetype_index;
                            try self.archetypes.items[new_archetype_index].rawRegisterEntity(entity, data[0..total_local_components]);

                            // update entity reference
                            self.entity_references.items[entity.id] = @intCast(
                                EntityRef,
                                new_node.bidirectional_ref.?.bit_path_index,
                            );

                            return new_archetype_created;
                        },
                        // if this happen, then the container is in an invalid state
                        error.EntityMissing => {
                            unreachable;
                        },
                    }
                }
            } else {
                // workaround for https://github.com/ziglang/zig/issues/12963
                const T = std.meta.Tuple(&[_]type{@TypeOf(component)});
                var t: T = undefined;
                t[0] = component;

                // this entity has no previous storage, initialize some if needed
                return self.initializeEntityStorage(entity, t);
            }
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

            // we know that archetype exist because hasComponent can only return if it does
            const old_node_index = self.entityToBinaryNodeIndex(entity).?;
            const old_entity_node: BinaryNode = self.nodes.items[old_node_index];
            const old_node_bidirect_ref: BinaryNode.BidirectRef = old_entity_node.bidirectional_ref.?;

            var data: [submitted_components.len][]u8 = undefined;
            inline for (component_info, 0..) |_, i| {
                var buf: [biggest_component_size]u8 = undefined;
                data[i] = &buf;
            }

            // get old path and count how many components are stored in the entity
            const old_bit_path = self.node_bit_paths.items[old_node_bidirect_ref.bit_path_index];
            const old_component_count = @popCount(old_bit_path);

            // remove the entity and it's components from the old archetype
            try self.archetypes.items[old_node_bidirect_ref.opaque_arcehetype_index].rawSwapRemoveEntity(entity, data[0..old_component_count]);
            // TODO: handle error, this currently can lead to corrupt entities!

            // if the entity only had a single component previously
            if (old_component_count == 1) {
                // update entity reference to be of void type
                self.entity_references.items[entity.id] = void_index;
                return false;
            }

            const global_remove_component_index = comptime componentIndex(Component);
            const remove_bit = @as(BitPath, 1 << global_remove_component_index);
            const new_path = old_bit_path & ~remove_bit;

            var local_remove_component_index: usize = remove_index_calc_blk: {
                // calculate mask that filters out most significant bits
                const remove_after_bits_mask = remove_bit - 1;
                const remove_index = @popCount(old_bit_path & remove_after_bits_mask);
                break :remove_index_calc_blk remove_index;
            };

            var new_node: *BinaryNode = node_search_blk: {
                var state_path_bits = new_path;
                var current_node = &self.nodes.items[0];
                var loop_iter: u32 = 0;

                while (state_path_bits != 0) : (state_path_bits >>= 1) {
                    const step = @intCast(usize, state_path_bits & 1);
                    if (current_node.child_indices[step]) |index| {
                        current_node = &self.nodes.items[index];
                    } else {
                        const child_index = self.nodes.items.len;
                        try self.nodes.append(BinaryNode.empty(child_index, loop_iter));

                        current_node.child_indices[step] = @intCast(u32, child_index);
                        current_node = &self.nodes.items[child_index];

                        loop_iter += 1;
                    }
                }

                break :node_search_blk current_node;
            };

            const new_component_count = old_component_count - 1;
            var new_archetype_created = archetype_create_blk: {
                // if archetype already exist
                if (new_node.bidirectional_ref != null) {
                    break :archetype_create_blk false;
                } else {
                    // get the type hashes and sizes
                    var type_hashes: [submitted_components.len]u64 = undefined;
                    var type_sizes: [submitted_components.len]usize = undefined;
                    {
                        var path = new_path;
                        var cursor: u32 = 0;
                        for (0..new_component_count) |component_index| {
                            const step = @ctz(path);
                            std.debug.assert((path >> step) == 1);

                            type_hashes[component_index] = self.component_hashes[cursor];
                            type_sizes[component_index] = self.component_sizes[cursor];

                            cursor += @intCast(u32, step);
                            path = (path >> step) >> 1;
                        }
                    }

                    // register archetype path
                    try self.node_bit_paths.append(new_path);
                    errdefer _ = self.node_bit_paths.pop();

                    var new_archetype = try OpaqueArchetype.init(
                        self.allocator,
                        type_hashes[0..new_component_count],
                        type_sizes[0..new_component_count],
                    );
                    errdefer new_archetype.deinit();

                    const opaque_archetype_index = self.archetypes.items.len;
                    try self.archetypes.append(new_archetype);
                    errdefer _ = self.archetypes.pop();

                    const bit_path_index = self.node_bit_paths.items.len;
                    try self.node_bit_paths.append(new_path);
                    errdefer _ = self.node_bit_paths.pop();

                    // update this entity's node to contain the new archetype
                    new_node.bidirectional_ref = BinaryNode.BidirectRef{
                        .bit_path_index = @intCast(u32, bit_path_index),
                        .opaque_arcehetype_index = @intCast(u32, opaque_archetype_index),
                    };

                    break :archetype_create_blk true;
                }
            };

            var rhd = data[local_remove_component_index..old_component_count];
            std.mem.rotate([]u8, rhd, 1);

            // register the entity in the new archetype
            try self.archetypes.items[new_node.bidirectional_ref.?.opaque_arcehetype_index].rawRegisterEntity(
                entity,
                data[0..new_component_count],
            );

            // update entity reference
            self.entity_references.items[entity.id] = @intCast(
                EntityRef,
                new_node.bidirectional_ref.?.bit_path_index,
            );

            return new_archetype_created;
        }

        pub inline fn getTypeHashes(self: ArcheContainer, entity: Entity) ?[]const u64 {
            // get node index, or return empty slice if entity is a void type
            const node_index = self.entityToBinaryNodeIndex(entity) orelse return self.component_hashes[0..0];

            const opaque_archetype_index = self.nodes.items[node_index].bidirectional_ref.?.opaque_arcehetype_index;
            return self.archetypes.items[opaque_archetype_index].getTypeHashes();
        }

        pub inline fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            // verify that component exist in storage
            _ = comptime componentIndex(Component);

            // get node index, or return false if entity has void type
            const node_index = self.entityToBinaryNodeIndex(entity) orelse return false;
            const opaque_archetype_index = self.nodes.items[node_index].bidirectional_ref.?.opaque_arcehetype_index;
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
        ) error{ InvalidQuery, OutOfMemory }![]*OpaqueArchetype {
            var include_bits: BitPath = 0;
            for (include_component_hashes, 0..) |include_hash, i| {
                include_bits |= blk: {
                    for (self.component_hashes[i..], i..) |stored_hash, step| {
                        if (include_hash == stored_hash) {
                            break :blk @as(BitPath, 1) << @intCast(BitPathShift, step);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            var exclude_bits: BitPath = 0;
            for (exclude_component_hashes, 0..) |exclude_hash, i| {
                exclude_bits |= blk: {
                    for (self.component_hashes[i..], i..) |stored_hash, step| {
                        if (exclude_hash == stored_hash) {
                            break :blk @as(BitPath, 1) << @intCast(BitPathShift, step);
                        }
                    }
                    unreachable; // should be compile type guards before we reach this point ...
                };
            }

            if (include_bits & exclude_bits != 0) {
                // cant request components that are also excluded
                return error.InvalidQuery;
            }

            var resulting_archetypes = ArrayList(*OpaqueArchetype).init(allocator);
            errdefer resulting_archetypes.deinit();

            // TODO: if total count is low, then it should be cheaper to just loop bit paths and match with including and excluding

            // We use morris traversal: source https://www.geeksforgeeks.org/inorder-tree-traversal-without-recursion/
            var bit_location: BitPath = 0;
            var current_node_index: usize = 0;
            var current_node: *BinaryNode = &self.nodes.items[current_node_index];
            search_loop: while (true) {
                // TODO: comment!
                if (current_node.child_indices[@enumToInt(Step.left)] == null) {
                    current_node_index = current_node.child_indices[@enumToInt(Step.right)].?;
                    current_node = &self.nodes.items[current_node_index];

                    bit_location |= @as(BitPath, 1) << @intCast(BitPathShift, current_node.bit_offset);

                    if ((bit_location & include_bits) == include_bits) {
                        if (current_node.bidirectional_ref) |bidirection_ref| {
                            try resulting_archetypes.append(&self.archetypes.items[bidirection_ref.opaque_arcehetype_index]);
                        }
                    }
                } else {
                    const pre_left_index = current_node.child_indices[@enumToInt(Step.left)].?;
                    var predecessor: *BinaryNode = &self.nodes.items[pre_left_index];
                    pre_loop: while (predecessor.child_indices[@enumToInt(Step.right)]) |right_child_index| {
                        if (predecessor == current_node) {
                            break :pre_loop;
                        }

                        predecessor = &self.nodes.items[right_child_index];
                    }

                    if (predecessor.child_indices[@enumToInt(Step.right)] == null) {
                        predecessor.child_indices[@enumToInt(Step.right)] = @intCast(u32, current_node_index);
                        current_node_index = current_node.child_indices[@enumToInt(Step.left)].?;
                        current_node = &self.nodes.items[current_node_index];
                    } else {
                        predecessor.child_indices[@enumToInt(Step.right)] = null;

                        if ((bit_location & include_bits) == include_bits) {
                            if (current_node.bidirectional_ref) |bidirection_ref| {
                                try resulting_archetypes.append(&self.archetypes.items[bidirection_ref.opaque_arcehetype_index]);
                            }
                        }

                        if (current_node.child_indices[@enumToInt(Step.right)]) |right_index| {
                            current_node_index = right_index;
                            current_node = &self.nodes.items[current_node_index];

                            bit_location |= @as(BitPath, 1) << @intCast(BitPathShift, current_node.bit_offset);
                        } else {
                            break :search_loop;
                        }
                    }
                }
            }

            // search_loop: while (true) {
            //     var did_step_down = false;

            //     // if query does not care about next left step, then we can step left if we have a left node
            //     if (include_bits & (1 << depth) == 0 and
            //         exclude_bits & (1 << depth) == 0 and
            //         current_node.child_indices[@enumToInt(Step.left)] != null)
            //     {
            //         const left_node_index = current_node.child_indices[@enumToInt(Step.left)].?;
            //         current_node = self.nodes.items[left_node_index];

            //         depth += 1;
            //         did_step_down = true;

            //         // if query does not care about next right step, then we can step right if we have a right node
            //     } else if (exclude_bits & (1 << depth) == 0 and
            //         current_node.child_indices[@enumToInt(Step.right)] != null)
            //     {
            //         const right_node_index = current_node.child_indices[@enumToInt(Step.left)].?;
            //         current_node = self.nodes.items[right_node_index];

            //         depth += 1;
            //         did_step_down = true;
            //     }

            //     if (did_step_down == false) {}
            // }
            // for (self.node_bit_paths.items) |bit_path| {
            //     if ((bit_path & include_bits) == include_bits and (bit_path & exclude_bits) == 0) {
            //         resulting_archetypes.append()
            //     }
            // }

            return resulting_archetypes.toOwnedSlice();
        }

        pub fn getComponent(self: ArcheContainer, entity: Entity, comptime Component: type) ecez_error.ArchetypeError!Component {
            const zone = ztracy.ZoneNC(@src(), "Container getComponent", Color.arche_container);
            defer zone.End();

            const node_index = self.entityToBinaryNodeIndex(entity) orelse return error.ComponentMissing;
            const opaque_archetype_index = self.nodes.items[node_index].bidirectional_ref.?.opaque_arcehetype_index;

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
            if (arche_struct_info.fields.len == 0) {
                // no storage should be created if initial state is empty
                @compileError("called initializeEntityStorage with empty initial_state is illegal");
            }

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
            const initial_state_path_bits: BitPath = comptime bit_calc_blk: {
                var bits: BitPath = 0;
                outer_loop: inline for (sorted_initial_state_field_types, 0..) |initial_state_field_type, field_index| {
                    inline for (submitted_components[field_index..], 0..) |Component, comp_index| {
                        if (initial_state_field_type == Component) {
                            bits |= 1 << (field_index + comp_index);
                            continue :outer_loop;
                        }
                    }
                    @compileError(@typeName(initial_state_field_type) ++ " is not a World registered component type");
                }
                break :bit_calc_blk bits;
            };

            // get the node that will store the new entity and create the node path while required
            var entity_node: *BinaryNode = node_search_blk: {
                var state_path_bits = initial_state_path_bits;
                var current_node = &self.nodes.items[0];
                var loop_iter: u32 = 0;

                while (state_path_bits != 0) : (state_path_bits >>= 1) {
                    const step = @intCast(usize, state_path_bits & 1);
                    if (current_node.child_indices[step]) |index| {
                        current_node = &self.nodes.items[index];
                    } else {
                        const child_index = self.nodes.items.len;
                        try self.nodes.append(BinaryNode.empty(child_index, loop_iter));

                        current_node.child_indices[step] = @intCast(u32, child_index);
                        current_node = &self.nodes.items[child_index];
                        loop_iter += 1;
                    }
                }

                break :node_search_blk current_node;
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

            var new_archetype_created: bool = regiser_entity_blk: {
                // if the archetype already exist
                if (entity_node.bidirectional_ref) |ref| {
                    try self.archetypes.items[ref.opaque_arcehetype_index].rawRegisterEntity(entity, &sorted_state_data);
                    break :regiser_entity_blk false;
                }

                // register archetype bit path
                const bit_path_index = self.node_bit_paths.items.len;
                try self.node_bit_paths.append(initial_state_path_bits);
                errdefer _ = self.node_bit_paths.pop();

                comptime var type_hashes: [sorted_initial_state_field_types.len]u64 = undefined;
                comptime var type_sizes: [sorted_initial_state_field_types.len]usize = undefined;
                inline for (&type_hashes, &type_sizes, sorted_initial_state_field_types) |*type_hash, *type_size, Component| {
                    type_hash.* = comptime ecez_query.hashType(Component);
                    type_size.* = comptime @sizeOf(Component);
                }

                var new_archetype = try OpaqueArchetype.init(self.allocator, &type_hashes, &type_sizes);
                errdefer new_archetype.deinit();

                const opaque_archetype_index = self.archetypes.items.len;
                try self.archetypes.append(new_archetype);
                errdefer _ = self.archetypes.pop();

                try self.archetypes.items[opaque_archetype_index].rawRegisterEntity(entity, &sorted_state_data);
                // TODO: errdefer self.archetypes.items[opaque_archetype_index].removeEntity(); https://github.com/Avokadoen/ecez/issues/118

                // update this entity's node to contain the new archetype
                entity_node.bidirectional_ref = BinaryNode.BidirectRef{
                    .bit_path_index = @intCast(u32, bit_path_index),
                    .opaque_arcehetype_index = @intCast(u32, opaque_archetype_index),
                };

                break :regiser_entity_blk true;
            };

            // register a reference to able to locate entity
            self.entity_references.items[entity.id] = @intCast(EntityRef, entity_node.bidirectional_ref.?.bit_path_index);

            return new_archetype_created;
        }

        inline fn entityToBinaryNodeIndex(self: ArcheContainer, entity: Entity) ?usize {
            const ref = switch (self.entity_references.items[entity.id]) {
                void_index => return null, // void type
                else => |index| index,
            };
            const path = self.node_bit_paths.items[ref];

            return self.bitPathToBinaryNodeIndex(path);
        }

        inline fn bitPathToBinaryNodeIndex(self: ArcheContainer, path: BitPath) usize {
            var local_path = path;

            var current_node = &self.nodes.items[0];
            while (local_path != 0) : (local_path >>= 1) {
                const step = @intCast(usize, local_path & 1);
                const index = current_node.child_indices[step].?;
                current_node = &self.nodes.items[index];
            }

            return @intCast(usize, current_node.ref.self_index);
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
        container.getTypeHashes(entity).?,
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
