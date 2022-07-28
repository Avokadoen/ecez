const std = @import("std");
const Allocator = std.mem.Allocator;
const archetype = @import("archetype.zig");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const EntityRef = entity_type.EntityRef;

// TODO: issue - setEntityType should give compile error if stat fields will be unused
// TODO: issue - setEntityType should give compile error if stat fields does not exist in dest type

const testing = std.testing;
pub fn FromArchetypes(comptime submitted_archetypes: []const type) type {
    // const component_count = uniquelyCountComponents(
    //     countAndVerifyAllComponents(submitted_archetypes),
    //     submitted_archetypes,
    // );

    const KV = struct {
        @"0": []const u8,
        @"1": usize,
    };
    comptime var kv: [submitted_archetypes.len]KV = undefined;
    for (submitted_archetypes) |submitted_archetype, i| {
        kv[i] = .{ .@"0" = @typeName(submitted_archetype), .@"1" = i };
    }
    // given a typename, get a index to the archetype pointer
    const ArchetypeMap = std.ComptimeStringMap(usize, kv);

    comptime var Archetypes: [kv.len]type = undefined;
    inline for (Archetypes) |*A, i| {
        A.* = archetype.FromTypesTuple(submitted_archetypes[i]);
    }

    return struct {
        const ArcheContainer = @This();

        archetypes: [kv.len]*anyopaque,
        // map entity id to a archetypes index
        entity_references: std.ArrayList(EntityRef),

        pub fn init(allocator: Allocator) !ArcheContainer {
            var archetypes: [kv.len]*anyopaque = undefined;
            comptime var i: comptime_int = 0;
            inline while (i < kv.len) : (i += 1) {
                var arche = try allocator.create(Archetypes[i]);
                arche.* = Archetypes[i].init(allocator);
                archetypes[i] = @ptrCast(*anyopaque, arche);
            }

            return ArcheContainer{
                .archetypes = archetypes,
                .entity_references = std.ArrayList(EntityRef).init(allocator),
            };
        }

        pub fn deinit(self: ArcheContainer, allocator: Allocator) void {
            comptime var i: comptime_int = 0;
            inline while (i < kv.len) : (i += 1) {
                const T = archetype.FromTypesTuple(submitted_archetypes[i]);
                var arche = self.archetypeTyped(i, T);
                arche.deinit();
                allocator.destroy(arche);
            }
            self.entity_references.deinit();
        }

        /// create a new entity and supply it an initial state
        /// Parameters:
        ///     - inital_state: the initial state of the entity, this must be a registered archetype
        pub fn createEntity(self: *ArcheContainer, initial_state: anytype) !Entity {
            const ArchetypeStruct = @TypeOf(initial_state);
            const archetype_index = comptime ArcheContainer.getTypeIndex(ArchetypeStruct);

            const entity = Entity{ .id = self.entity_references.items.len };
            try self.entity_references.append(EntityRef{ .index = archetype_index });
            errdefer _ = self.entity_references.pop();

            var entity_archetype = self.archetypeTyped(archetype_index, Archetypes[archetype_index]);
            try entity_archetype.registerEntity(entity, initial_state);

            return entity;
        }

        /// update the type of an entity
        /// Parameters:
        ///     - entity: the entity to update type of
        ///     - NewType: the new archetype of *entity*
        ///     - state: tuple of some components of *NewType*, or struct of type *NewType*
        ///                  if *state* is a subset of *NewType*, then the missing components of *state*
        ///                  must exist in *entity*'s previous type. Void is valid if *NewType* is a subset of
        ///                  *entity* previous type.
        pub fn setEntityType(self: *ArcheContainer, entity: Entity, comptime NewType: type, state: anytype) !void {
            // get target archetype
            const target_index = comptime getTypeIndex(NewType);
            var target_archetype = self.archetypeTyped(target_index, Archetypes[target_index]);

            const new_state = blk1: {
                const state_info = blk2: {
                    const info = @typeInfo(@TypeOf(state));
                    if (info != .Struct) {
                        @compileError("invalid entity new state");
                    }
                    break :blk2 info.Struct;
                };

                if (state_info.is_tuple) {
                    break :blk1 state;
                }
                const Type = std.builtin.Type;
                comptime var tuple_fields: [state_info.fields.len]Type.StructField = undefined;
                inline for (state_info.fields) |field, i| {
                    tuple_fields[i] = field;
                    var num_buf: [8]u8 = undefined;
                    tuple_fields[i].name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
                }
                const state_as_tuple_info = Type{ .Struct = .{
                    .layout = .Auto,
                    .fields = &tuple_fields,
                    .decls = &[0]Type.Declaration{},
                    .is_tuple = true,
                } };
                const Tuple = @Type(state_as_tuple_info);
                var tuple: Tuple = undefined;
                inline for (state_info.fields) |field, i| {
                    tuple[i] = @field(state, field.name);
                }
                break :blk1 tuple;
            };

            const entity_ref = self.entity_references.items[entity.id];
            inline for (Archetypes) |A, i| {
                if (entity_ref.index == i) {
                    // check if data is missing in assignment
                    var entity_archetype = self.archetypeTyped(i, A);
                    try entity_archetype.moveEntity(entity, Archetypes[target_index], target_archetype, new_state);
                    self.entity_references.items[entity.id].index = target_index;
                    return;
                }
            }
            // this can only occur if entity.id (or the entity ref)
            // has been changed externally which is a big no no!
            unreachable;
        }

        /// check if a given entity is the specified type T
        /// Returns true if entity is of type T, false otherwise
        pub fn isEntityType(self: ArcheContainer, entity: Entity, comptime Archetype: type) bool {
            const archetype_index = comptime ArcheContainer.getTypeIndex(Archetype);
            return self.entity_references.items[entity.id].index == archetype_index;
        }

        pub fn hasComponent(self: ArcheContainer, entity: Entity, comptime Component: type) bool {
            const entity_ref = self.entity_references.items[entity.id];
            inline for (Archetypes) |_, i| {
                if (entity_ref.index == i) {
                    const field_info_a = @typeInfo(submitted_archetypes[i]).Struct;
                    inline for (field_info_a.fields) |field| {
                        if (field.field_type == Component) {
                            return true;
                        }
                    }
                }
            }
            return false;
        }

        inline fn archetypeTyped(self: ArcheContainer, archetype_index: usize, comptime T: type) *T {
            return @ptrCast(*T, @alignCast(@alignOf(T), self.archetypes[archetype_index]));
        }

        /// Comptime function to get the type index of T, will result in compile time error if T is not
        /// part of struct type
        inline fn getTypeIndex(comptime T: type) usize {
            return ArchetypeMap.get(@typeName(T)) orelse {
                @compileError(@typeName(T) ++ " was not registered under World type construction");
            };
        }
    };
}

/// Count components in an archetype and verify that the archetype consist of components (structs)
fn countComponentsAndVerifyArchetype(comptime archetype_struct: type) comptime_int {
    const type_info = blk: {
        const info = @typeInfo(archetype_struct);
        if (info != .Struct) {
            @compileError("expected type of archetype " ++ @typeName(archetype_struct) ++ " to be a struct");
        }
        break :blk info.Struct;
    };
    inline for (type_info.fields) |field| {
        if (@typeInfo(field.field_type) != .Struct) {
            @compileError(@typeName(archetype_struct) ++ " has non component based field" ++ " an archetype must consist of component structs");
        }
    }
    return type_info.fields.len;
}

/// count component types once uniquely
fn countAndVerifyAllComponents(comptime submitted_archetypes: []const type) comptime_int {
    comptime var counted: comptime_int = 0;
    inline for (submitted_archetypes) |submitted_archetype, i| {
        counted += countComponentsAndVerifyArchetype(submitted_archetype);

        var j = 0;
        while (j < i) : (j += 1) {
            if (submitted_archetype == submitted_archetypes[j]) {
                @compileError(@typeName(submitted_archetype) ++ " supplied more than once");
            }
        }
    }
    return counted;
}

/// count component types once uniquely
fn uniquelyCountComponents(comptime total_count: comptime_int, comptime submitted_archetypes: []const type) comptime_int {
    comptime var components_counted: [total_count]type = undefined;
    comptime var counted: comptime_int = 0;

    inline for (submitted_archetypes) |submitted_archetype| {
        const type_info = @typeInfo(submitted_archetype).Struct;
        field_loop: inline for (type_info.fields) |field| {
            // if we have already counted type
            var i = 0;
            while (i < counted) : (i += 1) {
                if (components_counted[i] == field.field_type) continue :field_loop;
            }
            components_counted[counted] = field.field_type;
            counted += 1;
        }
    }

    return counted;
}

const Testing = struct {
    const Component = struct {
        const A = struct { value: u32 };
        const B = struct { value: u8 };
        const C = struct {};
    };

    const Archetype = struct {
        const A = struct {
            a: Component.A,
        };
        const AB = struct {
            a: Component.A,
            b: Component.B,
        };
        const AC = struct {
            a: Component.A,
            c: Component.C,
        };
        const ABC = struct {
            a: Component.A,
            b: Component.B,
            c: Component.C,
        };
    };

    const AllArchetypes = [_]type{
        Testing.Archetype.A,
        Testing.Archetype.AB,
        Testing.Archetype.AC,
        Testing.Archetype.ABC,
    };
};
test "countComponentsAndVerifyArchetype() counts components" {
    try testing.expectEqual(1, countComponentsAndVerifyArchetype(Testing.Archetype.A));
    try testing.expectEqual(2, countComponentsAndVerifyArchetype(Testing.Archetype.AB));
    try testing.expectEqual(3, countComponentsAndVerifyArchetype(Testing.Archetype.ABC));
}

test "countAndVerifyAllComponents() correctly count types once" {
    try testing.expectEqual(8, countAndVerifyAllComponents(&Testing.AllArchetypes));
}

test "uniquelyCountComponents() correctly count types once" {
    try testing.expectEqual(3, uniquelyCountComponents(6, &Testing.AllArchetypes));
}

test "Archetypes init + deinit is idempotent" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    const archetypes = try Archetypes.init(testing.allocator);
    archetypes.deinit(testing.allocator);
}

test "Archetypes createEntity returns a valid entity" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    var archetypes = try Archetypes.init(testing.allocator);
    defer archetypes.deinit(testing.allocator);

    const entity = try archetypes.createEntity(Testing.Archetype.ABC{
        .a = .{ .value = 32 },
        .b = .{ .value = 2 },
        .c = .{},
    });

    try testing.expectEqual(@as(entity_type.EntityId, 0), entity.id);

    // 2 is the index of Testing.Archetype.ABC because it is the 3. element in the
    // Testing.AllArchetypes array
    const archetype_index = comptime Archetypes.getTypeIndex(Testing.Archetype.ABC);
    const Archetype = archetype.FromTypesTuple(Testing.Archetype.ABC);
    const archetype_abc = @ptrCast(*Archetype, @alignCast(@alignOf(Archetype), archetypes.archetypes[archetype_index]));

    try testing.expectEqual(
        Testing.Component.A{ .value = 32 },
        try archetype_abc.getComponent(entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 2 },
        try archetype_abc.getComponent(entity, Testing.Component.B),
    );
    try testing.expectEqual(
        Testing.Component.C{},
        try archetype_abc.getComponent(entity, Testing.Component.C),
    );
}

test "Archetypes setEntityType update to subtype" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    var archetypes = try Archetypes.init(testing.allocator);
    defer archetypes.deinit(testing.allocator);

    const entity = try archetypes.createEntity(Testing.Archetype.ABC{
        .a = .{ .value = 1 },
        .b = .{ .value = 2 },
        .c = .{},
    });

    try archetypes.setEntityType(entity, Testing.Archetype.AC, .{});
    try archetypes.setEntityType(entity, Testing.Archetype.A, .{});

    const archetype_index = comptime Archetypes.getTypeIndex(Testing.Archetype.A);
    const Archetype = archetype.FromTypesTuple(Testing.Archetype.A);
    const archetype_a = @ptrCast(*Archetype, @alignCast(@alignOf(Archetype), archetypes.archetypes[archetype_index]));

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try archetype_a.getComponent(entity, Testing.Component.A),
    );
}

test "Archetypes setEntityType update to superset" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    var archetypes = try Archetypes.init(testing.allocator);
    defer archetypes.deinit(testing.allocator);

    const entity = try archetypes.createEntity(Testing.Archetype.A{
        .a = .{ .value = 1 },
    });

    try archetypes.setEntityType(
        entity,
        Testing.Archetype.AC,
        .{Testing.Component.C{}},
    );
    try archetypes.setEntityType(
        entity,
        Testing.Archetype.ABC,
        .{Testing.Component.B{ .value = 3 }},
    );

    const archetype_index = comptime Archetypes.getTypeIndex(Testing.Archetype.ABC);
    const Archetype = archetype.FromTypesTuple(Testing.Archetype.ABC);
    const archetype_a = @ptrCast(*Archetype, @alignCast(@alignOf(Archetype), archetypes.archetypes[archetype_index]));

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try archetype_a.getComponent(entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 3 },
        try archetype_a.getComponent(entity, Testing.Component.B),
    );
}

test "Archetypes isEntityType correctly identify type of entity" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    var archetypes = try Archetypes.init(testing.allocator);
    defer archetypes.deinit(testing.allocator);

    const entity = try archetypes.createEntity(Testing.Archetype.AB{
        .a = .{ .value = 0 },
        .b = .{ .value = 0 },
    });

    try testing.expectEqual(true, archetypes.isEntityType(entity, Testing.Archetype.AB));
    try testing.expectEqual(false, archetypes.isEntityType(entity, Testing.Archetype.ABC));
}

test "Archetypes hasComponent correctly identify entity component types" {
    const Archetypes = FromArchetypes(&Testing.AllArchetypes);
    var archetypes = try Archetypes.init(testing.allocator);
    defer archetypes.deinit(testing.allocator);

    {
        const entity = try archetypes.createEntity(Testing.Archetype.A{
            .a = .{ .value = 0 },
        });
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.A));
        try testing.expectEqual(false, archetypes.hasComponent(entity, Testing.Component.B));
        try testing.expectEqual(false, archetypes.hasComponent(entity, Testing.Component.C));
    }

    {
        const entity = try archetypes.createEntity(Testing.Archetype.AB{
            .a = .{ .value = 0 },
            .b = .{ .value = 0 },
        });
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.A));
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.B));
        try testing.expectEqual(false, archetypes.hasComponent(entity, Testing.Component.C));
    }

    {
        const entity = try archetypes.createEntity(Testing.Archetype.AC{
            .a = .{ .value = 0 },
            .c = .{},
        });
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.A));
        try testing.expectEqual(false, archetypes.hasComponent(entity, Testing.Component.B));
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.C));
    }

    {
        const entity = try archetypes.createEntity(Testing.Archetype.ABC{
            .a = .{ .value = 0 },
            .b = .{ .value = 0 },
            .c = .{},
        });
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.A));
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.B));
        try testing.expectEqual(true, archetypes.hasComponent(entity, Testing.Component.C));
    }
}
