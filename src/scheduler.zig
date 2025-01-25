const std = @import("std");

const ztracy = @import("ztracy");

const ThreadPool = @import("StdThreadPool.zig");
const ResetEvent = std.Thread.ResetEvent;

const QueryType = @import("storage.zig").QueryType;
const StorageType = @import("storage.zig").StorageType;
const SubsetType = @import("storage.zig").SubsetType;

const gen_dependency_chain = @import("dependency_chain.zig");

const Color = @import("misc.zig").Color;

pub const Config = struct {
    /// Used to handle auxiliary memory for thread workers in the thread pool
    /// Recommended to use a dedicated Arena or a FixedBuffer allocator
    pool_allocator: std.mem.Allocator,
    /// Used on dispatch to submit arguments that are of Storage.Query type.
    /// Make sure the allocator is thread safe.
    /// Recommended to use a dedicated Arena or a FixedBuffer allocator
    query_submit_allocator: std.mem.Allocator,
    /// Override the pool thread count.
    /// By default it will query the current host CPU and use the logical core count.
    thread_count: ?u32 = null,
};

/// Allow the user to attach systems to a storage. The user can then trigger events on the scheduler to execute
/// the systems in a multithreaded environment
pub fn CreateScheduler(comptime events: anytype) type {
    const event_count = CompileReflect.countAndVerifyEvents(events);

    // Store each individual ResetEvent
    const EventsInFlight = blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        inline for (&fields, events, 0..) |*field, event, i| {
            const system_count = CompileReflect.countAndVerifySystems(event);

            const default_value = [_]ResetEvent{.{}} ** system_count;
            var num_buf: [8:0]u8 = undefined;
            const name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
            num_buf[name.len] = 0;

            field.* = Type.StructField{
                .name = name[0.. :0],
                .type = [system_count]ResetEvent,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf([system_count]ResetEvent),
            };
        }

        break :blk @Type(Type{ .Struct = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
        } });
    };

    // Calculate dependencies
    const Dependencies = CompileReflect.DependencyListsType(events, event_count){};

    return struct {
        const Scheduler = @This();

        pub const EventsEnum = CompileReflect.GenerateEventEnum(events);

        query_submit_allocator: std.mem.Allocator,
        thread_pool: *ThreadPool,
        events_in_flight: EventsInFlight,

        /// Initialized the system scheduler. User must make sure to call deinit
        pub fn init(config: Config) !Scheduler {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer zone.End();

            const thread_pool = try config.pool_allocator.create(ThreadPool);
            errdefer config.pool_allocator.destroy(thread_pool);

            try ThreadPool.init(thread_pool, .{
                .allocator = config.pool_allocator,
                .n_jobs = config.thread_count,
            });

            var events_in_flight = EventsInFlight{};
            inline for (0..event_count) |event_index| {
                for (&events_in_flight[event_index]) |*system_in_flight| {
                    system_in_flight.set();
                }
            }

            return Scheduler{
                .query_submit_allocator = config.query_submit_allocator,
                .thread_pool = thread_pool,
                .events_in_flight = events_in_flight,
            };
        }

        pub fn deinit(self: *Scheduler) void {
            self.thread_pool.deinit();
            const allocator = self.thread_pool.allocator;
            allocator.destroy(self.thread_pool);
        }

        /// Trigger an event asynchronously. The caller must make sure to call waitEvent with matching enum identifier
        /// Before relying on the result of a trigger.
        /// Parameters:
        ///     - event:            The event enum identifier. When registering an event on Wolrd creation a identifier is
        ///                         submitted.
        ///     - event_argument:   An event specific argument. Keep in mind that if you submit a pointer as argument data
        ///                         then the lifetime of the argument must out live the execution of the event.
        ///
        /// Example:
        /// ```
        /// const Scheduler = ecez.CreateScheduler(Storage, .{ecez.Event("onMouse", .{onMouseSystem}, MouseArg)})
        /// // ... storage creation etc ...
        /// // trigger mouse handle
        /// scheduler.dispatchEvent(&storage, .onMouse, @as(MouseArg, mouse));
        /// ```
        pub fn dispatchEvent(self: *Scheduler, storage: anytype, comptime event: EventsEnum, event_argument: anytype) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("dispatchEvent {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const Storage = get_storage_type_blk: {
                const StoragePtr = @TypeOf(storage);
                const storage_ptr = @typeInfo(StoragePtr);
                if (storage_ptr != .Pointer) {
                    @compileError(@src().fn_name ++ " expected argument storage to be pointer to a ecez.Storage, got " ++ @typeName(StoragePtr));
                }

                const child_type = storage_ptr.Pointer.child;
                const is_storage_type = check_if_storage_type_blk: {
                    if (@hasDecl(child_type, "EcezType") == false) {
                        break :check_if_storage_type_blk false;
                    }

                    if (child_type.EcezType != StorageType) {
                        break :check_if_storage_type_blk false;
                    }

                    break :check_if_storage_type_blk true;
                };

                if (is_storage_type == false) {
                    @compileError(@src().fn_name ++ " got storage of unkown type " ++ @typeName(@TypeOf(storage)) ++ ", expected *ecez.CreateStorage");
                }

                break :get_storage_type_blk child_type;
            };

            const event_index = @intFromEnum(event);
            const event_in_flight = &self.events_in_flight[event_index];
            const triggered_event = events[event_index];

            const event_dependencies = @field(Dependencies, triggered_event._name);
            inline for (triggered_event._systems, event_dependencies, 0..) |system, system_dependencies, system_index| {
                const DispatchJob = EventDispatchJob(
                    system,
                    Storage,
                    @TypeOf(event_argument),
                );

                // initialized the system job
                const system_job = DispatchJob{
                    .query_submit_allocator = self.query_submit_allocator,
                    .storage = storage,
                    .event_argument = event_argument,
                };

                // Assert current system is not executing
                std.debug.assert(event_in_flight[system_index].isSet());

                // NOTE: Work around compiler crash: dont use reference to empty structs
                const dependencies = comptime if (system_dependencies.wait_on_indices.len == 0) &[0]u32{} else system_dependencies.wait_on_indices;
                self.thread_pool.spawnRe(
                    dependencies,
                    event_in_flight,
                    system_index,
                    DispatchJob.exec,
                    .{system_job},
                );
            }
        }

        /// Wait for all jobs from a dispatchEvent to finish by blocking the calling thread
        /// should only be called from the dispatchEvent thread
        pub fn waitEvent(self: *Scheduler, comptime event: EventsEnum) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("{s}: event {s}", .{ @src().fn_name, @tagName(event) });
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const event_in_flight = &self.events_in_flight[@intFromEnum(event)];
            for (event_in_flight) |*system_event| {
                system_event.wait();
            }
        }

        /// Force the storage to flush all current in flight jobs before continuing
        pub fn waitIdle(self: *Scheduler) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer zone.End();

            inline for (0..events.len) |event_enum_int| {
                self.waitEvent(@enumFromInt(event_enum_int));
            }
        }

        /// Dump the dependency chain of systems to see which systems will wait on which previous systems
        pub fn dumpDependencyChain(comptime event: EventsEnum) []const gen_dependency_chain.Dependency {
            if (@inComptime() == false) {
                @compileError(@src().fn_name ++ " should be called in comptime only");
            }

            const event_index = @intFromEnum(event);
            const triggered_event = events[event_index];
            const event_dependencies = @field(Dependencies, triggered_event._name);
            return &event_dependencies;
        }

        fn EventDispatchJob(
            comptime func: anytype,
            comptime Storage: type,
            comptime EventArgument: type,
        ) type {
            return struct {
                const DispatchJob = @This();

                event_argument: EventArgument,
                query_submit_allocator: std.mem.Allocator,
                storage: *Storage,

                pub fn exec(self_job: DispatchJob) void {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    const FuncType = @TypeOf(func);
                    const param_types = comptime get_param_types_blk: {
                        const func_info = @typeInfo(FuncType);
                        var types: [func_info.Fn.params.len]type = undefined;
                        for (&types, func_info.Fn.params) |*Type, param| {
                            Type.* = param.type.?;
                        }

                        break :get_param_types_blk types;
                    };

                    var arguments: std.meta.Tuple(&param_types) = undefined;
                    inline for (param_types, &arguments) |Param, *argument| {
                        var arg = get_arg_blk: {
                            if (Param == EventArgument) {
                                break :get_arg_blk self_job.event_argument;
                            }

                            const param_info = @typeInfo(Param);
                            if (param_info != .Pointer) {
                                @compileError("System Query and Subset arguments must be pointer type");
                            }

                            break :get_arg_blk switch (param_info.Pointer.child.EcezType) {
                                // TODO: scheduler should have an allocator for this
                                QueryType => param_info.Pointer.child.submit(self_job.query_submit_allocator, self_job.storage) catch @panic("Scheduler dispatch query_submit_allocator OOM"),
                                SubsetType => param_info.Pointer.child{ .storage = self_job.storage },
                                else => |Type| @compileError("Unknown EcezType " ++ @typeName(Type)), // This is a ecez bug if hit (i.e not user error)
                            };
                        };

                        // TODO: store all queries on self_job struct to ensure lifetime
                        if (Param == EventArgument) {
                            argument.* = self_job.event_argument;
                        } else {
                            argument.* = &arg;
                        }
                    }

                    // if this is a debug build we do not want inline (to get better error messages), otherwise inline systems for performance
                    const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .always_inline;
                    @call(system_call_modidifer, func, arguments);

                    inline for (param_types, &arguments) |Param, *arg| {
                        if (Param == EventArgument) {
                            continue;
                        }

                        const param_info = @typeInfo(Param);

                        switch (param_info.Pointer.child.EcezType) {
                            QueryType => arg.*.deinit(self_job.query_submit_allocator),
                            else => {},
                        }
                    }
                }
            };
        }
    };
}

pub const EventType = struct {};

pub fn Event(comptime name: []const u8, comptime systems: anytype) type {
    const systems_fields = @typeInfo(@TypeOf(systems));
    if (systems_fields != .Struct) {
        @compileError("Event expect systems to be a tuple of systems");
    }

    for (systems_fields.Struct.fields, 0..) |system_field, system_index| {
        const system_field_info = @typeInfo(system_field.type);
        if (system_field_info != .Fn) {
            const error_msg = std.fmt.comptimePrint("Event must be populated with functions, system number '{d}' was {s}", .{
                system_index,
                @typeName(system_field.type),
            });
            @compileError(error_msg);
        }
    }

    return struct {
        const ThisEvent = @This();

        pub const EcezType = EventType;
        pub const _name = name;
        pub const _systems = systems;

        // TODO: validate given a storage
        pub fn getSystemCount() u32 {
            comptime var system_count = 0;
            const systems_info = @typeInfo(@TypeOf(ThisEvent._systems));
            system_loop: inline for (systems_info.Struct.fields) |field_system| {
                const system_info = @typeInfo(field_system.type);
                if (system_info != .Fn) {
                    continue :system_loop;
                }
                system_count += 1;
            }

            return system_count;
        }
    };
}

// TODO: move scheduler and dependency_chain to same folder. Move this logic in this folder out of this file
pub const CompileReflect = struct {
    pub fn countAndVerifyEvents(comptime events: anytype) u32 {
        const events_info = events_info_blk: {
            const info: std.builtin.Type = @typeInfo(@TypeOf(events));
            if (info != .Struct) {
                @compileError("expected events to be a struct of Event");
            }
            break :events_info_blk info.Struct;
        };

        inline for (events_info.fields, 0..) |events_fields, event_index| {
            if (events_fields.default_value == null) {
                @compileError(std.fmt.comptimePrint("event number {d} is not an event. Events must be created with ecez.Event()", .{event_index}));
            }

            const this_event = @as(*const events_fields.type, @ptrCast(events_fields.default_value.?)).*;
            const has_EcezType = @hasField(this_event, "EcezType");
            const has_name = @hasField(this_event, "_name");
            const has_systems = @hasField(this_event, "_systems");

            const has_expected_decls = has_EcezType and has_name and has_systems;
            if (has_expected_decls) {
                @compileError(@typeName(events[event_index]) ++ " Event missing expected decal. Events must be created with ecez.Event()");
            }

            if (this_event.EcezType != EventType) {
                @compileError(std.fmt.comptimePrint("event number {d} is not an event. Events must be created with ecez.Event()", .{event_index}));
            }
        }

        return events_info.fields.len;
    }
    test "countAndVerifyEvents return correct event count" {
        const event1 = Event("a", .{countAndVerifyEvents});
        const event2 = Event("b", .{std.debug.assert});
        const event3 = Event("c", .{std.debug.assert});
        const event_count = countAndVerifyEvents(.{ event1, event2, event3 });
        try std.testing.expectEqual(3, event_count);
    }

    pub fn countAndVerifySystems(comptime event: anytype) u32 {
        {
            const info: std.builtin.Type = @typeInfo(event);
            if (info != .Struct) {
                @compileError("expected events to be a struct of Event");
            }
        }

        comptime var system_count = 0;
        const systems_info = @typeInfo(@TypeOf(event._systems));
        system_loop: inline for (systems_info.Struct.fields) |field_system| {
            const system_info = @typeInfo(field_system.type);
            if (system_info != .Fn) {
                continue :system_loop;
            }

            // Ensure arguments are queries
            const params = system_info.Fn.params;
            for (params) |param| {
                if (param.is_generic) {
                    @compileError("system of type " ++ @typeName(field_system.type) ++ " has generic parameter, expected ecez storage query, or event argument");
                }

                if (param.type == null) {
                    @compileError("system of type " ++ @typeName(field_system.type) ++ " is missing type, expected ecez storage query, or event argument");
                }

                // TODO: verify that system has EventArgument, or Query, or ???
                // const ParamType = param.type.?;
                // const has_EcezType = @hasField(ParamType, "EcezType");
                // if (has_EcezType == false or ParamType.EcezType != QueryType) {
                //     @compileError("system of type " ++ @typeName(field_system.type) ++ " has parameter of type '" ++ @typeName(ParamType) ++ "' expected ecez storage query");
                // }
            }

            system_count += 1;
        }

        return system_count;
    }
    test "countAndVerifySystems return correct system count" {
        const event1 = Event("a", .{std.debug.assert});
        const event2 = Event("b", .{ std.debug.assert, std.debug.assert });
        const event3 = Event("c", .{ std.debug.assert, std.debug.assert, std.debug.assert });

        try std.testing.expectEqual(1, comptime countAndVerifySystems(event1));
        try std.testing.expectEqual(2, comptime countAndVerifySystems(event2));
        try std.testing.expectEqual(3, comptime countAndVerifySystems(event3));
    }

    pub fn GenerateEventEnum(comptime events: anytype) type {
        const events_info = @typeInfo(@TypeOf(events)).Struct;

        var enum_fields: [events_info.fields.len]std.builtin.Type.EnumField = undefined;
        inline for (&enum_fields, events_info.fields, 0..) |*enum_field, events_fields, enum_value| {
            const this_event = @as(*const events_fields.type, @ptrCast(events_fields.default_value.?)).*;
            enum_field.name = this_event._name[0.. :0];
            enum_field.value = enum_value;
        }

        const enum_info = std.builtin.Type{ .Enum = .{
            .tag_type = u32,
            .fields = &enum_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        } };

        return @Type(enum_info);
    }

    pub fn DependencyListsType(comptime events: anytype, comptime event_count: u32) type {
        var dependency_lists_type_fields: [event_count]std.builtin.Type.StructField = undefined;
        for (&dependency_lists_type_fields, events) |*dependency_lists_type_field, event| {
            const system_count = event.getSystemCount();
            const DependecyArrayType = [system_count]gen_dependency_chain.Dependency;
            const value = gen_dependency_chain.buildDependencyList(event._systems, system_count);

            dependency_lists_type_field.* = .{
                .name = event._name[0.. :0],
                .type = DependecyArrayType,
                .default_value = @ptrCast(&value),
                .is_comptime = true,
                .alignment = @alignOf(DependecyArrayType),
            };
        }

        return @Type(std.builtin.Type{ .Struct = .{
            .layout = .auto,
            .fields = &dependency_lists_type_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } });
    }
};

const Testing = @import("Testing.zig");
const testing = std.testing;

const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;

const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;

const StorageStub = CreateStorage(Testing.AllComponentsTuple);
const Queries = Testing.Queries;

test "system query can mutate components" {
    const Query = StorageStub.Query(
        struct {
            a: *Testing.Component.A,
            b: Testing.Component.B,
        },
        .{},
        .{},
    );

    const SystemStruct = struct {
        pub fn mutateStuff(ab: *Query) void {
            while (ab.next()) |ent_ab| {
                ent_ab.a.value += ent_ab.b.value;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const OnFooEvent = Event("onFoo", .{SystemStruct.mutateStuff});

    var scheduler = try CreateScheduler(.{OnFooEvent}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "system SubStorage can spawn new entites (and no race hazards)" {
    const SubsetA = StorageStub.Subset(.{*Testing.Component.A});
    const SubsetB = StorageStub.Subset(.{*Testing.Component.B});

    const initial_entity_count = 100;
    // This would probably be better as data stored in components instead of EventArgument
    const SpawnedEntities = struct {
        a: [initial_entity_count]Entity,
        b: [initial_entity_count]Entity,
    };

    const SystemStruct = struct {
        pub fn incrB(b_query: *Queries.WriteB) void {
            while (b_query.next()) |item| {
                item.b.value += 1;
            }
        }

        pub fn decrB(b_query: *Queries.WriteB) void {
            while (b_query.next()) |item| {
                item.b.value -= 1;
            }
        }

        pub fn incrA(a_query: *Queries.WriteA) void {
            while (a_query.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn decrA(a_query: *Queries.WriteA) void {
            while (a_query.next()) |item| {
                item.a.value -= 1;
            }
        }

        pub fn spawnEntityAFromB(b_query: *Queries.ReadB, a_sub: *SubsetA, spawned_entities: *SpawnedEntities) void {
            for (&spawned_entities.a) |*entity| {
                const item = b_query.next().?;

                entity.* = a_sub.createEntity(.{
                    Testing.Component.A{ .value = item.b.value },
                }) catch @panic("OOM");
            }
        }

        pub fn spawnEntityBFromA(a_query: *Queries.ReadA, b_sub: *SubsetB, spawned_entities: *SpawnedEntities) void {
            // Loop reverse to make it more likely for race conditions to cause issues
            for (0..spawned_entities.b.len) |reverse_index| {
                const item = a_query.next().?;

                const index = spawned_entities.b.len - reverse_index - 1;
                spawned_entities.b[index] = b_sub.createEntity(.{
                    Testing.Component.B{ .value = @intCast(item.a.value) },
                }) catch @panic("OOM");
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event(
        "onFoo",
        .{
            SystemStruct.incrB,
            SystemStruct.decrB,
            SystemStruct.spawnEntityAFromB,
            SystemStruct.spawnEntityBFromA,
            SystemStruct.incrA,
            SystemStruct.decrA,
        },
    )}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    // Do this test repeatedly to ensure it's determenistic (no race hazards)
    for (0..128) |_| {
        storage.clearRetainingCapacity();

        var initial_entites: [initial_entity_count]Entity = undefined;
        for (&initial_entites, 0..) |*entity, iter| {
            entity.* = try storage.createEntity(.{
                Testing.Component.B{ .value = @intCast(iter) },
            });
        }

        var spawned_entites: SpawnedEntities = undefined;
        scheduler.dispatchEvent(&storage, .onFoo, &spawned_entites);
        scheduler.waitEvent(.onFoo);

        for (&initial_entites, 0..) |entity, iter| {
            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(iter) },
                try storage.getComponent(entity, Testing.Component.B),
            );
        }

        for (spawned_entites.a, 0..) |entity, iter| {
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(iter) },
                try storage.getComponent(entity, Testing.Component.A),
            );
        }

        for (spawned_entites.b, 0..) |entity, iter| {
            // Make sure these entities is not the ones we spawned in this for loop
            try std.testing.expect(entity.id != iter);

            const reverse = initial_entity_count - iter - 1;
            try testing.expectEqual(
                Testing.Component.B{ .value = @intCast(reverse) },
                try storage.getComponent(entity, Testing.Component.B),
            );
        }
    }
}

test "Thread count 0 works" {
    const SystemStruct = struct {
        pub fn incrB(b_query: *Queries.WriteB) void {
            while (b_query.next()) |item| {
                item.b.value += 1;
            }
        }

        pub fn decrB(b_query: *Queries.WriteB) void {
            while (b_query.next()) |item| {
                item.b.value -= 1;
            }
        }

        pub fn incrA(a_query: *Queries.WriteA) void {
            while (a_query.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn decrA(a_query: *Queries.WriteA) void {
            while (a_query.next()) |item| {
                item.a.value -= 1;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event(
        "onFoo",
        .{
            SystemStruct.incrB,
            SystemStruct.decrB,
            SystemStruct.incrA,
            SystemStruct.decrA,
        },
    )}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    for (0..128) |iter| {
        _ = try storage.createEntity(.{
            Testing.Component.B{ .value = @intCast(iter) },
        });
    }

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);
}

test "system sub storage can mutate components" {
    const SubStorage = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });

    const SystemStruct = struct {
        pub fn mutateStuff(entities: *Queries.Entities, ab: *SubStorage) void {
            while (entities.next()) |item| {
                const a = ab.getComponent(item.entity, Testing.Component.A) catch @panic("oof");

                ab.setComponents(item.entity, .{
                    Testing.Component.B{ .value = @intCast(a.value) },
                }) catch @panic("oof");
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event("onFoo", .{SystemStruct.mutateStuff})}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.B{ .value = 42 },
        try storage.getComponent(entity, Testing.Component.B),
    );
}

test "Dispatch is determenistic (no race conditions)" {
    const AbSubStorage = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });

    const SystemStruct = struct {
        pub fn incrA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn incrB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value += 1;
            }
        }

        pub fn doubleA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value *= 2;
            }
        }

        pub fn doubleB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value *= 2;
            }
        }

        pub fn storageIncrAIncrB(entities: *Queries.Entities, sub: *AbSubStorage) void {
            while (entities.next()) |item| {
                const ab = sub.getComponents(item.entity, struct {
                    a: *Testing.Component.A,
                    b: *Testing.Component.B,
                }) catch @panic("oof");

                ab.a.value += 1;
                ab.b.value += 1;
            }
        }

        pub fn storageDoubleADoubleB(entities: *Queries.Entities, sub: *AbSubStorage) void {
            while (entities.next()) |item| {
                const ab = sub.getComponents(item.entity, struct {
                    a: *Testing.Component.A,
                    b: *Testing.Component.B,
                }) catch @panic("oof");

                ab.a.value *= 2;
                ab.b.value *= 2;
            }
        }

        pub fn storageZeroAZeroB(entities: *Queries.Entities, sub: *AbSubStorage) void {
            while (entities.next()) |item| {
                sub.setComponents(item.entity, .{
                    Testing.Component.A{ .value = 0 },
                    Testing.Component.B{ .value = 0 },
                }) catch @panic("oof");
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    // Run the test many times, expect the same result
    for (0..128) |_| {
        defer storage.clearRetainingCapacity();

        var scheduler = try CreateScheduler(.{
            Event("onFoo", .{
                SystemStruct.storageZeroAZeroB,
                SystemStruct.incrA,
                SystemStruct.doubleA,
                SystemStruct.incrA,
                SystemStruct.incrB,
                SystemStruct.doubleB,
                SystemStruct.incrB,
                SystemStruct.storageDoubleADoubleB,
                SystemStruct.storageIncrAIncrB,
            }),
        }).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const initial_state = Testing.Structure.AB{
            .a = Testing.Component.A{ .value = 42 },
            .b = Testing.Component.B{ .value = 42 },
        };
        var entities: [128]Entity = undefined;
        for (&entities) |*entity| {
            entity.* = try storage.createEntity(initial_state);
        }

        // (((0 + 1) * 2) + 1) * 2 + 1 = 7
        const expected_value = 7;

        scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        for (entities) |entity| {
            const ab = try storage.getComponents(entity, Testing.Structure.AB);
            try testing.expectEqual(
                Testing.Component.A{ .value = expected_value },
                ab.a,
            );
            try testing.expectEqual(
                Testing.Component.B{ .value = expected_value },
                ab.b,
            );
        }

        // (((0 + 1) * 2) + 1) * 2 + 1 = 7
        scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        for (entities) |entity| {
            const ab = try storage.getComponents(entity, Testing.Structure.AB);
            try testing.expectEqual(
                Testing.Component.A{ .value = expected_value },
                ab.a,
            );
            try testing.expectEqual(
                Testing.Component.B{ .value = expected_value },
                ab.b,
            );
        }
    }
}

test "Dispatch with multiple events works" {
    const SystemStruct = struct {
        pub fn incrA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn incrB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value += 1;
            }
        }

        pub fn doubleA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value *= 2;
            }
        }

        pub fn doubleB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value *= 2;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{
        Event("onA", .{
            SystemStruct.incrA,
            SystemStruct.doubleA,
            SystemStruct.incrA,
        }),
        Event("onB", .{
            SystemStruct.incrB,
            SystemStruct.doubleB,
            SystemStruct.incrB,
        }),
    }).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const initial_state = Testing.Structure.AB{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    var entities: [1]Entity = undefined;
    for (&entities) |*entity| {
        entity.* = try storage.createEntity(initial_state);
    }

    // ((0 + 1) * 2) + 1 = 3
    scheduler.dispatchEvent(&storage, .onA, .{});
    scheduler.dispatchEvent(&storage, .onB, .{});
    scheduler.waitIdle();

    // ((3 + 1) * 2) + 1 = 9
    scheduler.dispatchEvent(&storage, .onA, .{});
    scheduler.dispatchEvent(&storage, .onB, .{});
    scheduler.waitIdle();

    // ((9 + 1) * 2) + 1 = 21
    scheduler.dispatchEvent(&storage, .onA, .{});
    scheduler.dispatchEvent(&storage, .onB, .{});
    scheduler.waitIdle();

    // ((21 + 1) * 2) + 1 = 45
    scheduler.dispatchEvent(&storage, .onA, .{});
    scheduler.dispatchEvent(&storage, .onB, .{});
    scheduler.waitIdle();

    const expected_value = 45;
    for (entities) |entity| {
        const ab = try storage.getComponents(entity, Testing.Structure.AB);
        try testing.expectEqual(
            Testing.Component.A{ .value = expected_value },
            ab.a,
        );
        try testing.expectEqual(
            Testing.Component.B{ .value = expected_value },
            ab.b,
        );
    }
}

test "dumpDependencyChain" {
    const SystemStruct = struct {
        pub fn incrA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn incrB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value += 1;
            }
        }

        pub fn doubleA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value *= 2;
            }
        }

        pub fn doubleB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value *= 2;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Scheduler = CreateScheduler(.{
        Event("onA", .{
            SystemStruct.incrA,
            SystemStruct.doubleA,
            SystemStruct.incrA,
        }),
        Event("onB", .{
            SystemStruct.incrB,
            SystemStruct.incrA,
            SystemStruct.doubleB,
            SystemStruct.incrB,
        }),
    });

    {
        const expectedDumpOnA = [_]gen_dependency_chain.Dependency{
            .{ .wait_on_indices = &[_]u32{} },
            .{ .wait_on_indices = &[_]u32{0} },
            .{ .wait_on_indices = &[_]u32{1} },
        };
        const actualDumpOnA = comptime Scheduler.dumpDependencyChain(.onA);
        for (&expectedDumpOnA, actualDumpOnA) |expected, actual| {
            try std.testing.expectEqualSlices(
                u32,
                expected.wait_on_indices,
                actual.wait_on_indices,
            );
        }
    }
    {
        const expectedDumpOnB = [_]gen_dependency_chain.Dependency{
            .{ .wait_on_indices = &[_]u32{} },
            .{ .wait_on_indices = &[_]u32{} },
            .{ .wait_on_indices = &[_]u32{0} },
            .{ .wait_on_indices = &[_]u32{2} },
        };
        const actualDumpOnB = comptime Scheduler.dumpDependencyChain(.onB);
        for (&expectedDumpOnB, actualDumpOnB) |expected, actual| {
            try std.testing.expectEqualSlices(
                u32,
                expected.wait_on_indices,
                actual.wait_on_indices,
            );
        }
    }
}

test "systems can accepts event related data" {
    const AddValue = struct {
        v: u32,
    };

    // define a system type
    const System = struct {
        pub fn addToA(q: *Queries.WriteA, add_value: AddValue) void {
            while (q.next()) |item| {
                item.a.value += add_value.v;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{
        Event("onFoo", .{System.addToA}),
    }).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const entity = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

    const value = 42;
    scheduler.dispatchEvent(&storage, .onFoo, AddValue{ .v = value });
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = value },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "systems can mutate event argument" {
    const AddValue = struct {
        v: u32,
    };

    // define a system type
    const System = struct {
        pub fn addToA(q: *Queries.ReadA, add_value: *AddValue) void {
            while (q.next()) |item| {
                add_value.v += item.a.value;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{
        Event("onFoo", .{System.addToA}),
    }).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const value = 42;
    _ = try storage.createEntity(.{Testing.Component.A{ .value = value }});

    var event_argument = AddValue{ .v = 0 };
    scheduler.dispatchEvent(&storage, .onFoo, &event_argument);
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        value,
        event_argument.v,
    );
}

test "system can contain two queries" {
    const pass_value = 99;
    const fail_value = 100;

    const SystemStruct = struct {
        pub fn eventSystem(query_mut: *Queries.WriteA, query_const: *Queries.ReadA) void {
            const mut_item = query_mut.next().?;
            const const_item = query_const.next().?;
            if (mut_item.a.value == const_item.a.value) {
                mut_item.a.value = pass_value;
            } else {
                mut_item.a.value = fail_value;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event("onFoo", .{
        SystemStruct.eventSystem,
    })}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const entity = try storage.createEntity(.{Testing.Component.A{ .value = fail_value }});

    scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = pass_value },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

// NOTE: we don't use a cache anymore, but the test can stay for now since it might be good for
//       detecting potential regressions
test "event caching works" {
    const Systems = struct {
        pub fn incA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value += 1;
            }
        }

        pub fn incB(q: *Queries.WriteB) void {
            while (q.next()) |item| {
                item.b.value += 1;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{
        Event("onIncA", .{Systems.incA}),
        Event("onIncB", .{Systems.incB}),
    }).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const entity1 = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

    scheduler.dispatchEvent(&storage, .onIncA, .{});
    scheduler.waitEvent(.onIncA);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(entity1, Testing.Component.A),
    );

    // move entity to archetype A, B
    try storage.setComponents(entity1, .{Testing.Component.B{ .value = 0 }});

    scheduler.dispatchEvent(&storage, .onIncA, .{});
    scheduler.waitEvent(.onIncA);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try storage.getComponent(entity1, Testing.Component.A),
    );

    scheduler.dispatchEvent(&storage, .onIncB, .{});
    scheduler.waitEvent(.onIncB);

    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try storage.getComponent(entity1, Testing.Component.B),
    );

    const entity2 = blk: {
        const initial_state = AbcEntityType{
            .a = .{ .value = 0 },
            .b = .{ .value = 0 },
            .c = .{},
        };
        break :blk try storage.createEntity(initial_state);
    };

    scheduler.dispatchEvent(&storage, .onIncA, .{});
    scheduler.waitEvent(.onIncA);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(entity2, Testing.Component.A),
    );

    scheduler.dispatchEvent(&storage, .onIncB, .{});
    scheduler.waitEvent(.onIncB);

    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try storage.getComponent(entity2, Testing.Component.B),
    );
}

test "Event with no archetypes does not crash" {
    const Systems = struct {
        pub fn incA(q: *Queries.WriteA) void {
            while (q.next()) |item| {
                item.a.value += 1;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event("onFoo", .{
        Systems.incA,
    })}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    for (0..100) |_| {
        scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Scheduler does not include new components to systems previously triggered" {
    const Tracker = struct {
        count: u32,
    };

    const Systems = struct {
        pub fn addToTracker(q: *Queries.WriteA, tracker: *Tracker) void {
            while (q.next()) |item| {
                tracker.count += item.a.value;
            }
        }
    };

    const RepStorage = CreateStorage(Testing.AllComponentsTuple);
    const Scheduler = CreateScheduler(.{Event("onFoo", .{Systems.addToTracker})});

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    const inital_state = .{Testing.Component.A{ .value = 1 }};
    _ = try storage.createEntity(inital_state);
    _ = try storage.createEntity(inital_state);

    var tracker = Tracker{ .count = 0 };

    scheduler.dispatchEvent(&storage, .onFoo, &tracker);
    scheduler.waitEvent(.onFoo);

    _ = try storage.createEntity(inital_state);
    _ = try storage.createEntity(inital_state);

    scheduler.dispatchEvent(&storage, .onFoo, &tracker);
    scheduler.waitEvent(.onFoo);

    // at this point we expect tracker to have a count of:
    // t1: 1 + 1 = 2
    // t2: t1 + 1 + 1 + 1 + 1
    // = 6
    try testing.expectEqual(@as(u32, 6), tracker.count);
}
