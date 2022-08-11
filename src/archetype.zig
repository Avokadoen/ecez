const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const IArchetype = @import("IArchetype.zig");
const meta = @import("meta.zig");

// const ztracy = @import("ztracy");

const Color = @import("misc.zig").Color;
const query = @import("query.zig");
// const hashfn = @import("query.zig").hashfn;
const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityContext = struct {
    pub fn hash(self: EntityContext, e: Entity) u32 {
        _ = self;
        // id is already unique
        return @intCast(u32, e.id);
    }
    pub fn eql(self: EntityContext, e1: Entity, e2: Entity, index: usize) bool {
        _ = self;
        _ = index;
        return e1.id == e2.id;
    }
};
const EntityMap = std.ArrayHashMap(Entity, usize, EntityContext, false);

pub fn FromTypesTuple(comptime component_types: anytype) type {
    const component_count = comptime countAndVerifyComponentTypes(component_types);
    const unsorted_types = comptime componentTypesTupleOrStructToTypeArr(component_count, component_types);
    return FromTypesArray(&unsorted_types);
}

pub fn FromTypesArray(comptime component_types: []const type) type {
    const component_type_arr = comptime query.sortTypes(component_types);
    const ComponentStorage = meta.ComponentStorage(&component_type_arr);

    return struct {
        const Archetype = @This();

        allocator: Allocator,

        entities: EntityMap,
        component_storage: ComponentStorage,

        /// initialize an archetype
        pub fn init(allocator: Allocator) Archetype {
            // const zone = ztracy.ZoneNC(@src(), "Archetype init", Color.archetype);
            // defer zone.End();

            var component_storage: ComponentStorage = undefined;
            inline for (component_type_arr) |ComponentType, i| {
                if (@sizeOf(ComponentType) > 0) {
                    component_storage[i] = std.ArrayList(ComponentType).init(allocator);
                } else {
                    component_storage[i] = ComponentType{};
                }
            }

            return Archetype{
                .allocator = allocator,
                .entities = EntityMap.init(allocator),
                .component_storage = component_storage,
            };
        }

        pub fn deinit(self: *Archetype) void {
            // const zone = ztracy.ZoneNC(@src(), "Archetype deinit", Color.archetype);
            // defer zone.End();

            self.entities.deinit();
            inline for (component_type_arr) |ComponentType, i| {
                if (@sizeOf(ComponentType) > 0) {
                    self.component_storage[i].deinit();
                }
            }
        }

        /// Register a new entity in this archetype
        /// Parameters:
        ///     - self: the archetype recieving the new entity
        ///     - entity: the entity being registered
        ///     - components: all the component data for this entity
        pub fn registerEntity(self: *Archetype, entity: Entity, components: anytype) !void {
            // const zone = ztracy.ZoneNC(@src(), "Archetype registerEntity", Color.archetype);
            // defer zone.End();

            const type_map = comptime mapComponentStruct(component_type_arr.len, &component_type_arr, @TypeOf(components));

            const value = self.entities.count();
            try self.entities.put(entity, value);
            errdefer _ = self.entities.swapRemove(entity);

            // // in the event of eror we need to remove added component byte data
            // var appended: usize = 0;
            // errdefer {
            //     var i: usize = 0;
            //     while (i < appended) : (i += 1) {
            //         _ = self.component_storage[i].pop();
            //     }
            // }

            const components_type_info = @typeInfo(@TypeOf(components)).Struct;
            // add component data to entity according to if it is a struct or tuple
            if (components_type_info.is_tuple) {
                inline for (component_type_arr) |ComponentType, i| {
                    if (@sizeOf(ComponentType) > 0) {
                        try self.component_storage[i].append(components[type_map[i]]);
                    }
                }
            } else {
                inline for (component_type_arr) |ComponentType, i| {
                    if (@sizeOf(ComponentType) > 0) {
                        const field = @field(components, components_type_info.fields[type_map[i]].name);
                        try self.component_storage[i].append(field);
                    }
                }
            }
        }

        /// Assign a component value to the entity
        pub fn setComponent(self: Archetype, entity: Entity, comptime T: type, value: T) !void {
            // const zone = ztracy.ZoneNC(@src(), "Archetype setComponent", Color.archetype);
            // defer zone.End();

            if (comptime indexOfType(T, &component_type_arr)) |index| {
                const entity_index = self.entities.get(entity) orelse return error.EntityMissing;
                // Nothing to set
                if (@sizeOf(T) == 0) {
                    return;
                }
                self.component_storage[index].items[entity_index] = value;
            } else {
                @compileError("attempted to retrieve component from invalid arche type, this is an ecez bug please submit an issue");
            }
        }

        /// get the archetype dynamic dispatch interface
        pub fn archetypeInterface(self: *Archetype) IArchetype {
            return IArchetype.init(self, rawHasComponent, rawGetComponent);
        }

        pub fn componentIndex(self: Archetype, comptime T: type) ?usize {
            // const zone = ztracy.ZoneNC(@src(), "Archetype componentIndex", Color.archetype);
            // defer zone.End();
            _ = self;
            return comptime indexOfType(T, &component_type_arr);
        }

        // TODO: accept a rem_components: anytype with the remaining component data
        /// moves an entity and it's components to dest archetype
        pub fn moveEntity(self: *Archetype, entity: Entity, comptime DestType: type, dest: *DestType, rem_components: anytype) !void {
            // const zone = ztracy.ZoneNC(@src(), "Archetype moveEntity", Color.archetype);
            // defer zone.End();

            // move entity to destination and get entity component index
            const moving_kv = self.entities.fetchSwapRemove(entity) orelse return error.EntityMissing;
            const value = dest.entities.count(); // TODO: rename
            try dest.entities.put(entity, value);

            const DestStruct = DestType.ComponentStruct();
            const map_len = comptime tuplesTypeMapLen(DestStruct);

            const SelfStruct = Archetype.ComponentStruct();
            const RemStruct = @TypeOf(rem_components);

            // get type maps and verify that each field is defined and only once
            comptime var self_type_map = tuplesTypeMap(map_len, SelfStruct, DestStruct);
            const rem_type_map = comptime tuplesTypeMap(map_len, RemStruct, DestStruct);
            inline for (self_type_map) |*map, i| {
                if (rem_type_map[i] == .index) {
                    // new data takes precendence
                    map.* = .none;
                }

                if (map.* == .none and rem_type_map[i] == .none) {
                    return error.MissingComponentData; // entity changed type without supplying it sufficient components
                }
            }

            // move components from self to dest
            {
                // TODO: errdefer: backtrack partially added components
                inline for (self_type_map) |map, i| {
                    if (map == .index) {
                        // move component from self to dest
                        const src_component = self.component_storage[map.index].items[moving_kv.value];
                        try dest.component_storage[i].append(src_component);
                    }
                }
            }

            // move remainding components to dest
            {
                // TODO: errdefer: backtrack partially added components
                inline for (rem_type_map) |map, i| {
                    if (map == .index) {
                        const src_component = rem_components[map.index];
                        try dest.component_storage[i].append(src_component);
                    }
                }
            }

            // remove entity and update entity values for all entities with component data to the right of removed entity
            {
                // TODO: faster way of doing this?
                // https://devlog.hexops.com/2022/zig-hashmaps-explained/
                for (self.entities.values()) |*component_index| {
                    // if the entity was located after removed entity, we shift it left
                    // to occupy vacant memory
                    if (component_index.* > moving_kv.value) {
                        component_index.* -= 1;
                    }
                }

                inline for (component_type_arr) |T, i| {
                    if (@sizeOf(T) > 0) {
                        _ = self.component_storage[i].orderedRemove(moving_kv.value);
                    }
                }
            }
        }

        /// Retrieve a component value from a given entity
        pub fn getComponent(self: *Archetype, entity: Entity, comptime T: type) IArchetype.Error!T {
            // const zone = ztracy.ZoneNC(@src(), "Archetype getComponent", Color.archetype);
            // defer zone.End();
            const bytes = try self.rawGetComponent(entity, comptime query.hashType(T));
            if (@sizeOf(T) <= 0) return T{};
            return @ptrCast(*const T, @alignCast(@alignOf(T), bytes.ptr)).*;
        }

        /// Retrieve a component value as bytes from a given entity
        pub fn rawGetComponent(self: *Archetype, entity: Entity, type_hash: u64) IArchetype.Error![]const u8 {
            // const zone = ztracy.ZoneNC(@src(), "Archetype getComponent", Color.archetype);
            // defer zone.End();
            if (self.rawHasComponent(type_hash) == false) {
                return IArchetype.Error.ComponentMissing; // Component type not part of archetype
            }

            const entity_index = self.entities.get(entity) orelse {
                return IArchetype.Error.EntityMissing; // Entity not part of archetype
            };

            inline for (component_type_arr) |Component, i| {
                if (query.hashType(Component) == type_hash) {
                    if (@sizeOf(Component) == 0) {
                        return &[0]u8{};
                    }
                    // TODO: is this stack memory
                    return std.mem.asBytes(&self.component_storage[i].items[entity_index]);
                }
            }
            // we return in begining of function for the case that would reach this point
            unreachable;
        }

        /// Implementation of IArchetype hasComponent
        pub fn rawHasComponent(self: *Archetype, type_hash: u64) bool {
            _ = self;
            inline for (component_type_arr) |Component| {
                if (query.hashType(Component) == type_hash) {
                    return true;
                }
            }
            return false;
        }

        /// Retrieve the component slices relative to the requested types
        /// Ie. you can request component (A, C) from archetype (A, B, C) and get the slices for A and C
        pub fn getComponentStorage(self: *Archetype, comptime types: []const type) meta.ComponentStorage(types) {
            // const zone = ztracy.ZoneNC(@src(), "Archetype getComponentStorages", Color.archetype);
            // defer zone.End();

            const RtrMapStruct = ArcheComponentStruct(types);
            const map_len = comptime tuplesTypeMapLen(RtrMapStruct);
            const type_map = comptime tuplesTypeMap(map_len, Archetype.ComponentStruct(), RtrMapStruct);

            var rtr_storage: meta.ComponentStorage(types) = undefined;
            // move components from self to dest
            {
                inline for (type_map) |map, i| {
                    switch (map) {
                        .index => |index| rtr_storage[i] = self.component_storage[index],
                        .empty_type => rtr_storage[i] = types[i]{},
                        .none => @compileError("requested component storage with invalid type " ++ @typeName(types[i]) ++ " this is an ecez bug please submit and issue"),
                    }
                }
            }

            return rtr_storage;
        }

        pub fn ComponentStruct() type {
            return ArcheComponentStruct(&component_type_arr);
        }
    };
}

/// Count and verify component types
fn countAndVerifyComponentTypes(comptime component_types: anytype) comptime_int {
    const type_info = blk: {
        var info = @typeInfo(@TypeOf(component_types));
        if (info == .Type) {
            info = @typeInfo(component_types);
        }
        if (info != .Struct) {
            @compileError("invalid use of countAndVerifyComponentTypes, this is a ecez bug, please submit an issue");
        }
        break :blk info.Struct;
    };
    inline for (type_info.fields) |field| {
        const field_type = @typeInfo(field.field_type);
        if (field_type != .Type and field_type != .Struct) {
            @compileError("invalid use of countAndVerifyComponentTypes, this is a ecez bug, please submit an issue");
        }
    }
    return type_info.fields.len;
}

/// returns map for component struct with type array
/// the map maps index i of the archetype component types to incomming
/// components data
fn mapComponentStruct(
    comptime types_count: comptime_int,
    comptime component_types: []const type,
    comptime components_type: type,
) [types_count]usize {
    const components_info = @typeInfo(components_type);
    if (components_info != .Struct) {
        @compileError("invalid use of mapComponentStruct, this is a ecez bug, please submit an issue");
    }
    if (components_info.Struct.fields.len != types_count) {
        @compileError("invalid use of mapComponentStruct, this is a ecez bug, please submit an issue");
    }

    var map: [types_count]usize = undefined;
    inline for (components_info.Struct.fields) |field, i| {
        inline for (component_types) |component_type, j| {
            if (field.field_type == component_type) {
                map[j] = i;
                break;
            }
        }
    }
    return map;
}

fn componentTypesTupleOrStructToTypeArr(comptime elem_count: comptime_int, comptime tuple: anytype) [elem_count]type {
    var type_arr: [elem_count]type = undefined;

    switch (@typeInfo(@TypeOf(tuple))) {
        .Struct => |type_info| {
            inline for (type_info.fields) |_, i| {
                type_arr[i] = tuple[i];
            }
        },
        .Type => {
            const type_info = @typeInfo(tuple).Struct;
            inline for (type_info.fields) |field, i| {
                type_arr[i] = field.field_type;
            }
        },
        else => @compileError("unexpected type info in componentTypesTupleOrStructToTypeArr, this is an ecez bug please file an issue"),
    }
    return type_arr;
}

fn indexOfType(comptime T: type, comptime types: []const type) ?usize {
    inline for (types) |TT, i| {
        if (T == TT) return i;
    }
    return null;
}

/// return map len given two tuples
fn tuplesTypeMapLen(comptime B: type) usize {
    const info_b = blk: {
        const info = @typeInfo(B);
        if (info != .Struct) {
            @compileError("invalid tuple_b, this is a ecez bug, please file an issue");
        }
        break :blk info.Struct;
    };

    return info_b.fields.len;
}

const TypeMapEntry = union(enum) {
    index: usize,
    empty_type: void,
    none: void,
};
/// return type map given two tuples, the map consist of an array where map[i] correspond to field i in type B
/// the array value at i correspond to the field valued j of type A
inline fn tuplesTypeMap(comptime map_len: usize, comptime A: type, comptime B: type) [map_len]TypeMapEntry {
    const info_a = blk: {
        const info = @typeInfo(A);
        if (info != .Struct) {
            @compileError("invalid tuple_a, this is a ecez bug, please file an issue");
        }
        break :blk info.Struct;
    };
    const info_b = blk: {
        const info = @typeInfo(B);
        if (info != .Struct) {
            @compileError("invalid tuple_b, this is a ecez bug, please file an issue");
        }
        break :blk info.Struct;
    };

    comptime var map: [map_len]TypeMapEntry = [_]TypeMapEntry{.none} ** map_len;
    inline for (info_b.fields) |field_b, i| {
        inner: inline for (info_a.fields) |field_a, j| {
            if (field_a.field_type == field_b.field_type) {
                if (@sizeOf(field_b.field_type) == 0 and @sizeOf(field_a.field_type) == 0) {
                    map[i] = TypeMapEntry.empty_type;
                } else {
                    map[i] = TypeMapEntry{ .index = j };
                }
                break :inner;
            }
        }
    }
    return map;
}

/// Generate a entity's component data struct type
fn ArcheComponentStruct(comptime types: []const type) type {
    const Type = std.builtin.Type;

    var struct_fields: [types.len]Type.StructField = undefined;
    inline for (types) |T, i| {
        var num_buf: [8]u8 = undefined;
        struct_fields[i] = .{
            .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
            .field_type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(T) > 0) @alignOf(T) else 0,
        };
    }

    const RtrTypeInfo = std.builtin.Type{ .Struct = .{
        .layout = .Auto,
        .fields = &struct_fields,
        .decls = &[0]std.builtin.Type.Declaration{},
        .is_tuple = true,
    } };

    return @Type(RtrTypeInfo);
}

test "init() produce expected arche type" {
    const A = struct {};
    const B = struct { b: u32 };
    const C = struct { c: u7 };

    var archetype = FromTypesTuple(.{ A, B, C }).init(testing.allocator);
    defer archetype.deinit();

    // expect no compile errors from setting storage
    try testing.expectEqual(A{}, archetype.component_storage[0]);

    // currently query.typeSort sort C to index 1 and B to index 2
    try archetype.component_storage[1].append(C{ .c = 0 });
    try archetype.component_storage[2].append(B{ .b = 1 });
}

test "registerEntity() produce entity and components" {
    const A = struct {};
    const B = struct { b: usize };
    const C = struct { c: u7 };

    var archetype = FromTypesTuple(.{ A, B, C }).init(testing.allocator);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{};
    const b = B{ .b = 1 };
    const c = C{ .c = 3 };
    try archetype.registerEntity(mock_entity, .{ a, b, c });

    // currently query.sortTypes sort A B C to A C B
    try testing.expectEqual(a, archetype.component_storage[0]);
    try testing.expectEqual(@as(usize, 1), archetype.component_storage[1].items.len);
    try testing.expectEqual(c, archetype.component_storage[1].items[0]);
    try testing.expectEqual(@as(usize, 1), archetype.component_storage[2].items.len);
    try testing.expectEqual(b, archetype.component_storage[2].items[0]);
}

test "getComponent() return error when getting non existing entity's component" {
    const A = struct {};
    const B = struct { b: u32 };
    var archetype = FromTypesTuple(.{ A, B }).init(testing.allocator);
    defer archetype.deinit();

    try testing.expectError(error.EntityMissing, archetype.getComponent(Entity{ .id = 0 }, A));
    try testing.expectError(error.EntityMissing, archetype.getComponent(Entity{ .id = 0 }, B));
}

test "getComponent() retrieve component value" {
    const A = struct { a: usize, b: [3]u32 };
    const B = struct { a: u1 };
    const C = struct { a: u1 };

    var archetype = FromTypesTuple(.{ A, B, C }).init(testing.allocator);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{
        .a = 42,
        .b = .{ 1234, 2345, 3456 },
    };
    const b = B{ .a = 0 };
    const c = C{ .a = 1 };
    try archetype.registerEntity(mock_entity, .{ a, b, c });

    try testing.expectEqual(a, try archetype.getComponent(mock_entity, A));
    try testing.expectEqual(b, try archetype.getComponent(mock_entity, B));
    try testing.expectEqual(c, try archetype.getComponent(mock_entity, C));
}

test "setComponent() return error when setting non existing entity's component" {
    const A = struct {};
    const B = struct { b: u32 };
    var archetype = FromTypesTuple(.{ A, B }).init(testing.allocator);
    defer archetype.deinit();

    try testing.expectError(error.EntityMissing, archetype.setComponent(Entity{ .id = 0 }, A, .{}));
    try testing.expectError(error.EntityMissing, archetype.setComponent(Entity{ .id = 0 }, B, .{ .b = 0 }));
}

test "setComponent() overwrite original component value" {
    const A = struct { a: u32 };
    const B = struct { a: i32 };
    const C = struct { a: u2 };

    var archetype = FromTypesTuple(.{ A, B, C }).init(testing.allocator);
    defer archetype.deinit();

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try archetype.registerEntity(Entity{ .id = i }, .{
            A{ .a = 999 },
            B{ .a = -999 },
            C{ .a = 3 },
        });
    }

    const mock_entity = Entity{ .id = i };
    try archetype.registerEntity(mock_entity, .{
        A{ .a = 999 },
        B{ .a = -999 },
        C{ .a = 3 },
    });
    i += 1;

    while (i < 40) : (i += 1) {
        try archetype.registerEntity(Entity{ .id = i }, .{
            A{ .a = 999 },
            B{ .a = -999 },
            C{ .a = 3 },
        });
    }

    const a = A{ .a = 42 };
    const b = B{ .a = -42 };
    const c = C{ .a = 1 };
    try archetype.setComponent(mock_entity, A, a);
    try archetype.setComponent(mock_entity, B, b);
    try archetype.setComponent(mock_entity, C, c);
    try testing.expectEqual(a, try archetype.getComponent(mock_entity, A));
    try testing.expectEqual(b, try archetype.getComponent(mock_entity, B));
    try testing.expectEqual(c, try archetype.getComponent(mock_entity, C));
}

test "hasComponent() return expected result" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var archetype = FromTypesTuple(.{ A, B }).init(testing.allocator);
    defer archetype.deinit();

    try testing.expectEqual(true, archetype.rawHasComponent(comptime query.hashType(A)));
    try testing.expectEqual(true, archetype.rawHasComponent(comptime query.hashType(B)));
    try testing.expectEqual(false, archetype.rawHasComponent(comptime query.hashType(C)));
}

test "componentIndex() find index of components" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var archetype = FromTypesTuple(.{ A, B, C }).init(testing.allocator);
    defer archetype.deinit();

    const sorted_types = query.sortTypes(&[3]type{ A, B, C });
    inline for (sorted_types) |T, i| {
        try testing.expectEqual(@as(?usize, i), archetype.componentIndex(T));
    }
    try testing.expectEqual(@as(?usize, null), archetype.componentIndex(@TypeOf(archetype)));
}

test "moveEntity() moves components and entity to new archetype" {
    const A = struct { a: usize };
    const B = struct { b: usize };
    const C = struct { c: usize };
    const D = struct { d: usize };
    const E = struct {};

    var archetype_a = FromTypesTuple(.{ A, C, E }).init(testing.allocator);
    defer archetype_a.deinit();

    var archetype_b = FromTypesTuple(.{ A, B, C, D }).init(testing.allocator);
    defer archetype_b.deinit();

    // register entities to archetype a which is a subset of archetype b
    var mock_entities: [10]Entity = undefined;
    for (mock_entities) |*entity, i| {
        entity.* = Entity{ .id = @intCast(@TypeOf(mock_entities[0].id), i) };

        const a = A{ .a = i };
        const c = C{ .c = i };
        const e = E{};
        try archetype_a.registerEntity(entity.*, .{ a, c, e });
    }

    for (mock_entities) |entity, i| {
        const d = D{ .d = i };
        const b = B{ .b = i };
        try archetype_a.moveEntity(entity, @TypeOf(archetype_b), &archetype_b, .{ d, b });
        try testing.expectEqual(A{ .a = i }, try archetype_b.getComponent(entity, A));
        try testing.expectEqual(B{ .b = i }, try archetype_b.getComponent(entity, B));
        try testing.expectEqual(C{ .c = i }, try archetype_b.getComponent(entity, C));
        try testing.expectEqual(D{ .d = i }, try archetype_b.getComponent(entity, D));
    }

    for (mock_entities) |entity, i| {
        try archetype_b.moveEntity(entity, @TypeOf(archetype_a), &archetype_a, .{E{}});
        try testing.expectEqual(A{ .a = i }, try archetype_a.getComponent(entity, A));
        try testing.expectEqual(C{ .c = i }, try archetype_a.getComponent(entity, C));
        try testing.expectEqual(E{}, try archetype_a.getComponent(entity, E));
    }

    try testing.expectEqual(@as(usize, mock_entities.len), archetype_a.component_storage[1].items.len);
    try testing.expectEqual(@as(usize, 0), archetype_b.component_storage[0].items.len);
}

test "getComponentStorage() returns subset or all of an archetype storage" {
    const A = struct { a: u1 };
    const B = struct { b: usize };
    const C = struct { c: u16 };
    const D = struct {};

    var archetype = FromTypesTuple(.{ A, B, C, D }).init(testing.allocator);
    defer archetype.deinit();

    const mock_entity = Entity{ .id = 0 };
    const a = A{ .a = 1 };
    const b = B{ .b = 16 };
    const c = C{ .c = 32 };
    const d = D{};
    try archetype.registerEntity(mock_entity, .{ a, b, c, d });

    {
        const storage = archetype.getComponentStorage(&[_]type{ B, C, A });
        try testing.expectEqual(b, storage[0].items[0]);
        try testing.expectEqual(c, storage[1].items[0]);
        try testing.expectEqual(a, storage[2].items[0]);
    }

    {
        const storage = archetype.getComponentStorage(&[_]type{ A, B, C, D });
        try testing.expectEqual(a, storage[0].items[0]);
        try testing.expectEqual(b, storage[1].items[0]);
        try testing.expectEqual(c, storage[2].items[0]);
        try testing.expectEqual(d, storage[3]);
    }
}

test "tuplesTypeMapLen() correctly count components" {
    const A = struct {};
    const C = struct {};

    const result = tuplesTypeMapLen(struct { c: C, a: A });
    try testing.expectEqual(@as(usize, 2), result);
}

test "tuplesTypeMap() correctly map components" {
    const A = struct {};
    const B = struct {};
    const C = struct { c: usize };

    {
        const result = tuplesTypeMap(2, struct { a: A, b: B, c: C }, struct { c: C, a: A });
        const expected = [2]TypeMapEntry{ .{ .index = 2 }, .empty_type };
        try testing.expectEqual(expected, result);
    }
    {
        const result = tuplesTypeMap(3, struct { c: C, a: A }, struct { a: A, b: B, c: C });
        const expected = [3]TypeMapEntry{ .empty_type, .none, .{ .index = 0 } };
        try testing.expectEqual(expected, result);
    }
}

test "archetype IArchetype hasComponent returns expected" {
    const A = struct { a: u32 };
    const B = struct { a: i32 };
    const C = struct { a: u2 };

    const Archetype = FromTypesTuple(.{ A, B });
    var archetype = Archetype.init(testing.allocator);
    defer archetype.deinit();

    const i_archetype = archetype.archetypeInterface();

    try testing.expectEqual(true, i_archetype.hasComponent(A));
    try testing.expectEqual(true, i_archetype.hasComponent(B));
    try testing.expectEqual(false, i_archetype.hasComponent(C));

    // std.heap.ArenaAllocator
}
