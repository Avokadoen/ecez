const std = @import("std");
const ResetEvent = std.Thread.ResetEvent;
const testing = std.testing;
const builtin = @import("builtin");

const Color = @import("misc.zig").Color;
const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;
const gen_dependency_chain = @import("dependency_chain.zig");
const query = @import("query.zig");
const QueryType = query.QueryType;
const QueryAnyType = query.QueryAnyType;
const StorageType = @import("storage.zig").StorageType;
const SubsetType = @import("storage.zig").SubsetType;
const Testing = @import("Testing.zig");
const AbEntityType = Testing.Structure.AB;
const AcEntityType = Testing.Structure.AC;
const BcEntityType = Testing.Structure.BC;
const AbcEntityType = Testing.Structure.ABC;
const Queries = Testing.Queries;
const thread_pool_impl = @import("thread_pool.zig");
const ztracy = @import("ecez_ztracy.zig");

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

    const system_counts = init_system_count_array_blk: {
        var _system_counts: [event_count]u32 = undefined;
        for (&_system_counts, events) |*system_count, event| {
            system_count.* = CompileReflect.countAndVerifySystems(event);
        }

        break :init_system_count_array_blk _system_counts;
    };

    // Store each individual thread_pool_impl.Runnable
    const ThreadpoolRunnables = comptime blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (&fields, system_counts, 0..) |*field, system_count, i| {
            const default_value = [_]*thread_pool_impl.RunQueue.Node{undefined} ** system_count;
            const name = CompileReflect.getRunnablesFieldName(i);

            field.* = Type.StructField{
                .name = name[0.. :0],
                .type = [system_count]*thread_pool_impl.RunQueue.Node,
                .default_value_ptr = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf([system_count]*thread_pool_impl.RunQueue.Node),
            };
        }

        break :blk @Type(Type{ .@"struct" = Type.Struct{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = false,
        } });
    };

    // Calculate dependencies
    const Dependencies = CompileReflect.DependencyListsType(events, event_count){};

    return struct {
        pub const ThreadPool = thread_pool_impl.Create();

        const Scheduler = @This();

        pub const EventsEnum = CompileReflect.GenerateEventEnum(events);

        query_submit_allocator: std.mem.Allocator,
        thread_pool: *ThreadPool,

        system_run_state: ThreadpoolRunnables,
        event_systems_running: [event_count]std.atomic.Value(u32),

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

            return Scheduler{
                .query_submit_allocator = config.query_submit_allocator,
                .thread_pool = thread_pool,
                .system_run_state = ThreadpoolRunnables{},
                .event_systems_running = [_]std.atomic.Value(u32){.{ .raw = 0 }} ** event_count,
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
        /// try scheduler.dispatchEvent(&storage, .onMouse, @as(MouseArg, mouse));
        /// ```
        pub fn dispatchEvent(self: *Scheduler, storage: anytype, comptime event: EventsEnum, event_argument: anytype) error{OutOfMemory}!void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("dispatchEvent {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const Storage = get_storage_type_blk: {
                const StoragePtr = @TypeOf(storage);
                const storage_ptr = @typeInfo(StoragePtr);
                if (storage_ptr != .pointer) {
                    @compileError(@src().fn_name ++ " expected argument storage to be pointer to a ecez.Storage, got " ++ @typeName(StoragePtr));
                }

                const child_type = storage_ptr.pointer.child;
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
            const event_system_run_state, const triggered_event = extract_event_blk: {
                const event_field_name = comptime CompileReflect.getRunnablesFieldName(event_index);

                break :extract_event_blk .{
                    &@field(self.system_run_state, event_field_name),
                    events[event_index],
                };
            };

            const run_on_main_thread = builtin.single_threaded or self.thread_pool.threads.len == 0 or triggered_event._run_on_main_thread;
            if (run_on_main_thread == false) {
                self.event_systems_running[event_index].store(
                    system_counts[event_index],
                    .monotonic,
                );
            }

            const event_dependencies = @field(Dependencies, triggered_event._name);
            // Ensure each runnable is ready to be signaled by previous jobs
            inline for (
                event_system_run_state,
                triggered_event._systems,
                0..,
            ) |
                *runnable_node,
                system,
                entry_index,
            | {
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

                const dispatch_exec_func = DispatchJob.exec;
                if (run_on_main_thread) {
                    @call(.auto, dispatch_exec_func, .{system_job});
                } else {
                    @branchHint(.likely);
                    const closure = try self.thread_pool.allocClosure(
                        entry_index,
                        &event_dependencies,
                        event_system_run_state,
                        &self.event_systems_running[event_index],
                        system_job,
                    );

                    runnable_node.* = &closure.run_node;
                }
            }

            if (run_on_main_thread == false) {
                @branchHint(.likely);
                for (event_system_run_state, event_dependencies) |runnable_node, dependency| {
                    self.thread_pool.spawn(
                        dependency,
                        runnable_node,
                    );
                }
            }
        }

        /// Wait for all jobs from a dispatchEvent to finish by blocking the calling thread
        /// should only be called from the dispatchEvent thread
        pub fn waitEvent(self: *Scheduler, comptime event: EventsEnum) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("{s}: event {s}", .{ @src().fn_name, @tagName(event) });
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            // Spinlock :/
            const event_index = @intFromEnum(event);
            while (self.event_systems_running[event_index].load(.monotonic) > 0) {}
        }

        /// Check if an event is currently being executed
        /// should only be called from the dispatchEvent thread
        pub fn isEventInFlight(self: *Scheduler, comptime event: EventsEnum) bool {
            const tracy_zone_name = comptime std.fmt.comptimePrint("{s}: event {s}", .{ @src().fn_name, @tagName(event) });
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const event_index = @intFromEnum(event);
            return self.event_systems_running[event_index].load(.monotonic) > 0;
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
                    const FuncType = @TypeOf(func);
                    const param_types = comptime get_param_types_blk: {
                        const func_info = @typeInfo(FuncType);
                        var types: [func_info.@"fn".params.len]type = undefined;
                        for (&types, func_info.@"fn".params) |*Type, param| {
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
                            if (param_info != .pointer) {
                                @compileError("System Query and Subset arguments must be pointer type");
                            }

                            break :get_arg_blk switch (param_info.pointer.child.EcezType) {
                                // TODO: scheduler should have an allocator for this
                                QueryType => param_info.pointer.child.submit(self_job.query_submit_allocator, self_job.storage) catch @panic("Scheduler dispatch query_submit_allocator OOM"),
                                QueryAnyType => param_info.pointer.child.prepare(self_job.storage),
                                SubsetType => param_info.pointer.child{ .storage = self_job.storage },
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
                    const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .auto;
                    @call(system_call_modidifer, func, arguments);

                    inline for (param_types, &arguments) |Param, *arg| {
                        if (Param == EventArgument) {
                            continue;
                        }

                        const param_info = @typeInfo(Param);

                        switch (param_info.pointer.child.EcezType) {
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

pub const EventConfig = struct {
    run_on_main_thread: bool = false,
};

pub fn Event(comptime name: []const u8, comptime systems: anytype, comptime config: EventConfig) type {
    const systems_fields: std.builtin.Type = @typeInfo(@TypeOf(systems));
    if (systems_fields != .@"struct") {
        @compileError("Event expect systems to be a tuple of systems");
    }

    for (systems_fields.@"struct".fields, 0..) |system_field, system_index| {
        const system_field_info = @typeInfo(system_field.type);
        if (system_field_info != .@"fn") {
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
        pub const _run_on_main_thread = config.run_on_main_thread;

        // TODO: validate given a storage
        pub fn getSystemCount() u32 {
            comptime var system_count = 0;
            const systems_info = @typeInfo(@TypeOf(ThisEvent._systems));
            system_loop: inline for (systems_info.@"struct".fields) |field_system| {
                const system_info = @typeInfo(field_system.type);
                if (system_info != .@"fn") {
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
    pub inline fn getRunnablesFieldName(comptime index: u32) []const u8 {
        var num_buf: [8:0]u8 = undefined;
        const name = std.fmt.bufPrint(&num_buf, "{d}", .{index}) catch unreachable;
        num_buf[name.len] = 0;

        return name;
    }

    pub fn countAndVerifyEvents(comptime events: anytype) u32 {
        const events_info = events_info_blk: {
            const info: std.builtin.Type = @typeInfo(@TypeOf(events));
            if (info != .@"struct") {
                @compileError("expected events to be a struct of Event");
            }
            break :events_info_blk info.@"struct";
        };

        inline for (events_info.fields, 0..) |events_fields, event_index| {
            if (events_fields.default_value_ptr == null) {
                @compileError(std.fmt.comptimePrint("event number {d} is not an event. Events must be created with ecez.Event()", .{event_index}));
            }

            const this_event = @as(*const events_fields.type, @ptrCast(events_fields.default_value_ptr.?)).*;
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
        const event1 = Event("a", .{countAndVerifyEvents}, .{});
        const event2 = Event("b", .{std.debug.assert}, .{});
        const event3 = Event("c", .{std.debug.assert}, .{});
        const event_count = countAndVerifyEvents(.{ event1, event2, event3 });
        try std.testing.expectEqual(3, event_count);
    }

    pub fn countAndVerifySystems(comptime event: anytype) u32 {
        {
            const info: std.builtin.Type = @typeInfo(event);
            if (info != .@"struct") {
                @compileError("expected events to be a struct of Event");
            }
        }

        comptime var system_count = 0;
        const systems_info = @typeInfo(@TypeOf(event._systems));
        system_loop: inline for (systems_info.@"struct".fields) |field_system| {
            const system_info = @typeInfo(field_system.type);
            if (system_info != .@"fn") {
                continue :system_loop;
            }

            // Ensure arguments are queries
            const params = system_info.@"fn".params;
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
        const event1 = Event("a", .{std.debug.assert}, .{});
        const event2 = Event("b", .{ std.debug.assert, std.debug.assert }, .{});
        const event3 = Event("c", .{ std.debug.assert, std.debug.assert, std.debug.assert }, .{});

        try std.testing.expectEqual(1, comptime countAndVerifySystems(event1));
        try std.testing.expectEqual(2, comptime countAndVerifySystems(event2));
        try std.testing.expectEqual(3, comptime countAndVerifySystems(event3));
    }

    pub fn GenerateEventEnum(comptime events: anytype) type {
        const events_info = @typeInfo(@TypeOf(events)).@"struct";

        var enum_fields: [events_info.fields.len]std.builtin.Type.EnumField = undefined;
        inline for (&enum_fields, events_info.fields, 0..) |*enum_field, events_fields, enum_value| {
            const this_event = @as(*const events_fields.type, @ptrCast(events_fields.default_value_ptr.?)).*;
            enum_field.name = this_event._name[0.. :0];
            enum_field.value = enum_value;
        }

        const enum_info = std.builtin.Type{ .@"enum" = .{
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
                .default_value_ptr = @ptrCast(&value),
                .is_comptime = true,
                .alignment = @alignOf(DependecyArrayType),
            };
        }

        return @Type(std.builtin.Type{ .@"struct" = .{
            .layout = .auto,
            .fields = &dependency_lists_type_fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } });
    }
};

const StorageStub = CreateStorage(Testing.AllComponentsTuple);

test "system query can mutate components" {
    const QueryTypes = Testing.QueryAndQueryAny(
        struct {
            a: *Testing.Component.A,
            b: Testing.Component.B,
        },
        .{},
        .{},
    );

    inline for (QueryTypes) |Query| {
        const SystemStruct = struct {
            pub fn mutateStuff(ab: *Query) void {
                while (ab.next()) |ent_ab| {
                    ent_ab.a.value += ent_ab.b.value;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        const OnFooEvent = Event(
            "onFoo",
            .{SystemStruct.mutateStuff},
            .{},
        );

        var scheduler = try CreateScheduler(.{OnFooEvent}).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        try scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 1 },
            .b = Testing.Component.B{ .value = 2 },
        };
        const entity = try storage.createEntity(initial_state);

        try scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        try testing.expectEqual(
            Testing.Component.A{ .value = 3 },
            storage.getComponent(entity, Testing.Component.A).?,
        );
    }
}

test "scheduler can be used for multiple storage types" {
    const QueryTypes = Testing.QueryAndQueryAny(
        struct {
            a: *Testing.Component.A,
            b: Testing.Component.B,
        },
        .{},
        .{},
    );

    const StorageAC = CreateStorage(.{ Testing.Component.A, Testing.Component.B });
    inline for (QueryTypes) |Query| {
        const SystemStruct = struct {
            pub fn mutateStuff(ab: *Query) void {
                while (ab.next()) |ent_ab| {
                    ent_ab.a.value += ent_ab.b.value;
                }
            }
        };

        const OnFooEvent = Event(
            "onFoo",
            .{SystemStruct.mutateStuff},
            .{},
        );
        var scheduler = try CreateScheduler(.{OnFooEvent}).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        inline for (0..2) |storage_type_index| {
            const Storage = if (storage_type_index == 0) StorageStub else StorageAC;

            var storage = try Storage.init(testing.allocator);
            defer storage.deinit();

            const initial_state = AbEntityType{
                .a = Testing.Component.A{ .value = 1 },
                .b = Testing.Component.B{ .value = 2 },
            };
            const entity = try storage.createEntity(initial_state);

            try scheduler.dispatchEvent(&storage, .onFoo, .{});
            scheduler.waitEvent(.onFoo);

            try testing.expectEqual(
                Testing.Component.A{ .value = 3 },
                storage.getComponent(entity, Testing.Component.A).?,
            );
        }
    }
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
    inline for (Queries.WriteA, Queries.ReadA, Queries.WriteB, Queries.ReadB) |WriteA, ReadA, WriteB, ReadB| {
        const SystemStruct = struct {
            pub fn incrB(b_query: *WriteB) void {
                while (b_query.next()) |item| {
                    item.b.value += 1;
                }
            }

            pub fn decrB(b_query: *WriteB) void {
                while (b_query.next()) |item| {
                    item.b.value -= 1;
                }
            }

            pub fn incrA(a_query: *WriteA) void {
                while (a_query.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn decrA(a_query: *WriteA) void {
                while (a_query.next()) |item| {
                    item.a.value -= 1;
                }
            }

            pub fn spawnEntityAFromB(b_query: *ReadB, a_sub: *SubsetA, spawned_entities: *SpawnedEntities) void {
                for (&spawned_entities.a) |*entity| {
                    const item = b_query.next().?;

                    entity.* = a_sub.createEntity(.{
                        Testing.Component.A{ .value = item.b.value },
                    }) catch @panic("OOM");
                }
            }

            pub fn spawnEntityBFromA(a_query: *ReadA, b_sub: *SubsetB, spawned_entities: *SpawnedEntities) void {
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
            .{},
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
            try scheduler.dispatchEvent(&storage, .onFoo, &spawned_entites);
            scheduler.waitEvent(.onFoo);

            for (&initial_entites, 0..) |entity, iter| {
                try testing.expectEqual(
                    Testing.Component.B{ .value = @intCast(iter) },
                    storage.getComponent(entity, Testing.Component.B).?,
                );
            }

            for (spawned_entites.a, 0..) |entity, iter| {
                try testing.expectEqual(
                    Testing.Component.A{ .value = @intCast(iter) },
                    storage.getComponent(entity, Testing.Component.A).?,
                );
            }

            for (spawned_entites.b, 0..) |entity, iter| {
                // Make sure these entities is not the ones we spawned in this for loop
                try std.testing.expect(entity.id != iter);

                const reverse = initial_entity_count - iter - 1;
                try testing.expectEqual(
                    Testing.Component.B{ .value = @intCast(reverse) },
                    storage.getComponent(entity, Testing.Component.B).?,
                );
            }
        }
    }
}

test "Thread count 0 works" {
    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const SystemStruct = struct {
            pub fn incrB(b_query: *WriteB) void {
                while (b_query.next()) |item| {
                    item.b.value += 1;
                }
            }

            pub fn decrB(b_query: *WriteB) void {
                while (b_query.next()) |item| {
                    item.b.value -= 1;
                }
            }

            pub fn incrA(a_query: *WriteA) void {
                while (a_query.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn decrA(a_query: *WriteA) void {
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
                SystemStruct.incrB,
            },
            .{},
        )}).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
            .thread_count = 0,
        });
        defer scheduler.deinit();

        var entities: [128]Entity = undefined;
        for (&entities, 0..) |*entity, iter| {
            entity.* = try storage.createEntity(.{
                Testing.Component.B{ .value = @intCast(iter) },
            });
        }

        try scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        for (entities, 0..) |entity, iter| {
            const b = storage.getComponent(entity, Testing.Component.B).?;
            try std.testing.expectEqual(Testing.Component.B{ .value = @intCast(iter + 1) }, b);
        }
    }
}

test "system sub storage can mutate components" {
    const SubStorage = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });

    const SystemStruct = struct {
        pub fn mutateStuff(entities: *Queries.Entities, ab: *SubStorage) void {
            while (entities.next()) |item| {
                const a = ab.getComponent(item.entity, Testing.Component.A).?;

                ab.setComponents(item.entity, .{
                    Testing.Component.B{ .value = @intCast(a.value) },
                }) catch @panic("oof");
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{Event(
        "onFoo",
        .{SystemStruct.mutateStuff},
        .{},
    )}).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    try scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    try scheduler.dispatchEvent(&storage, .onFoo, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.B{ .value = 42 },
        storage.getComponent(entity, Testing.Component.B).?,
    );
}

test "Dispatch is determenistic (no race conditions)" {
    const AbSubStorage = StorageStub.Subset(.{
        *Testing.Component.A,
        *Testing.Component.B,
    });

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const SystemStruct = struct {
            pub fn incrA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn incrB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value += 1;
                }
            }

            pub fn doubleA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value *= 2;
                }
            }

            pub fn doubleB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value *= 2;
                }
            }

            pub fn storageIncrAIncrB(entities: *Queries.Entities, sub: *AbSubStorage) void {
                while (entities.next()) |item| {
                    const ab = sub.getComponents(item.entity, struct {
                        a: *Testing.Component.A,
                        b: *Testing.Component.B,
                    }).?;

                    ab.a.value += 1;
                    ab.b.value += 1;
                }
            }

            pub fn storageDoubleADoubleB(entities: *Queries.Entities, sub: *AbSubStorage) void {
                while (entities.next()) |item| {
                    const ab = sub.getComponents(item.entity, struct {
                        a: *Testing.Component.A,
                        b: *Testing.Component.B,
                    }).?;

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

        // Run the test many times, expect the same result
        for (0..128) |_| {
            defer storage.clearRetainingCapacity();

            var scheduler = try CreateScheduler(.{
                Event(
                    "onFoo",
                    .{
                        SystemStruct.storageZeroAZeroB,
                        SystemStruct.incrA,
                        SystemStruct.doubleA,
                        SystemStruct.incrA,
                        SystemStruct.incrB,
                        SystemStruct.doubleB,
                        SystemStruct.incrB,
                        SystemStruct.storageDoubleADoubleB,
                        SystemStruct.storageIncrAIncrB,
                    },
                    .{},
                ),
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

            try scheduler.dispatchEvent(&storage, .onFoo, .{});
            scheduler.waitEvent(.onFoo);

            for (entities) |entity| {
                const ab = storage.getComponents(entity, Testing.Structure.AB).?;
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
            try scheduler.dispatchEvent(&storage, .onFoo, .{});
            scheduler.waitEvent(.onFoo);

            for (entities) |entity| {
                const ab = storage.getComponents(entity, Testing.Structure.AB).?;
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
}

test "Dispatch with multiple events works" {
    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const SystemStruct = struct {
            pub fn incrA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn incrB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value += 1;
                }
            }

            pub fn doubleA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value *= 2;
                }
            }

            pub fn doubleB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value *= 2;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{
            Event(
                "onA",
                .{
                    SystemStruct.incrA,
                    SystemStruct.doubleA,
                    SystemStruct.incrA,
                },
                .{},
            ),
            Event(
                "onB",
                .{
                    SystemStruct.incrB,
                    SystemStruct.doubleB,
                    SystemStruct.incrB,
                },
                .{},
            ),
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
        try scheduler.dispatchEvent(&storage, .onA, .{});
        try scheduler.dispatchEvent(&storage, .onB, .{});
        scheduler.waitIdle();

        // ((3 + 1) * 2) + 1 = 9
        try scheduler.dispatchEvent(&storage, .onA, .{});
        try scheduler.dispatchEvent(&storage, .onB, .{});
        scheduler.waitIdle();

        // ((9 + 1) * 2) + 1 = 21
        try scheduler.dispatchEvent(&storage, .onA, .{});
        try scheduler.dispatchEvent(&storage, .onB, .{});
        scheduler.waitIdle();

        // ((21 + 1) * 2) + 1 = 45
        try scheduler.dispatchEvent(&storage, .onA, .{});
        try scheduler.dispatchEvent(&storage, .onB, .{});
        scheduler.waitIdle();

        const expected_value = 45;
        for (entities) |entity| {
            const ab = storage.getComponents(entity, Testing.Structure.AB).?;
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

test "Dispatch with destroyEntity is determenistic" {
    const ASubset = StorageStub.Subset(.{*Testing.Component.A});
    const AllSubset = StorageStub.Subset(StorageStub.AllComponentWriteAccess);
    inline for (Queries.WriteA, Queries.ReadC, Queries.ReadB) |WriteA, ReadC, ReadB| {
        const SystemStruct = struct {
            pub fn incrA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn destroyEntityWithC(q: *ReadC, all_storage: *AllSubset) void {
                while (q.next()) |item| {
                    all_storage.destroyEntity(item.entity) catch unreachable;
                }
            }

            pub fn createEntityA(a_storage: *ASubset) void {
                for (0..100) |_| {
                    _ = a_storage.createEntity(.{Testing.Component.A{ .value = 0 }}) catch unreachable;
                }
            }

            // incrA

            pub fn destroyEntityWithB(q: *ReadB, all_storage: *AllSubset) void {
                while (q.next()) |item| {
                    all_storage.destroyEntity(item.entity) catch unreachable;
                }
            }

            // incrA
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{
            Event(
                "incrDestroy",
                .{
                    SystemStruct.incrA,
                    SystemStruct.destroyEntityWithC,
                    SystemStruct.createEntityA,
                    SystemStruct.incrA,
                    SystemStruct.destroyEntityWithB,
                    SystemStruct.createEntityA,
                    SystemStruct.incrA,
                },
                .{},
            ),
        }).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        var entity_a0: [100]Entity = undefined;
        for (&entity_a0, 0..) |*entity, index| {
            entity.* = try storage.createEntity(.{Testing.Component.A{
                .value = @intCast(index),
            }});
        }

        var entity_ac: [100]Entity = undefined;
        for (&entity_ac, 0..) |*entity, index| {
            entity.* = try storage.createEntity(Testing.Structure.AC{
                .a = .{ .value = @intCast(index) },
                .c = .{},
            });
        }

        var entity_ab: [100]Entity = undefined;
        for (&entity_ab, 0..) |*entity, index| {
            entity.* = try storage.createEntity(Testing.Structure.AB{
                .a = .{ .value = @intCast(index) },
                .b = .{ .value = @intCast(index) },
            });
        }

        var entity_a1: [100]Entity = undefined;
        for (&entity_a1, 0..) |*entity, index| {
            entity.* = try storage.createEntity(.{Testing.Component.A{
                .value = @intCast(index),
            }});
        }

        try scheduler.dispatchEvent(&storage, .incrDestroy, .{});
        scheduler.waitIdle();

        for (&entity_a0, 0..) |entity, index| {
            const a = storage.getComponent(entity, Testing.Component.A).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(index + 3) },
                a,
            );
        }
        for (&entity_ac) |entity| {
            const a = storage.getComponent(entity, Testing.Component.A).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = 2 },
                a,
            );
            try testing.expect(!storage.hasComponents(entity, .{Testing.Component.B}));
            try testing.expect(!storage.hasComponents(entity, .{Testing.Component.C}));
        }
        for (&entity_ab) |entity| {
            const a = storage.getComponent(entity, Testing.Component.A).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = 1 },
                a,
            );
            try testing.expect(!storage.hasComponents(entity, .{Testing.Component.B}));
            try testing.expect(!storage.hasComponents(entity, .{Testing.Component.C}));
        }
        for (&entity_a1, 0..) |entity, index| {
            const a = storage.getComponent(entity, Testing.Component.A).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(index + 3) },
                a,
            );
        }
    }
}

test "dumpDependencyChain" {
    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const SystemStruct = struct {
            pub fn incrA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn incrB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value += 1;
                }
            }

            pub fn doubleA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value *= 2;
                }
            }

            pub fn doubleB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value *= 2;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        const Scheduler = CreateScheduler(.{
            Event(
                "onA",
                .{
                    SystemStruct.incrA,
                    SystemStruct.doubleA,
                    SystemStruct.incrA,
                },
                .{},
            ),
            Event(
                "onB",
                .{
                    SystemStruct.incrB,
                    SystemStruct.incrA,
                    SystemStruct.doubleB,
                    SystemStruct.incrB,
                },
                .{},
            ),
        });

        {
            const expectedDumpOnA = [_]gen_dependency_chain.Dependency{
                .{ .prereq_count = 0, .signal_indices = &[_]u32{1} },
                .{ .prereq_count = 1, .signal_indices = &[_]u32{2} },
                .{ .prereq_count = 1, .signal_indices = &[_]u32{} },
            };
            const actualDumpOnA = comptime Scheduler.dumpDependencyChain(.onA);
            for (&expectedDumpOnA, actualDumpOnA) |expected, actual| {
                try std.testing.expectEqual(
                    expected.prereq_count,
                    actual.prereq_count,
                );

                try std.testing.expectEqualSlices(
                    u32,
                    expected.signal_indices,
                    actual.signal_indices,
                );
            }
        }
        {
            const expectedDumpOnB = [_]gen_dependency_chain.Dependency{
                .{ .prereq_count = 0, .signal_indices = &[_]u32{2} },
                .{ .prereq_count = 0, .signal_indices = &[_]u32{} },
                .{ .prereq_count = 1, .signal_indices = &[_]u32{3} },
                .{ .prereq_count = 1, .signal_indices = &[_]u32{} },
            };
            const actualDumpOnB = comptime Scheduler.dumpDependencyChain(.onB);
            for (&expectedDumpOnB, actualDumpOnB) |expected, actual| {
                try std.testing.expectEqual(
                    expected.prereq_count,
                    actual.prereq_count,
                );

                try std.testing.expectEqualSlices(
                    u32,
                    expected.signal_indices,
                    actual.signal_indices,
                );
            }
        }
    }
}

test "systems can accepts event related data" {
    const AddValue = struct {
        v: u32,
    };

    inline for (Queries.WriteA) |WriteA| {
        // define a system type
        const System = struct {
            pub fn addToA(q: *WriteA, add_value: AddValue) void {
                while (q.next()) |item| {
                    item.a.value += add_value.v;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{
            Event(
                "onFoo",
                .{System.addToA},
                .{},
            ),
        }).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

        const value = 42;
        try scheduler.dispatchEvent(&storage, .onFoo, AddValue{ .v = value });
        scheduler.waitEvent(.onFoo);

        try testing.expectEqual(
            Testing.Component.A{ .value = value },
            storage.getComponent(entity, Testing.Component.A).?,
        );
    }
}

test "systems can mutate event argument" {
    const AddValue = struct {
        v: u32,
    };

    inline for (Queries.ReadA) |ReadA| {
        // define a system type
        const System = struct {
            pub fn addToA(q: *ReadA, add_value: *AddValue) void {
                while (q.next()) |item| {
                    add_value.v += item.a.value;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{
            Event(
                "onFoo",
                .{System.addToA},
                .{},
            ),
        }).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const value = 42;
        _ = try storage.createEntity(.{Testing.Component.A{ .value = value }});

        var event_argument = AddValue{ .v = 0 };
        try scheduler.dispatchEvent(&storage, .onFoo, &event_argument);
        scheduler.waitEvent(.onFoo);

        try testing.expectEqual(
            value,
            event_argument.v,
        );
    }
}

test "system can contain two queries" {
    const pass_value = 99;
    const fail_value = 100;

    inline for (Queries.WriteA, Queries.ReadA) |WriteA, ReadA| {
        const SystemStruct = struct {
            pub fn eventSystem(query_mut: *WriteA, query_const: *ReadA) void {
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

        var scheduler = try CreateScheduler(.{Event(
            "onFoo",
            .{
                SystemStruct.eventSystem,
            },
            .{},
        )}).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity = try storage.createEntity(.{Testing.Component.A{ .value = fail_value }});

        try scheduler.dispatchEvent(&storage, .onFoo, .{});
        scheduler.waitEvent(.onFoo);

        try testing.expectEqual(
            Testing.Component.A{ .value = pass_value },
            storage.getComponent(entity, Testing.Component.A).?,
        );
    }
}

// NOTE: we don't use a cache anymore, but the test can stay for now since it might be good for
//       detecting potential regressions
test "event caching works" {
    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const Systems = struct {
            pub fn incA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn incB(q: *WriteB) void {
                while (q.next()) |item| {
                    item.b.value += 1;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{
            Event("onIncA", .{Systems.incA}, .{}),
            Event("onIncB", .{Systems.incB}, .{}),
        }).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity1 = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

        try scheduler.dispatchEvent(&storage, .onIncA, .{});
        scheduler.waitEvent(.onIncA);

        try testing.expectEqual(
            Testing.Component.A{ .value = 1 },
            storage.getComponent(entity1, Testing.Component.A).?,
        );

        // move entity to archetype A, B
        try storage.setComponents(entity1, .{Testing.Component.B{ .value = 0 }});

        try scheduler.dispatchEvent(&storage, .onIncA, .{});
        scheduler.waitEvent(.onIncA);

        try testing.expectEqual(
            Testing.Component.A{ .value = 2 },
            storage.getComponent(entity1, Testing.Component.A).?,
        );

        try scheduler.dispatchEvent(&storage, .onIncB, .{});
        scheduler.waitEvent(.onIncB);

        try testing.expectEqual(
            Testing.Component.B{ .value = 1 },
            storage.getComponent(entity1, Testing.Component.B).?,
        );

        const entity2 = blk: {
            const initial_state = AbcEntityType{
                .a = .{ .value = 0 },
                .b = .{ .value = 0 },
                .c = .{},
            };
            break :blk try storage.createEntity(initial_state);
        };

        try scheduler.dispatchEvent(&storage, .onIncA, .{});
        scheduler.waitEvent(.onIncA);

        try testing.expectEqual(
            Testing.Component.A{ .value = 1 },
            storage.getComponent(entity2, Testing.Component.A).?,
        );

        try scheduler.dispatchEvent(&storage, .onIncB, .{});
        scheduler.waitEvent(.onIncB);

        try testing.expectEqual(
            Testing.Component.B{ .value = 1 },
            storage.getComponent(entity2, Testing.Component.B).?,
        );
    }
}

test "Event with no archetypes does not crash" {
    inline for (Queries.WriteA) |WriteA| {
        const Systems = struct {
            pub fn incA(q: *WriteA) void {
                while (q.next()) |item| {
                    item.a.value += 1;
                }
            }
        };

        var storage = try StorageStub.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try CreateScheduler(.{Event(
            "onFoo",
            .{
                Systems.incA,
            },
            .{},
        )}).init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        for (0..100) |_| {
            try scheduler.dispatchEvent(&storage, .onFoo, .{});
            scheduler.waitEvent(.onFoo);
        }
    }
}

test "event in flight" {
    const Resets = struct {
        start: [3]std.Thread.ResetEvent = .{std.Thread.ResetEvent{}} ** 3,
        stop: [3]std.Thread.ResetEvent = .{std.Thread.ResetEvent{}} ** 3,
    };

    const Systems = struct {
        pub fn first(resets: *Resets) void {
            resets.start[0].wait();
            resets.stop[0].set();
        }
        pub fn second(resets: *Resets) void {
            resets.start[1].wait();
            resets.stop[1].set();
        }
        pub fn third(resets: *Resets) void {
            resets.start[2].wait();
            resets.stop[2].set();
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(.{
        Event("onFoo", .{
            Systems.first,
            Systems.second,
            Systems.third,
        }, .{}),
    }).init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    var resets = Resets{};

    try scheduler.dispatchEvent(&storage, .onFoo, &resets);

    try std.testing.expect(scheduler.isEventInFlight(.onFoo));
    resets.start[0].set();
    resets.stop[0].wait();

    try std.testing.expect(scheduler.isEventInFlight(.onFoo));
    resets.start[1].set();
    resets.stop[1].wait();

    try std.testing.expect(scheduler.isEventInFlight(.onFoo));
    resets.start[2].set();
    resets.stop[2].wait();

    // Even though we wait on resets.stop[2], this ResetEvent is signaled by the system.
    // We dont have any guarantee that scheduler's internal tracking of onFoo will actually propagate as done
    // before sampling event status with 'isEventInFlight'.
    scheduler.waitEvent(.onFoo);

    try std.testing.expect(!scheduler.isEventInFlight(.onFoo));
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Scheduler does not include new components to systems previously triggered" {
    const Tracker = struct {
        count: u32,
    };

    inline for (Queries.WriteA) |WriteA| {
        const Systems = struct {
            pub fn addToTracker(q: *WriteA, tracker: *Tracker) void {
                while (q.next()) |item| {
                    tracker.count += item.a.value;
                }
            }
        };

        const RepStorage = CreateStorage(Testing.AllComponentsTuple);
        const Scheduler = CreateScheduler(.{Event(
            "onFoo",
            .{Systems.addToTracker},
            .{},
        )});

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

        try scheduler.dispatchEvent(&storage, .onFoo, &tracker);
        scheduler.waitEvent(.onFoo);

        _ = try storage.createEntity(inital_state);
        _ = try storage.createEntity(inital_state);

        try scheduler.dispatchEvent(&storage, .onFoo, &tracker);
        scheduler.waitEvent(.onFoo);

        // at this point we expect tracker to have a count of:
        // t1: 1 + 1 = 2
        // t2: t1 + 1 + 1 + 1 + 1
        // = 6
        try testing.expectEqual(@as(u32, 6), tracker.count);
    }
}

// Reproduces an issue with calling waitForEvent on a dispatch to main thread
test "reproducer: single threaded dispatch with a waitForEvent is idempotent" {
    inline for (Queries.WriteA, Queries.WriteB) |WriteA, WriteB| {
        const Systems = struct {
            pub fn writeA(a_query: *WriteA) void {
                while (a_query.next()) |item| {
                    item.a.value += 1;
                }
            }

            pub fn writeB(a_query: *WriteB) void {
                while (a_query.next()) |item| {
                    item.b.value += 1;
                }
            }
        };

        const RepStorage = CreateStorage(Testing.AllComponentsTuple);
        const Scheduler = CreateScheduler(.{Event(
            "on_foo",
            .{
                Systems.writeA,
                Systems.writeB,
                Systems.writeA,
            },
            .{},
        )});

        var storage = try RepStorage.init(testing.allocator);
        defer storage.deinit();

        var scheduler = try Scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
            .thread_count = 0,
        });
        defer scheduler.deinit();

        const inital_state = .{
            Testing.Component.A{ .value = 0 },
            Testing.Component.B{ .value = 0 },
        };
        const my_entity = try storage.createEntity(inital_state);

        try scheduler.dispatchEvent(&storage, .on_foo, .{});
        scheduler.waitEvent(.on_foo);

        const final_state = storage.getComponents(my_entity, Testing.Structure.AB).?;
        try testing.expectEqual(@as(u32, 2), final_state.a.value);
        try testing.expectEqual(@as(u32, 1), final_state.b.value);
    }
}
