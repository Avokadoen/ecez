const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ztracy = @import("ztracy");

const query = @import("query.zig");
const meta = @import("meta.zig");

const archetype_container = @import("archetype_container.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const Color = @import("misc.zig").Color;
const SystemMetadata = meta.SystemMetadata;

const Testing = @import("Testing.zig");

/// Create an event which can be triggered and dispatch associated systems
/// Parameters:
///     - event_name: the name of the event
///     - systems: the systems that should be dispatched if this event is triggered
pub const Event = meta.Event;

/// Mark system arguments as shared state
pub const SharedState = meta.SharedState;
pub const EventArgument = meta.EventArgument;

/// Create a ecs instance by gradually defining application types, systems and events.
pub fn WorldBuilder() type {
    return WorldIntermediate(.{}, .{}, .{}, .{});
}

// temporary type state for world
fn WorldIntermediate(comptime prev_archetypes: anytype, comptime prev_shared_state: anytype, comptime prev_systems: anytype, comptime prev_events: anytype) type {
    return struct {
        const Self = @This();

        /// define application archetypes
        /// Parameters:
        ///     - archetypes: structures of archetypes that will used by the application
        pub fn WithArchetypes(comptime archetypes: anytype) type {
            return WorldIntermediate(archetypes, prev_shared_state, prev_systems, prev_events);
        }

        /// define application shared state
        /// Parameters:
        ///     - archetypes: structures of archetypes that will used by the application
        pub fn WithSharedState(comptime shared_state: anytype) type {
            return WorldIntermediate(prev_archetypes, shared_state, prev_systems, prev_events);
        }

        /// define application systems which should run on each dispatch
        /// Parameters:
        ///     - systems: a tuple of each system used by the world each frame
        pub fn WithSystems(comptime systems: anytype) type {
            return WorldIntermediate(prev_archetypes, prev_shared_state, systems, prev_events);
        }

        /// define application events that can be triggered programmatically
        ///     - events: a tuple of events created using the ecez.Event function
        pub fn WithEvents(comptime events: anytype) type {
            return WorldIntermediate(prev_archetypes, prev_shared_state, prev_systems, events);
        }

        /// build the world instance **type** which can be initialized
        pub fn init(allocator: Allocator, shared_state: anytype) !CreateWorld(prev_archetypes, prev_shared_state, prev_systems, prev_events) {
            return CreateWorld(prev_archetypes, prev_shared_state, prev_systems, prev_events).init(allocator, shared_state);
        }
    };
}

fn CreateWorld(
    comptime archetypes: anytype,
    comptime shared_state_types: anytype,
    comptime systems: anytype,
    comptime events: anytype,
) type {
    @setEvalBranchQuota(10_000);
    const Container = blk: {
        const archetypes_info = @typeInfo(@TypeOf(archetypes));
        if (archetypes_info != .Struct) {
            @compileError("submitted_archetypes was not a tuple of types");
        }
        var archetype_types: [archetypes_info.Struct.fields.len]type = undefined;
        for (archetypes_info.Struct.fields) |_, i| {
            archetype_types[i] = archetypes[i];
        }
        break :blk archetype_container.FromArchetypes(&archetype_types);
    };

    const SharedStateStorage = meta.SharedStateStorage(shared_state_types);

    const system_count = meta.countAndVerifySystems(systems);
    const systems_info = meta.systemInfo(system_count, systems);
    const event_count = meta.countAndVerifyEvents(events);

    return struct {
        const World = @This();

        pub const EventsEnum = meta.GenerateEventsEnum(event_count, events);
        container: Container,
        shared_state: SharedStateStorage,

        /// intialize the world structure
        /// Parameters:
        ///     - allocator: allocator used when initiating entities
        ///     - shared_state: a tuple with an initial state for ALL shared state data declared when constructing world type
        pub fn init(allocator: Allocator, shared_state: anytype) !World {
            const zone = ztracy.ZoneNC(@src(), "World init", Color.world);
            defer zone.End();

            var actual_shared_state: SharedStateStorage = undefined;
            const shared_state_map = meta.typeMap(shared_state_types, @TypeOf(shared_state));
            inline for (shared_state_map) |index, i| {
                const shared_info = @typeInfo(@TypeOf(shared_state[index]));
                // copy all data except the added magic field
                inline for (shared_info.Struct.fields) |field| {
                    @field(actual_shared_state[i], field.name) = @field(shared_state[index], field.name);
                }
            }

            const container = try Container.init(allocator);
            return World{
                .container = container,
                .shared_state = actual_shared_state,
            };
        }

        pub fn deinit(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World deinit", Color.world);
            defer zone.End();

            self.container.deinit();
        }

        /// Create an entity and returns the entity handle
        /// Parameters:
        ///     - archetype_state: the archetype that entity should be assigned and it's initial state
        pub fn createEntity(self: *World, archetype_state: anytype) !Entity {
            const zone = ztracy.ZoneNC(@src(), "World createEntity", Color.world);
            defer zone.End();
            return self.container.createEntity(archetype_state);
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn setComponent(self: *World, entity: Entity, component: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World setComponent", Color.world);
            defer zone.End();
            try self.container.setComponent(entity, component);
        }

        /// update the type of an entity
        /// Parameters:
        ///     - entity: the entity to update type of
        ///     - NewType: the new archetype of *entity*
        ///     - state: tuple of some components of *NewType*, or struct of type *NewType*
        ///              if *state* is a subset of *NewType*, then the missing components of *state*
        ///              must exist in *entity*'s previous type. Void is valid if *NewType* is a subset of
        ///              *entity* previous type.
        pub fn setEntityType(self: *World, entity: Entity, comptime NewType: type, state: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World setComponents", Color.world);
            defer zone.End();
            try self.container.setEntityType(entity, NewType, state);
        }

        /// Check if an entity has a given component
        /// Parameters:
        ///     - entity:    the entity to check for type Component
        ///     - Component: the type of the component to check after
        pub fn hasComponent(self: World, entity: Entity, comptime Component: type) bool {
            const zone = ztracy.ZoneNC(@src(), "World hasComponent", Color.world);
            defer zone.End();
            return self.container.hasComponent(entity, Component);
        }

        /// Fetch an entity's component data
        /// Parameters:
        ///     - entity:    the entity to retrieve Component from
        ///     - Component: the type of the component to retrieve
        pub fn getComponent(self: *World, entity: Entity, comptime Component: type) !Component {
            const zone = ztracy.ZoneNC(@src(), "World getComponent", Color.world);
            defer zone.End();
            return self.container.getComponent(entity, Component);
        }

        /// Call all systems registered when calling CreateWorld
        pub fn dispatch(self: *World) !void {
            const zone = ztracy.ZoneNC(@src(), "World dispatch", Color.world);
            defer zone.End();

            inline for (systems_info.metadata) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();
                const param_types = comptime metadata.paramArgTypes();

                // extract data relative to system for each relevant archetype
                const archetypes_system_data = self.container.getTypeSubsets(&component_query_types);
                for (archetypes_system_data) |archetype_system_data| {
                    var i: usize = 0;
                    while (i < archetype_system_data.len) : (i += 1) {
                        var arguments: std.meta.Tuple(&param_types) = undefined;
                        inline for (param_types) |Param, j| {
                            // TODO: FIXME: checking size of pointers is not valid ...
                            if (@sizeOf(Param) > 0) {
                                switch (metadata.args[j]) {
                                    .component_value => arguments[j] = archetype_system_data.storage[j].items[i],
                                    .component_ptr => arguments[j] = &archetype_system_data.storage[j].items[i],
                                    .event_argument_ptr, .event_argument_value => @compileError("event arguments are illegal for dispatch systems"),
                                    .shared_state_value => arguments[j] = self.getSharedStateWithSharedStateType(Param),
                                    .shared_state_ptr => arguments[j] = self.getSharedStatePtrWithSharedStateType(Param),
                                }
                            } else {
                                switch (metadata.args[j]) {
                                    .component_value => arguments[j] = Param{},
                                    .component_ptr => arguments[j] = &Param{},
                                    .event_argument_value, .event_argument_ptr => @compileError("requesting event argument with zero size is not allowed"),
                                    .shared_state_value, .shared_state_ptr => @compileError("requesting shared state with zero size is not allowed"),
                                }
                            }
                        }
                        const system_ptr = @ptrCast(*const systems_info.function_types[system_index], systems_info.functions[system_index]);
                        // call either a failable system, or a normal void system
                        if (comptime metadata.canReturnError()) {
                            try failableCallWrapper(system_ptr.*, arguments);
                        } else {
                            callWrapper(system_ptr.*, arguments);
                        }
                    }
                }
            }
        }

        fn triggerEvent(self: *World, comptime event: EventsEnum, event_extra_argument: anytype) !void {
            const tracy_zone_name = std.fmt.comptimePrint("World trigger {any}", .{event});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.world);
            defer zone.End();

            const e = events[@enumToInt(event)];

            // TODO: verify systems and arguments in type initialization
            const EventExtraArgument = @TypeOf(event_extra_argument);
            if (@sizeOf(e.EventArgument) > 0) {
                if (comptime meta.isEventArgument(EventExtraArgument)) {
                    @compileError("event arguments should not be wrapped in EventArgument type when triggering an event");
                }
                if (EventExtraArgument != e.EventArgument) {
                    @compileError("event " ++ @tagName(event) ++ " was declared to accept " ++ @typeName(e.EventArgument) ++ " got " ++ @typeName(EventExtraArgument));
                }
            }

            const TargetEventArg = meta.EventArgument(EventExtraArgument);

            inline for (e.systems_info.metadata) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();
                const param_types = comptime metadata.paramArgTypes();

                // extract data relative to system for each relevant archetype
                const archetypes_system_data = self.container.getTypeSubsets(&component_query_types);
                for (archetypes_system_data) |archetype_system_data| {
                    var i: usize = 0;
                    while (i < archetype_system_data.len) : (i += 1) {
                        var arguments: std.meta.Tuple(&param_types) = undefined;
                        inline for (param_types) |Param, j| {
                            // TODO: FIXME: checking size of pointers is not valid ...
                            if (@sizeOf(Param) > 0) {
                                switch (metadata.args[j]) {
                                    .component_value => arguments[j] = archetype_system_data.storage[j].items[i],
                                    .component_ptr => arguments[j] = &archetype_system_data.storage[j].items[i],
                                    .event_argument_value => arguments[j] = @bitCast(TargetEventArg, event_extra_argument),
                                    .event_argument_ptr => arguments[j] = @ptrCast(*TargetEventArg, &event_extra_argument),
                                    .shared_state_value => arguments[j] = self.getSharedStateWithSharedStateType(Param),
                                    .shared_state_ptr => arguments[j] = self.getSharedStatePtrWithSharedStateType(Param),
                                }
                            } else {
                                switch (metadata.args[j]) {
                                    .component_value => arguments[j] = Param{},
                                    .component_ptr => arguments[j] = &Param{},
                                    .event_argument_ptr => arguments[j] = @bitCast(TargetEventArg, event_extra_argument),
                                    .event_argument_value => arguments[j] = @ptrCast(*TargetEventArg, &event_extra_argument),
                                    .shared_state_value, .shared_state_ptr => @compileError("requesting shared state with zero size is not allowed"),
                                }
                            }
                        }

                        const system_ptr = @ptrCast(*const e.systems_info.function_types[system_index], e.systems_info.functions[system_index]);
                        // call either a failable system, or a normal void system
                        if (comptime metadata.canReturnError()) {
                            try failableCallWrapper(system_ptr.*, arguments);
                        } else {
                            callWrapper(system_ptr.*, arguments);
                        }
                    }
                }
            }
        }

        /// get a shared state using the inner type
        pub fn getSharedState(self: World, comptime T: type) meta.SharedState(T) {
            return self.getSharedStateWithSharedStateType(meta.SharedState(T));
        }

        /// get a shared state using ecez.SharedState(InnerType) retrieve it's current value
        pub fn getSharedStateWithSharedStateType(self: World, comptime T: type) T {
            const index = indexOfSharedType(T);
            return self.shared_state[index];
        }

        // blocked by: https://github.com/ziglang/zig/issues/5497
        // /// set a shared state using the shared state's inner type
        // pub fn setSharedState(self: World, state: anytype) void {
        //     const ActualType = meta.SharedState(@TypeOf(state));
        //     const index = indexOfSharedType(ActualType);
        //     self.shared_state[index] = @bitCast(ActualType, state);
        // }

        /// given a shared state type T retrieve it's pointer
        pub fn getSharedStatePtrWithSharedStateType(self: *World, comptime PtrT: type) PtrT {
            // figure out which type we are looking for in the storage
            const QueryT = blk: {
                const info = @typeInfo(PtrT);
                if (info != .Pointer) {
                    @compileError("PtrT '" ++ @typeName(PtrT) ++ "' is not a pointer type, this is a ecez bug. please file an issue!");
                }
                const ptr_info = info.Pointer;

                const child_info = @typeInfo(ptr_info.child);
                if (child_info != .Struct) {
                    @compileError("PtrT child '" ++ @typeName(ptr_info.child) ++ " is not a struct type, this is a ecez bug. please file an issue!");
                }
                break :blk ptr_info.child;
            };

            const index = indexOfSharedType(QueryT);
            return &self.shared_state[index];
        }

        fn indexOfSharedType(comptime Shared: type) comptime_int {
            const shared_storage_fields = @typeInfo(SharedStateStorage).Struct.fields;
            inline for (shared_storage_fields) |field, i| {
                if (field.field_type == Shared) {
                    return i;
                }
            }
            @compileError(@typeName(Shared) ++ " is not a shared state");
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

// world without systems
const WorldStub = WorldBuilder().WithArchetypes(Testing.AllArchetypesTuple);

test "init() + deinit() is idempotent" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity0 = try world.createEntity(Testing.Archetype.A{});
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try world.createEntity(Testing.Archetype.A{});
    try testing.expectEqual(entity1.id, 1);
}

// test "setComponent() component moves entity to correct archetype" {
//     const A = struct { some_value: u32 };
//     const B = struct { some_value: u8 };

//     var world = try WorldStub.init(testing.allocator);
//     defer world.deinit();

//     const entity1 = try world.createEntity();
//     // entity is now a void entity (no components)

//     const a = A{ .some_value = 123 };
//     try world.setComponent(entity1, a);
//     // entity is now of archetype (A)

//     const b = B{ .some_value = 42 };
//     try world.setComponent(entity1, b);
//     // entity is now of archetype (A B)

//     const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
//     const stored_a = try entity_archetype.getComponent(entity1, A);
//     try testing.expectEqual(a, stored_a);
//     const stored_b = try entity_archetype.getComponent(entity1, B);
//     try testing.expectEqual(b, stored_b);
// }

test "setComponent() update entities component state" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(Testing.Archetype.AB{});
    // entity is now a void entity (no components)

    const a = Testing.Component.A{ .value = 123 };
    try world.setComponent(entity, a);
    // entity is now of archetype (A B)

    const stored_a = try world.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
}

test "hasComponent() responds as expected" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(Testing.Archetype.AC{});

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.B));
}

test "getComponent() retrieve component value" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 0 } });
    _ = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 1 } });
    _ = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 2 } });

    const a = Testing.Component.A{ .value = 123 };
    const entity = try world.createEntity(Testing.Archetype.A{ .a = a });

    _ = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 3 } });
    _ = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 4 } });

    try testing.expectEqual(a, try world.getComponent(entity, Testing.Component.A));
}

test "getSharedState retrieve state" {
    var world = try WorldStub.WithSharedState(.{ Testing.Component.A, Testing.Component.B }).init(testing.allocator, .{
        Testing.Component.A{ .value = 4 },
        Testing.Component.B{ .value = 2 },
    });
    defer world.deinit();

    try testing.expectEqual(@as(u32, 4), world.getSharedState(Testing.Component.A).value);
    try testing.expectEqual(@as(u8, 2), world.getSharedState(Testing.Component.B).value);
}

// blocked by: https://github.com/ziglang/zig/issues/5497
// test "setSharedState retrieve state" {
//     var world = try WorldStub.WithSharedState(.{ Testing.Component.A, Testing.Component.B }).init(testing.allocator, .{
//         Testing.Component.A{ .value = 0 },
//         Testing.Component.B{ .value = 0 },
//     });
//     defer world.deinit();

//     world.setSharedState(Testing.Component.A{ .value = 4 });
//     world.setSharedState(Testing.Component.B{ .value = 2 });

//     try testing.expectEqual(@as(u32, 4), world.getSharedState(Testing.Component.A).value);
//     try testing.expectEqual(@as(u8, 2), world.getSharedState(Testing.Component.B).value);
// }

test "systems can fail" {
    const SystemStruct = struct {
        pub fn aSystem(a: Testing.Component.A) !void {
            try testing.expectEqual(Testing.Component.A{ .value = 42 }, a);
        }

        pub fn bSystem(b: Testing.Component.B) !void {
            _ = b;
            return error.SomethingWentVeryWrong;
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).init(testing.allocator, .{});
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.AB{
        .a = .{ .value = 42 },
    });

    try testing.expectError(error.SomethingWentVeryWrong, world.dispatch());
}

test "systems can mutate components" {
    const SystemStruct = struct {
        pub fn mutateStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value += @intCast(u32, b.value);
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(Testing.Archetype.AB{
        .a = .{ .value = 1 },
        .b = .{ .value = 2 },
    });

    try world.dispatch();

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "systems can access shared state" {
    const A = struct {
        value: u8,
    };

    const SystemStruct = struct {
        pub fn aSystem(a: Testing.Component.A, shared: SharedState(A)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 8), shared.value);
        }

        pub fn bSystem(a: Testing.Component.A, b: Testing.Component.B, shared: SharedState(A)) !void {
            _ = a;
            _ = b;
            if (shared.value == 8) {
                return error.EightIsGreat;
            }
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).WithSharedState(.{
        A,
    }).init(testing.allocator, .{
        A{ .value = 8 },
    });
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.AB{});

    try testing.expectError(error.EightIsGreat, world.dispatch());
}

test "systems can mutate shared state" {
    const A = struct {
        value: u8,
    };
    const SystemStruct = struct {
        pub fn func(a: Testing.Component.A, shared: *SharedState(A)) !void {
            _ = a;
            shared.value += 1;
        }

        pub fn bSystem(a: Testing.Component.A, b: Testing.Component.B, shared: *SharedState(A)) !void {
            _ = a;
            _ = b;
            shared.value += 1;
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).WithSharedState(.{
        A,
    }).init(testing.allocator, .{
        A{ .value = 0 },
    });
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.AB{});
    try world.dispatch();

    try testing.expectEqual(@as(u8, 2), world.shared_state[0].value);
}

test "systems can have many shared state" {
    const A = struct {
        value: u8,
    };
    const B = struct {
        value: u8,
    };
    const C = struct {
        value: u8,
    };

    const SystemStruct = struct {
        pub fn system1(a: Testing.Component.A, shared: SharedState(A)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 0), shared.value);
        }

        pub fn system2(a: Testing.Component.A, shared: SharedState(B)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 1), shared.value);
        }

        pub fn system3(a: Testing.Component.A, shared: SharedState(C)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 2), shared.value);
        }

        pub fn system4(a: Testing.Component.A, shared_a: SharedState(A), shared_b: SharedState(B)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 0), shared_a.value);
            try testing.expectEqual(@as(u8, 1), shared_b.value);
        }

        pub fn system5(a: Testing.Component.A, shared_b: SharedState(B), shared_a: SharedState(A)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 0), shared_a.value);
            try testing.expectEqual(@as(u8, 1), shared_b.value);
        }

        pub fn system6(a: Testing.Component.A, shared_c: SharedState(C), shared_b: SharedState(B), shared_a: SharedState(A)) !void {
            _ = a;
            try testing.expectEqual(@as(u8, 0), shared_a.value);
            try testing.expectEqual(@as(u8, 1), shared_b.value);
            try testing.expectEqual(@as(u8, 2), shared_c.value);
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).WithSharedState(.{
        A, B, C,
    }).init(testing.allocator, .{
        A{ .value = 0 },
        B{ .value = 1 },
        C{ .value = 2 },
    });
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.A{});

    try world.dispatch();
}

test "systems can be registered through struct or individual function(s)" {
    const SystemStruct1 = struct {
        pub fn func1(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn func2(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    const SystemStruct2 = struct {
        pub fn func3(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn func4(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct1.func1,
        SystemStruct1.func2,
        SystemStruct2,
    }).init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(Testing.Archetype.A{
        .a = .{ .value = 0 },
    });

    try world.dispatch();

    try testing.expectEqual(
        Testing.Component.A{ .value = 4 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "events call systems" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: *Testing.Component.A) void {
            a.value += 1;
        }
        pub fn systemTwo(b: *Testing.Component.B) void {
            b.value += 1;
        }
    };

    const systemThree = struct {
        fn func(b: *Testing.Component.A) void {
            b.value += 1;
        }
    }.func;

    const World = WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
        Event("onBar", .{systemThree}, .{}),
    });

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    const entity1 = try world.createEntity(Testing.Archetype.AB{
        .a = .{ .value = 0 },
        .b = .{ .value = 0 },
    });
    const entity2 = try world.createEntity(Testing.Archetype.A{
        .a = .{ .value = 2 },
    });

    try world.triggerEvent(.onFoo, .{});

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try world.getComponent(entity1, Testing.Component.B),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity2, Testing.Component.A),
    );

    try world.triggerEvent(.onBar, .{});

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try world.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 4 },
        try world.getComponent(entity2, Testing.Component.A),
    );
}

test "events call propagate error" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: Testing.Component.A) !void {
            _ = a;
            return error.Spooky;
        }
    };

    const World = WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    });

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.A{});

    try testing.expectError(error.Spooky, world.triggerEvent(.onFoo, .{}));
}

test "events can access shared state" {
    const A = struct { value: u8 };
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: Testing.Component.A, shared: SharedState(A)) !void {
            _ = a;
            if (shared.value == 42) {
                return error.Ok;
            }
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).WithSharedState(.{
        A,
    }).init(testing.allocator, .{A{ .value = 42 }});

    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.A{});

    try testing.expectError(error.Ok, world.triggerEvent(.onFoo, .{}));
}

test "events can mutate shared state" {
    const A = struct { value: u8 };
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: Testing.Component.A, shared: *SharedState(A)) void {
            _ = a;
            shared.value = 2;
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).WithSharedState(.{
        A,
    }).init(testing.allocator, .{A{ .value = 1 }});

    defer world.deinit();

    _ = try world.createEntity(Testing.Archetype.A{});

    try world.triggerEvent(.onFoo, .{});
    try testing.expectEqual(@as(u8, 2), world.shared_state[0].value);
}

test "events can accepts event related data" {
    const MouseInput = struct { x: u32, y: u32 };
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: *Testing.Component.A, mouse: EventArgument(MouseInput)) void {
            a.value = mouse.x + mouse.y;
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, MouseInput),
    }).init(testing.allocator, .{});

    defer world.deinit();

    const entity = try world.createEntity(Testing.Archetype.A{ .a = .{ .value = 0 } });

    try world.triggerEvent(.onFoo, MouseInput{ .x = 40, .y = 2 });
    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try world.getComponent(entity, Testing.Component.A),
    );
}
