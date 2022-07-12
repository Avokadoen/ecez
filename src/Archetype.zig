const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const query = @import("query.zig");

// const hashfn = @import("query.zig").hashfn;
const Entity = @import("entity_type.zig").Entity;
const EntityContext = struct {
    pub fn hash(self: EntityContext, e: Entity) u32 {
        _ = self;
        // id is already unique
        return e.id;
    }
    pub fn eql(self: EntityContext, e1: Entity, e2: Entity, index: usize) bool {
        _ = self;
        _ = index;
        return e1.id == e2.id;
    }
};
const EntityMap = std.ArrayHashMap(Entity, usize, EntityContext, false);

const Archetype = @This();

allocator: Allocator,

type_count: usize,
type_sizes: []const usize,
type_hashes: []const u64,

components: []std.ArrayList(u8),
entities: EntityMap,

// used in deinit
q: ?query.Runtime,

/// init a arcetype container, type query is the type compositions for this archetype
/// The archetype container does not account for duplicate types, or out-of-order type slices
pub inline fn initFromTypes(allocator: Allocator, comptime types: []const type) !Archetype {
    var type_sizes: [types.len]usize = undefined;
    var type_hashes: [types.len]u64 = undefined;
    inline for (types) |T, index| {
        type_sizes[index] = @sizeOf(T);
        type_hashes[index] = comptime query.hashType(T);
    }
    return init(allocator, type_sizes[0..], type_hashes[0..]);
}

/// init an archetype from runtime and take ownership of runtime data
pub inline fn initFromQueryRuntime(runtime: *query.Runtime) !Archetype {
    const components = try runtime.allocator.alloc(std.ArrayList(u8), runtime.len);
    errdefer runtime.allocator.free(components);
    for (components) |*component| {
        component.* = std.ArrayList(u8).init(runtime.allocator);
    }

    // Archetype now owns the query memory
    runtime.takeOwnership();

    return Archetype{
        .allocator = runtime.allocator,
        .type_count = runtime.len,
        .type_sizes = runtime.type_sizes,
        .type_hashes = runtime.type_hashes,
        .entities = EntityMap.init(runtime.allocator),
        .components = components,
        .q = runtime.*,
    };
}

/// Init a archetype based on type metadata.
/// This function will sort metadata
/// Parameters:
///     - allocator: allocator used to allocate entities and components
///     - type_sizes: byte size of each component type
///     - type_hashes: the hashed value for a given type
pub inline fn init(
    allocator: Allocator,
    type_sizes: []const usize,
    type_hashes: []const u64,
) !Archetype {
    std.debug.assert(type_sizes.len == type_sizes.len);

    const owned_type_sizes = try allocator.dupe(usize, type_sizes);
    errdefer allocator.free(owned_type_sizes);
    const owned_type_hashes = try allocator.dupe(u64, type_hashes);
    errdefer allocator.free(owned_type_hashes);

    const components = try allocator.alloc(std.ArrayList(u8), type_sizes.len);
    errdefer allocator.free(components);
    for (components) |*component| {
        component.* = std.ArrayList(u8).init(allocator);
    }

    return Archetype{
        .allocator = allocator,
        .type_count = type_sizes.len,
        .type_sizes = owned_type_sizes,
        .type_hashes = owned_type_hashes,
        .entities = EntityMap.init(allocator),
        .components = components,
        .q = null,
    };
}

pub inline fn deinit(self: *Archetype) void {
    self.entities.deinit();
    for (self.components) |component| {
        component.deinit();
    }
    self.allocator.free(self.components);

    if (self.q) |*q| {
        // give Runtime access to clean own memory
        q.own_memory = true;
        q.deinit();
    } else {
        self.allocator.free(self.type_sizes);
        self.allocator.free(self.type_hashes);
    }
}

/// Register a new entity in this archetype
/// Parameters:
///     - self: the archetype recieving the new entity
///     - entity: the entity being registered
///     - components: all the component data for this entity, care should be taken to
///       maintain components order relative to the new archetype
pub inline fn registerEntity(self: *Archetype, entity: Entity, components: []const []const u8) !void {
    std.debug.assert(self.type_count == components.len); // type poisoning occured

    const value = self.entities.count();
    try self.entities.put(entity, value);
    errdefer _ = self.entities.swapRemove(entity);

    // in the event of eror we need to remove added component byte data
    var appended: usize = 0;
    errdefer {
        for (self.components[0..appended]) |*component, index| {
            component.shrinkAndFree(component.items.len - self.type_sizes[index]);
        }
    }

    // add component data to entity
    for (self.components) |*component, index| {
        std.debug.assert(self.type_sizes[index] == components[index].len);
        try component.appendSlice(components[index]);
        appended += 1;
    }
}

/// moves an entity and it's components to dest archetype
/// this operation is unsafe, because validation of dest archetype is not performend in any way
pub inline fn moveEntity(self: *Archetype, entity: Entity, dest: *Archetype) !void {
    const moving_kv = self.entities.fetchSwapRemove(entity) orelse return error.EntityMissing;

    // TODO: we can do loops in parallel!

    // copy data to destination

    var appended_types: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < appended_types) : (i += 1) {
            const type_index = blk: {
                for (dest.type_hashes) |hash, j| {
                    if (hash == self.type_hashes[i]) {
                        break :blk j;
                    }
                }
                unreachable;
            };
            dest.components[type_index].shrinkAndFree(dest.components[type_index].items.len - self.type_sizes[i]);
        }
    }
    {
        const value = dest.entities.count();
        try dest.entities.put(entity, value);

        component_loop: for (dest.components) |*component, i| {
            const stride = dest.type_sizes[i];
            const start = moving_kv.value * stride;

            // if component exist in previous/current archetype we copy it over
            for (self.type_hashes[0..self.type_count]) |hash, j| {
                if (dest.type_hashes[i] == hash) {
                    try component.appendSlice(self.components[j].items[start .. start + stride]);
                    continue :component_loop;
                }
            }
            // else we add zero bytes to the component storage (should be defined externally!)
            try component.appendNTimes(0, stride);
        }
    }

    // remove data from self
    {
        // TODO: faster way of doing this
        for (self.entities.values()) |*component_index| {
            // if the entity was located after removed entity, we shift it left
            // to occupy vacant memory
            if (component_index.* > moving_kv.value) {
                component_index.* -= 1;
            }
        }

        for (self.components) |*component, i| {
            const stride = self.type_sizes[i];
            const start = moving_kv.value * stride;
            // shift component data to the left
            std.mem.copy(u8, component.items[start..], component.items[start + stride ..]);

            component.shrinkAndFree(component.items.len - stride);
        }
    }
}

/// Assign a component value to the entity
pub inline fn setComponent(self: Archetype, entity: Entity, comptime T: type, value: T) !void {
    // Nothing to set
    if (@sizeOf(T) == 0) {
        return;
    }

    const component_index = try self.componentIndex(comptime query.hashType(T));
    const entity_index = self.entities.get(entity) orelse return error.MissingEntity;

    const start = entity_index * @sizeOf(T);
    const end = entity_index * @sizeOf(T) + @sizeOf(T);
    const bytes = std.mem.asBytes(&value);

    std.mem.copy(u8, self.components[component_index].items[start..end], bytes[0..]);
}

/// Retrieve a component value from a given entity
pub inline fn getComponent(self: Archetype, entity: Entity, comptime T: type) !T {
    const component_index = try self.componentIndex(comptime query.hashType(T));
    
    // Nothing unique to get
    if (@sizeOf(T) == 0) {
        return T{};
    }
    const entity_index = self.entities.get(entity) orelse return error.EntityMissing;
    const start = entity_index * @sizeOf(T);
    const component_ptr = @ptrCast(*T, @alignCast(@alignOf(T), &self.components[component_index].items[start]));
    return component_ptr.*;
}

fn ComponentStoragesReturnType(comptime type_count: usize, comptime types: [type_count]type) type {
    var fields: [types.len + 1]std.builtin.Type.StructField = undefined;
    inline for (types) |T, i| {
        @setEvalBranchQuota(10_000);
        var num_buf: [128]u8 = undefined;
        fields[i] = .{
            .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
            .field_type = if (@sizeOf(T) > 0) []T else T,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(T) > 0) @alignOf(T) else 0,
        };
    }
    var num_buf: [128]u8 = undefined;
    fields[types.len] = .{
        .name = std.fmt.bufPrint(&num_buf, "{d}", .{types.len}) catch unreachable,
        .field_type = usize,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(usize),
    };
    const RtrTypeInfo = std.builtin.Type{ .Struct = .{
        .layout = .Auto,
        .fields = fields[0..],
        .decls = &[0]std.builtin.Type.Declaration{},
        .is_tuple = true,
    } };
    return @Type(RtrTypeInfo);
}

/// Retrieve the component slices relative to the requested types
/// Ie. you can request component (A, C) from archetype (A, B, C) and get the slices for A and C
pub fn getComponentStorages(
    self: *Archetype,
    comptime type_count: usize,
    comptime types: [type_count]type,
) !ComponentStoragesReturnType(
    type_count,
    types,
) {
    comptime var rtr_type_hashes: [types.len]u64 = undefined;
    inline for (types) |T, i| {
        rtr_type_hashes[i] = comptime query.hashType(T);
    }

    var rtr_struct: ComponentStoragesReturnType(type_count, types) = undefined;
    var defined_fields: usize = 0;
    inline for (rtr_type_hashes) |rtr_hash, i| {
        inner: for (self.type_hashes[0..self.type_count]) |hash, j| {
            if (hash == rtr_hash) {
                defined_fields += 1;
                if (@sizeOf(types[i]) == 0) {
                    rtr_struct[i] = types[i]{};
                    break :inner;
                }
                const align_slice = @alignCast(@alignOf(types[i]), self.components[j].items);
                rtr_struct[i] = std.mem.bytesAsSlice(types[i], align_slice);
                break :inner;
            }
        }
    }
    if (defined_fields != rtr_type_hashes.len) {
        return error.TypePoison;
    }
    rtr_struct[rtr_type_hashes.len] = self.entities.count();
    return rtr_struct;
}

/// return true if the archetype contains type T, false otherwise
pub fn hasComponent(self: Archetype, comptime T: type) bool {
    _ = self.componentIndex(query.hashType(T)) catch {
        return false;
    };
    return true;
}

pub inline fn componentIndex(self: Archetype, type_hash: u64) !usize {
    for (self.type_hashes[0..self.type_count]) |hash, i| {
        if (hash == type_hash) return i;
    }
    // TODO: redesign stuff so all of this can be compile time
    return error.InvalidComponentType; // Component does not belong to this archetype
}

test "initFromTypes() produce expected archetype" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const type_arr: [3]type = .{ A, B, C };
    var archetype = try initFromTypes(testing.allocator, &type_arr);
    defer archetype.deinit();

    try testing.expectEqual(type_arr.len, archetype.type_count);
    try testing.expectEqual(type_arr.len, archetype.components.len);

    inline for (type_arr) |T, i| {
        try testing.expectEqual(archetype.type_hashes[i], query.hashType(T));
        try testing.expectEqual(archetype.type_sizes[i], 0);
    }
}

test "initFromQueryRuntime() produce expected archetype" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const type_arr: [3]type = .{ A, B, C };
    var type_sizes: [3]usize = undefined;
    var type_hashes: [3]u64 = undefined;
    inline for (type_arr) |T, i| {
        type_sizes[i] = @sizeOf(T);
        type_hashes[i] = query.hashType(T);
    }
    var q = try query.Runtime.fromSlices(testing.allocator, type_sizes[0..], type_hashes[0..]);
    defer q.deinit();

    var archetype = try initFromQueryRuntime(&q);
    defer archetype.deinit();

    try testing.expectEqual(type_arr.len, archetype.type_count);
    try testing.expectEqual(type_arr.len, archetype.components.len);

    inline for (query.sortTypes(&type_arr)) |T, i| {
        try testing.expectEqual(archetype.type_hashes[i], query.hashType(T));
        try testing.expectEqual(archetype.type_sizes[i], 0);
    }
}

test "init() produce expected arche type" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const type_arr: [3]type = .{ A, B, C };
    var type_sizes: [3]usize = undefined;
    var type_hashes: [3]u64 = undefined;
    inline for (type_arr) |T, i| {
        type_sizes[i] = @sizeOf(T);
        type_hashes[i] = query.hashType(T);
    }
    var archetype = try init(testing.allocator, type_sizes[0..], type_hashes[0..]);
    defer archetype.deinit();

    try testing.expectEqual(type_arr.len, archetype.type_count);
    try testing.expectEqual(type_arr.len, archetype.components.len);

    inline for (type_arr) |T, i| {
        try testing.expectEqual(archetype.type_hashes[i], query.hashType(T));
        try testing.expectEqual(archetype.type_sizes[i], 0);
    }
}

test "registerEntity() produce entity and components" {
    const A = struct {};
    const B = struct { b: usize };
    const C = struct { c: f64 };
    const type_arr: [3]type = .{ A, B, C };

    var archetype = try initFromTypes(testing.allocator, &type_arr);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{};
    const b = B{ .b = 1 };
    const c = C{ .c = 3.14 };
    try archetype.registerEntity(mock_entity, &[_][]const u8{
        &std.mem.toBytes(a),
        &std.mem.toBytes(b),
        &std.mem.toBytes(c),
    });

    try testing.expectEqual(a, try archetype.getComponent(mock_entity, A));
    try testing.expectEqual(b, try archetype.getComponent(mock_entity, B));
    try testing.expectEqual(c, try archetype.getComponent(mock_entity, C));
}

test "moveEntity() moves components and entity to new archetype" {
    const A = struct { a: usize };
    const B = struct { b: usize };
    const C = struct { c: usize };

    const type_arr1 = [_]type{ A, C };
    var arche1 = try initFromTypes(testing.allocator, &type_arr1);
    defer arche1.deinit();

    const type_arr2 = [_]type{ A, B, C };
    var arche2 = try initFromTypes(testing.allocator, &type_arr2);
    defer arche2.deinit();

    var mock_entities: [10]Entity = undefined;
    for (mock_entities) |*entity, i| {
        entity.* = Entity{ .id = @intCast(@TypeOf(mock_entities[0].id), i) };

        try arche1.registerEntity(entity.*, &[_][]const u8{
            &std.mem.toBytes(A{ .a = i }),
            &std.mem.toBytes(C{ .c = i }),
        });
    }

    const move_index = 5;
    try arche1.moveEntity(mock_entities[move_index], &arche2);

    // check if component A was moved to new location
    try testing.expectEqual(A{ .a = move_index }, try arche2.getComponent(mock_entities[move_index], A));
    try testing.expectEqual(C{ .c = move_index }, try arche2.getComponent(mock_entities[move_index], C));
    // check if entity and component data was properly removed from old location
    try testing.expectEqual(@as(?usize, null), arche1.entities.get(mock_entities[move_index]));

    for (mock_entities[0..move_index]) |entity, i| {
        try testing.expectEqual(i, arche1.entities.get(entity).?);

        inline for (type_arr1) |T, j| {
            const component_ptr = @ptrCast(*T, @alignCast(@alignOf(T), &arche1.components[j].items[i * @sizeOf(T)]));
            try testing.expectEqual(arche1.getComponent(entity, T), component_ptr.*);
        }
    }

    for (mock_entities[move_index + 1 ..]) |entity, i| {
        const index = i + move_index;
        try testing.expectEqual(index, arche1.entities.get(entity).?);

        inline for (type_arr1) |T, j| {
            const component_ptr = @ptrCast(*T, @alignCast(@alignOf(T), &arche1.components[j].items[index * @sizeOf(T)]));
            try testing.expectEqual(arche1.getComponent(entity, T), component_ptr.*);
        }
    }
}

test "setComponent() overwrite initial value" {
    const A = struct { a: usize, b: [3]f32 };
    const type_arr: [1]type = .{A};

    var archetype = try initFromTypes(testing.allocator, &type_arr);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{
        .a = 42,
        .b = .{ 1.234, 2.345, 3.456 },
    };
    try archetype.registerEntity(mock_entity, &[_][]const u8{std.mem.asBytes(&a)});

    try testing.expectEqual(a, try archetype.getComponent(mock_entity, A));
}

test "hasComponent() return expected result" {
    const A = struct {};
    const type_arr: [1]type = .{A};

    var archetype = try initFromTypes(testing.allocator, &type_arr);
    defer archetype.deinit();

    try testing.expectEqual(true, archetype.hasComponent(A));
    const B = struct {};
    try testing.expectEqual(false, archetype.hasComponent(B));
}

test "getComponentStorages() give expected slices" {
    const A = struct { a: usize };
    const B = struct { b: f32 };
    const C = struct { c: i64 };
    const type_arr: [3]type = .{ A, B, C };

    var archetype = try initFromTypes(testing.allocator, &type_arr);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{ .a = 123 };
    const b = B{ .b = 123.123 };
    const c = C{ .c = -1 };
    try archetype.registerEntity(mock_entity, &[_][]const u8{
        std.mem.asBytes(&a),
        std.mem.asBytes(&b),
        std.mem.asBytes(&c),
    });

    const a_c_components = try archetype.getComponentStorages(2, [_]type{ A, C });

    try testing.expectEqual(a, a_c_components[0][0]);
    try testing.expectEqual(c, a_c_components[1][0]);
    try testing.expectEqual(@as(usize, 1), a_c_components[2]);
}
