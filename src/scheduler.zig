const std = @import("std");
const ResetEvent = std.Thread.ResetEvent;
const testing = std.testing;
const ThreadPool = std.Thread.Pool;
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
    thread_count: ?usize = null,
};

/// Allow the user to attach systems to a storage. The user can then trigger events on the scheduler to execute
/// the systems in a multithreaded environment
pub fn CreateScheduler(comptime Storage: type, comptime events: anytype) type {
    const event_count = CompileReflect.countAndVerifyEvents(events);

    const system_counts = init_system_count_array_blk: {
        var _system_counts: [event_count]u32 = undefined;
        for (&_system_counts, events) |*system_count, event| {
            system_count.* = CompileReflect.countAndVerifySystems(event);
        }

        break :init_system_count_array_blk _system_counts;
    };

    // We need some memory to store each events error state
    const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));
    const ErrorAtomic = std.atomic.Value(ErrorInt);
    const EventErrorAtomics: type = CompileReflect.EventErrorAtomicStorageType(
        event_count,
        ErrorAtomic,
    );

    // Calculate dependencies
    const Dependencies: type = CompileReflect.DependencyListsType(events, event_count);

    // Store each individual thread_pool_impl.Runnable
    const EventsScheduler: type = CompileReflect.EventSchedulerType(
        event_count,
        events,
        &system_counts,
        Storage,
        ErrorAtomic,
    );

    // We need some memory to store the individual system interfaces
    const SystemSchedulerInterfaceStorage: type = CompileReflect.EventSystemStorageType(
        event_count,
        events,
        &system_counts,
        SystemSchedulerInterface,
    );

    // We need some memory to store the individual system pre-req counts
    const PreReqInflightStorage: type = CompileReflect.EventSystemStorageType(
        event_count,
        events,
        &system_counts,
        std.atomic.Value(u32),
    );

    return struct {
        const Scheduler = @This();

        pub const EventsEnum = CompileReflect.GenerateEventEnum(events);

        pub const uninitialized = Scheduler{
            .query_submit_allocator = undefined,
            .thread_pool = undefined,
            .events_scheduler = undefined,
            .system_scheduler_interface_storage = undefined,
            .pre_req_inflight_storage = undefined,
            .events_systems_running = undefined,
            .events_error_atomics = undefined,
            .dependencies = undefined,
        };

        query_submit_allocator: std.mem.Allocator,
        thread_pool: *ThreadPool,

        events_scheduler: EventsScheduler,
        system_scheduler_interface_storage: SystemSchedulerInterfaceStorage,
        pre_req_inflight_storage: PreReqInflightStorage,
        events_systems_running: [event_count]std.atomic.Value(i32),
        events_error_atomics: EventErrorAtomics,
        dependencies: Dependencies,

        /// Initialized the system scheduler. User must make sure to call deinit
        pub fn init(scheduler: *Scheduler, config: Config) !void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer zone.End();

            const thread_pool = try config.pool_allocator.create(ThreadPool);
            errdefer config.pool_allocator.destroy(thread_pool);

            try ThreadPool.init(thread_pool, .{
                .allocator = config.pool_allocator,
                .n_jobs = config.thread_count,
            });

            scheduler.query_submit_allocator = config.query_submit_allocator;
            scheduler.thread_pool = thread_pool;
            scheduler.dependencies = .{};
            for (&scheduler.events_systems_running) |*systems_running| {
                systems_running.* = .init(0);
            }

            var events_scheduler: *EventsScheduler = &scheduler.events_scheduler;
            var system_scheduler_interface_storage = &scheduler.system_scheduler_interface_storage;
            var pre_req_inflight_storage = &scheduler.pre_req_inflight_storage;
            inline for (@typeInfo(EventsScheduler).@"struct".fields, 0..) |event_field, event_index| {
                var prereq_jobs_inflights = &@field(pre_req_inflight_storage, event_field.name);
                var event_scheduler = &@field(events_scheduler, event_field.name);
                const system_scheduler_interfaces = &@field(system_scheduler_interface_storage, event_field.name);
                inline for (@typeInfo(event_field.type).@"struct".fields, system_scheduler_interfaces, 0..) |system_field, *system_scheduler_interface, system_index| {
                    const system_scheduler = &@field(event_scheduler, system_field.name);
                    system_scheduler.* = .{
                        .entry_index = system_index,
                        .system_schedulers = system_scheduler_interfaces,
                        .prereq_jobs_inflights = prereq_jobs_inflights,
                        .systems_running = &scheduler.events_systems_running[event_index],
                        .events_error_atomic = &scheduler.events_error_atomics[event_index],
                        .pool = thread_pool,
                        .execute_args = undefined, // Assigned in dispatch
                    };

                    prereq_jobs_inflights[system_index] = .init(0);

                    system_scheduler.execute_args.query_submit_allocator = scheduler.query_submit_allocator;
                    system_scheduler_interface.* = system_scheduler.systemSchedulerInterface();
                }
            }
        }

        pub fn deinit(self: *Scheduler) void {
            const allocator = self.thread_pool.allocator;
            self.thread_pool.deinit();
            allocator.destroy(self.thread_pool);

            self.* = .uninitialized;
        }

        /// Trigger an event asynchronously. The caller must make sure to call waitEvent with matching enum identifier
        /// Before relying on the result of a trigger.
        /// Parameters:
        ///     - event:            The event enum identifier. When registering an event on Wolrd creation a identifier is
        ///                         submitted.
        ///     - event_argument:   An event specific argument.
        ///
        /// Example:
        /// ```
        /// const Scheduler = ecez.CreateScheduler(
        ///     Storage,
        ///     .{
        ///         ecez.Event("on_mouse", .{onMouseSystem}, .{ .EventArgument = EventArgument}),
        ///     },
        /// );
        /// // ... storage creation etc ...
        /// // trigger mouse handle
        /// try scheduler.dispatchEvent(&storage, .on_mouse, @as(MouseArg, mouse));
        /// ```
        pub fn dispatchEvent(self: *Scheduler, storage: *Storage, comptime event: EventsEnum, event_argument: getEventArgumentType(event)) error{OutOfMemory}!void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("dispatchEvent {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const event_index = @intFromEnum(event);
            const triggered_event = events[event_index];

            // Set error state to void
            _ = self.events_error_atomics[event_index].store(0, .monotonic);

            const event_dependencies: []const gen_dependency_chain.Dependency = &@field(self.dependencies, triggered_event._name);
            const prereq_jobs_inflights = &@field(self.pre_req_inflight_storage, triggered_event._name);
            const event_scheduler = &@field(self.events_scheduler, triggered_event._name);
            const run_on_main_thread = builtin.single_threaded or self.thread_pool.threads.len == 0 or triggered_event._run_on_main_thread;
            if (run_on_main_thread == false) {
                @branchHint(.likely);

                self.events_systems_running[event_index].store(
                    0,
                    .monotonic,
                );

                for (prereq_jobs_inflights, 0..) |*prereq_jobs_inflight, system_index| {
                    const system_dep_count = event_dependencies[system_index].prereq_count;
                    prereq_jobs_inflight.store(system_dep_count, .monotonic);
                }
            }

            inline for (event_scheduler) |*system_scheduler| {
                system_scheduler.execute_args.storage = storage;
                system_scheduler.execute_args.event_argument = event_argument;
            }

            // Ensure each runnable is ready to be signaled by previous jobs
            if (run_on_main_thread) {
                @branchHint(.unlikely);

                inline for (event_scheduler) |*system_scheduler| {
                    var opaque_scheduler: *anyopaque = @ptrCast(system_scheduler);
                    _ = &opaque_scheduler; // silence zig thinking opaque_scheduler is not a var

                    @TypeOf(system_scheduler.*).execute(opaque_scheduler);

                    // If an error may occur for this event
                    if (comptime triggered_event.GetErrorSet()) |_| {
                        // catch error if any
                        const event_error_value = system_scheduler.events_error_atomic.load(.monotonic);
                        if (event_error_value > 0) {
                            // Hint to the scheduler that wait is no longer needed
                            system_scheduler.systems_running.store(0, .monotonic);

                            return;
                        }
                    }
                }
            } else {
                @branchHint(.likely);

                const event_scheduler_info = @typeInfo(@TypeOf(@field(self.events_scheduler, triggered_event._name)));
                inline for (event_scheduler, event_scheduler_info.@"struct".fields, 0..) |*system_scheduler, field_info, system_index| {
                    const system_dep_count = event_dependencies[system_index].prereq_count;
                    if (system_dep_count == 0) {
                        var opaque_scheduler: *anyopaque = @ptrCast(system_scheduler);
                        _ = &opaque_scheduler; // silence zig thinking opaque_scheduler is not a var

                        try self.thread_pool.spawn(field_info.type.schedule, .{ opaque_scheduler, event_dependencies });

                        _ = self.events_systems_running[event_index].fetchAdd(
                            1,
                            .monotonic,
                        );
                    }
                }
            }
        }

        /// Wait for all jobs from a dispatchEvent to finish by blocking the calling thread
        /// should only be called from the dispatchEvent thread
        pub fn waitEvent(self: *Scheduler, comptime event: EventsEnum) return_type_blk: {
            const event_index = @intFromEnum(event);
            const wait_event = events[event_index];
            break :return_type_blk wait_event.GetErrorUnion();
        } {
            const tracy_zone_name = comptime std.fmt.comptimePrint("{s}: event {s}", .{ @src().fn_name, @tagName(event) });
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const event_index = @intFromEnum(event);

            // Spinlock :/
            while (self.events_systems_running[event_index].load(.monotonic) > 0) {}

            const wait_event = events[event_index];
            const EventErrorUnion = wait_event.GetErrorUnion();

            if (comptime EventErrorUnion != void) {
                // catch error if any
                const event_error_value = self.events_error_atomics[event_index].load(.monotonic);
                if (event_error_value > 0) {
                    const err: EventErrorUnion = @errorCast(@errorFromInt(event_error_value - 1));
                    return err;
                }
            }
        }

        /// Check if an event is currently being executed
        /// should only be called from the dispatchEvent thread
        pub fn isEventInFlight(self: *Scheduler, comptime event: EventsEnum) bool {
            const tracy_zone_name = comptime std.fmt.comptimePrint("{s}: event {s}", .{ @src().fn_name, @tagName(event) });
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const event_index = @intFromEnum(event);
            return self.events_systems_running[event_index].load(.monotonic) > 0;
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
            const event_dependencies = @field(Dependencies{}, triggered_event._name);
            return &event_dependencies;
        }

        pub fn getEventArgumentType(comptime event: EventsEnum) type {
            if (@inComptime() == false) {
                @compileError(@src().fn_name ++ " should be called in comptime only");
            }

            const event_index = @intFromEnum(event);
            const triggered_event = events[event_index];
            return triggered_event._EventArgument;
        }
    };
}

const SystemSchedulerInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        schedule: *const fn (*anyopaque, dependencies: []const gen_dependency_chain.Dependency) void,
        execute: *const fn (*anyopaque) void,
    };

    pub fn schedule(scheduler: SystemSchedulerInterface, dependencies: []const gen_dependency_chain.Dependency) void {
        scheduler.vtable.schedule(scheduler.ptr, dependencies);
    }

    pub fn execute(scheduler: SystemSchedulerInterface) void {
        scheduler.vtable.execute(scheduler.ptr);
    }
};

fn SystemScheduler(
    comptime func: anytype,
    comptime Storage: type,
    comptime EventArgument: type,
    comptime EventErrorUnion: type,
    comptime ErrorAtomic: type,
) type {
    return struct {
        pub const Index = u32;

        pub const SystemExecute = struct {
            event_argument: EventArgument,
            query_submit_allocator: std.mem.Allocator,
            storage: *Storage,
        };

        entry_index: Index,
        system_schedulers: []SystemSchedulerInterface,
        prereq_jobs_inflights: []std.atomic.Value(u32),
        systems_running: *std.atomic.Value(i32),

        events_error_atomic: *ErrorAtomic,

        pool: *ThreadPool,

        execute_args: SystemExecute,

        pub fn systemSchedulerInterface(self: *@This()) SystemSchedulerInterface {
            return SystemSchedulerInterface{
                .ptr = @ptrCast(self),
                .vtable = &.{
                    .schedule = schedule,
                    .execute = execute,
                },
            };
        }

        pub fn schedule(ctx: *anyopaque, dependencies: []const gen_dependency_chain.Dependency) void {
            const thread_zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer thread_zone.End();

            const system_scheduler: *@This() = @ptrCast(@alignCast(ctx));

            // Launch system
            execute(ctx);
            defer {
                // Decrement schedulers "system in-flight" count
                _ = system_scheduler.systems_running.fetchSub(1, .acq_rel);
            }

            // If an error may occur for this event
            if (comptime EventErrorUnion != void) {
                // catch error if any
                const event_error_value = system_scheduler.events_error_atomic.load(.monotonic);
                if (event_error_value > 0) {
                    return;
                }
            }

            // Once done, loop all systems that depend on this system
            const signal_indices = dependencies[system_scheduler.entry_index].signal_indices;
            const other_event_schedulers = system_scheduler.system_schedulers;
            for (signal_indices) |signal_index| {
                // Decrement blocking prerequisites count for these systems
                const blocking_count = system_scheduler.prereq_jobs_inflights[signal_index].fetchSub(1, .monotonic);
                if (blocking_count == 1) {
                    // increment systems_running counter
                    _ = system_scheduler.systems_running.fetchAdd(1, .acq_rel);

                    // Schedule depending systems that are no longer blocked
                    system_scheduler.pool.spawn(
                        SystemSchedulerInterface.schedule,
                        .{ other_event_schedulers[signal_index], dependencies },
                    ) catch @panic("failed to spawn system");
                }
            }
        }

        pub fn execute(ctx: *anyopaque) void {
            const system_scheduler: *@This() = @ptrCast(@alignCast(ctx));
            const execute_args = &system_scheduler.execute_args;
            const FuncType = @TypeOf(func);
            const param_types = comptime get_param_types_blk: {
                const func_info = @typeInfo(FuncType).@"fn";
                var types: [func_info.params.len]type = undefined;
                for (&types, func_info.params) |*Type, param| {
                    Type.* = param.type.?;
                }

                break :get_param_types_blk types;
            };

            var arguments: std.meta.Tuple(&param_types) = undefined;
            inline for (param_types, &arguments) |Param, *argument| {
                var arg = get_arg_blk: {
                    if (Param == EventArgument) {
                        break :get_arg_blk execute_args.event_argument;
                    }

                    const param_info = @typeInfo(Param);
                    if (param_info != .pointer) {
                        @compileError("System Query and Subset arguments must be pointer type");
                    }

                    break :get_arg_blk switch (param_info.pointer.child.EcezType) {
                        QueryType => param_info.pointer.child.submit(execute_args.query_submit_allocator, execute_args.storage) catch @panic("Scheduler dispatch query_submit_allocator OOM"),
                        QueryAnyType => param_info.pointer.child.prepare(execute_args.storage),
                        SubsetType => param_info.pointer.child{ .storage = execute_args.storage },
                        else => |Type| @compileError("Unknown EcezType " ++ @typeName(Type)), // This is a ecez bug if hit (i.e not user error)
                    };
                };

                if (Param == EventArgument) {
                    argument.* = execute_args.event_argument;
                } else {
                    argument.* = &arg;
                }
            }

            // if this is a debug build we do not want inline (to get better error messages), otherwise inline systems for performance
            const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .auto;
            const return_error_type = CompileReflect.functionErrorSet(FuncType);
            if (comptime return_error_type != null) {
                @call(system_call_modidifer, func, arguments) catch |err| {
                    system_scheduler.events_error_atomic.store(@intFromError(err) + 1, .monotonic);
                };
            } else {
                @call(system_call_modidifer, func, arguments);
            }

            // For each system argument, make sure to deinitialize any queries produced by system dispatch
            inline for (param_types, &arguments) |Param, *arg| {
                if (Param == EventArgument) {
                    continue;
                }

                const param_info = @typeInfo(Param);
                switch (param_info.pointer.child.EcezType) {
                    QueryType => arg.*.deinit(execute_args.query_submit_allocator),
                    else => {},
                }
            }
        }
    };
}

pub const EventType = struct {};

pub const EventConfig = struct {
    EventArgument: type = void,
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
        pub const _EventArgument = config.EventArgument;

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

        pub fn GetErrorSet() ?type {
            const EmptyError = error{};
            comptime var AllErrorSet = EmptyError;
            const systems_info = @typeInfo(@TypeOf(ThisEvent._systems));
            inline for (systems_info.@"struct".fields) |field_system| {
                if (CompileReflect.functionErrorSet(field_system.type)) |error_set| {
                    AllErrorSet = AllErrorSet || error_set;
                }
            }

            if (AllErrorSet == EmptyError) {
                return null;
            }
            return AllErrorSet;
        }

        pub fn GetErrorUnion() type {
            return if (GetErrorSet()) |ErrorSet| ErrorSet!void else void;
        }

        test GetErrorSet {
            const Systems = struct {
                pub fn oom(a: *Testing.Queries.ReadA[0]) error{OutOfMemory}!void {
                    while (a.next()) |_| {}
                }

                pub fn myError(a: *Testing.Queries.ReadA[0]) error{MyError}!void {
                    while (a.next()) |_| {}
                }

                pub fn twoErrors(a: *Testing.Queries.ReadA[0]) error{ One, Two }!void {
                    while (a.next()) |_| {}
                }
            };

            const OnFooEvent = Event(
                "on_foo",
                .{
                    Systems.oom,
                    Systems.oom,
                    Systems.myError,
                    Systems.twoErrors,
                },
                .{},
            );

            const ErrorSet = OnFooEvent.GetErrorSet().?;
            const error_set_info = @typeInfo(ErrorSet);
            const error_set = error_set_info.error_set.?;
            try testing.expectEqual(4, error_set_info.error_set.?.len);
            try testing.expectEqual("OutOfMemory", error_set[0].name);
            try testing.expectEqual("MyError", error_set[1].name);
            try testing.expectEqual("One", error_set[2].name);
            try testing.expectEqual("Two", error_set[3].name);
        }
    };
}

// TODO: move scheduler and dependency_chain to same folder. Move this logic in this folder out of this file
pub const CompileReflect = struct {
    pub inline fn getTupleFieldName(comptime index: u32) []const u8 {
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

    pub fn functionErrorSet(comptime @"fn": type) ?type {
        const fn_info = @typeInfo(@"fn");
        if (fn_info != .@"fn") {
            return null;
        }

        const ReturnType = fn_info.@"fn".return_type orelse {
            return null;
        };

        const return_type_info = @typeInfo(ReturnType);
        if (return_type_info != .error_union) {
            if (return_type_info != .void) {
                @compileError("system '" ++ @typeName(@"fn") ++ "' is returning '" ++ @typeName(ReturnType) ++ "', systems must return void or error{}!void");
            }
            return null;
        }

        return return_type_info.error_union.error_set;
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
                .is_comptime = false,
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

    pub fn EventSchedulerType(
        comptime event_count: u32,
        comptime events: anytype,
        comptime system_counts: []const u32,
        comptime Storage: type,
        comptime ErrorAtomic: type,
    ) type {
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (&fields, events, system_counts) |*field, event, system_count| {
            var event_fields: [system_count]Type.StructField = undefined;
            for (&event_fields, event._systems, 0..) |*event_field, system, system_index| {
                const field_name = CompileReflect.getTupleFieldName(system_index);
                const FieldType = SystemScheduler(
                    system,
                    Storage,
                    event._EventArgument,
                    event.GetErrorUnion(),
                    ErrorAtomic,
                );
                event_field.* = Type.StructField{
                    .name = field_name[0.. :0],
                    .type = FieldType,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(FieldType),
                };
            }

            const EventSystemContainer = @Type(Type{ .@"struct" = Type.Struct{
                .layout = .auto,
                .backing_integer = null,
                .fields = &event_fields,
                .decls = &[0]Type.Declaration{},
                .is_tuple = true,
            } });
            field.* = Type.StructField{
                .name = event._name[0.. :0],
                .type = EventSystemContainer,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(EventSystemContainer),
            };
        }

        return @Type(Type{ .@"struct" = Type.Struct{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = false,
        } });
    }

    pub fn EventSystemStorageType(
        comptime event_count: u32,
        comptime events: anytype,
        comptime system_counts: []const u32,
        comptime StoreType: type,
    ) type {
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (&fields, events, system_counts) |*field, event, system_count| {
            const FieldType = [system_count]StoreType;
            field.* = Type.StructField{
                .name = event._name[0.. :0],
                .type = FieldType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
            };
        }

        return @Type(Type{ .@"struct" = Type.Struct{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = false,
        } });
    }

    pub fn EventErrorAtomicStorageType(
        comptime event_count: u32,
        comptime FieldType: type,
    ) type {
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (&fields, 0..) |*field, event_index| {
            field.* = Type.StructField{
                .name = std.fmt.comptimePrint("{d}", .{event_index}),
                .type = FieldType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(FieldType),
            };
        }

        return @Type(Type{ .@"struct" = Type.Struct{
            .layout = .auto,
            .backing_integer = null,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
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
            "on_foo",
            .{SystemStruct.mutateStuff},
            .{},
        );

        var scheduler = CreateScheduler(StorageStub, .{OnFooEvent}).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        try scheduler.dispatchEvent(&storage, .on_foo, {});
        scheduler.waitEvent(.on_foo);

        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 1 },
            .b = Testing.Component.B{ .value = 2 },
        };
        const entity = try storage.createEntity(initial_state);

        try scheduler.dispatchEvent(&storage, .on_foo, {});
        scheduler.waitEvent(.on_foo);

        try testing.expectEqual(
            Testing.Component.A{ .value = 3 },
            storage.getComponent(entity, Testing.Component.A).?,
        );
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

        var scheduler = CreateScheduler(StorageStub, .{Event(
            "on_foo",
            .{
                SystemStruct.incrB,
                SystemStruct.decrB,
                SystemStruct.spawnEntityAFromB,
                SystemStruct.spawnEntityBFromA,
                SystemStruct.incrA,
                SystemStruct.decrA,
            },
            .{
                .EventArgument = *SpawnedEntities,
            },
        )}).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        // Do this test repeatedly to ensure it's determenistic (no race hazards)
        for (0..256) |_| {
            storage.clearRetainingCapacity();

            var initial_entites: [initial_entity_count]Entity = undefined;
            for (&initial_entites, 0..) |*entity, iter| {
                entity.* = try storage.createEntity(.{
                    Testing.Component.B{ .value = @intCast(iter) },
                });
            }

            var spawned_entites: SpawnedEntities = undefined;
            try scheduler.dispatchEvent(&storage, .on_foo, &spawned_entites);
            scheduler.waitEvent(.on_foo);

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

        var scheduler = CreateScheduler(StorageStub, .{Event(
            "on_foo",
            .{
                SystemStruct.incrB,
                SystemStruct.decrB,
                SystemStruct.incrA,
                SystemStruct.decrA,
                SystemStruct.incrB,
            },
            .{},
        )}).uninitialized;

        try scheduler.init(.{
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

        try scheduler.dispatchEvent(&storage, .on_foo, {});
        scheduler.waitEvent(.on_foo);

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

    var scheduler = CreateScheduler(StorageStub, .{Event(
        "on_foo",
        .{SystemStruct.mutateStuff},
        .{},
    )}).uninitialized;

    try scheduler.init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    try scheduler.dispatchEvent(&storage, .on_foo, {});
    scheduler.waitEvent(.on_foo);

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    try scheduler.dispatchEvent(&storage, .on_foo, {});
    scheduler.waitEvent(.on_foo);

    try testing.expectEqual(
        Testing.Component.B{ .value = 42 },
        storage.getComponent(entity, Testing.Component.B).?,
    );
}

test "system can fail" {
    const SystemStruct = struct {
        pub fn mutateA(a_query: *Testing.Queries.WriteA[0]) error{Kaboom}!void {
            while (a_query.next()) |entity| {
                entity.a.value += 1;
            }

            return error.Kaboom;
        }

        // keep a system that is unrelated to the failure chain to invoke some
        // none-determinsim (and potentially trigger scheduler bugs)
        pub fn mutateD(d_query: *Testing.Queries.WriteD[0]) void {
            while (d_query.next()) |entity| {
                entity.d.* = .two;
            }
        }

        pub fn mutateAB(barrier_a: *Testing.Queries.ReadA[0], b_query: *Testing.Queries.WriteB[0]) void {
            _ = barrier_a;

            while (b_query.next()) |entity| {
                entity.b.value += 1;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const Scheduler = CreateScheduler(StorageStub, .{Event(
        "on_foo",
        .{
            SystemStruct.mutateA,
            SystemStruct.mutateD,
            SystemStruct.mutateAB,
        },
        .{},
    )});
    var scheduler = Scheduler.uninitialized;

    try scheduler.init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    // Repeat test incase we have non-deterministic behaviour
    for (0..512) |_| {
        var entities: [100]Entity = undefined;
        for (&entities, 0..) |*entity, index| {
            entity.* = try storage.createEntity(.{
                Testing.Component.A{ .value = @intCast(index) },
                Testing.Component.B{ .value = @intCast(index) },
                Testing.Component.D.one,
            });
        }

        try scheduler.dispatchEvent(&storage, .on_foo, {});

        try testing.expectError(
            error.Kaboom,
            scheduler.waitEvent(.on_foo),
        );

        for (entities, 0..) |entity, index| {
            const ab = storage.getComponents(entity, Testing.Structure.AB).?;
            try testing.expectEqual(
                Testing.Component.A{ .value = @intCast(index + 1) },
                ab.a,
            );
            testing.expectEqual(
                Testing.Component.B{ .value = @intCast(index) },
                ab.b,
            ) catch unreachable;
        }

        storage.clearRetainingCapacity(); // clear to repeat
    }
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

            var scheduler = CreateScheduler(StorageStub, .{
                Event(
                    "on_foo",
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
            }).uninitialized;

            try scheduler.init(.{
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

            try scheduler.dispatchEvent(&storage, .on_foo, {});
            scheduler.waitEvent(.on_foo);

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
            try scheduler.dispatchEvent(&storage, .on_foo, {});
            scheduler.waitEvent(.on_foo);

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

        var scheduler = CreateScheduler(StorageStub, .{
            Event(
                "on_a",
                .{
                    SystemStruct.incrA,
                    SystemStruct.doubleA,
                    SystemStruct.incrA,
                },
                .{},
            ),
            Event(
                "on_b",
                .{
                    SystemStruct.incrB,
                    SystemStruct.doubleB,
                    SystemStruct.incrB,
                },
                .{},
            ),
        }).uninitialized;

        try scheduler.init(.{
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
        try scheduler.dispatchEvent(&storage, .on_a, {});
        try scheduler.dispatchEvent(&storage, .on_b, {});
        scheduler.waitIdle();

        // ((3 + 1) * 2) + 1 = 9
        try scheduler.dispatchEvent(&storage, .on_a, {});
        try scheduler.dispatchEvent(&storage, .on_b, {});
        scheduler.waitIdle();

        // ((9 + 1) * 2) + 1 = 21
        try scheduler.dispatchEvent(&storage, .on_a, {});
        try scheduler.dispatchEvent(&storage, .on_b, {});
        scheduler.waitIdle();

        // ((21 + 1) * 2) + 1 = 45
        try scheduler.dispatchEvent(&storage, .on_a, {});
        try scheduler.dispatchEvent(&storage, .on_b, {});
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

        var scheduler = CreateScheduler(StorageStub, .{
            Event(
                "incr_destroy",
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
        }).uninitialized;

        try scheduler.init(.{
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

        try scheduler.dispatchEvent(&storage, .incr_destroy, {});
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

        const Scheduler = CreateScheduler(StorageStub, .{
            Event(
                "on_a",
                .{
                    SystemStruct.incrA,
                    SystemStruct.doubleA,
                    SystemStruct.incrA,
                },
                .{},
            ),
            Event(
                "on_b",
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
            const actualDumpOnA = comptime Scheduler.dumpDependencyChain(.on_a);
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
            const actualDumpOnB = comptime Scheduler.dumpDependencyChain(.on_b);
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

        var scheduler = CreateScheduler(StorageStub, .{
            Event(
                "on_foo",
                .{System.addToA},
                .{
                    .EventArgument = AddValue,
                },
            ),
        }).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

        const value = 42;
        try scheduler.dispatchEvent(&storage, .on_foo, AddValue{ .v = value });
        scheduler.waitEvent(.on_foo);

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

        var scheduler = CreateScheduler(StorageStub, .{
            Event(
                "on_foo",
                .{System.addToA},
                .{
                    .EventArgument = *AddValue,
                },
            ),
        }).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const value = 42;
        _ = try storage.createEntity(.{Testing.Component.A{ .value = value }});

        var event_argument = AddValue{ .v = 0 };
        try scheduler.dispatchEvent(&storage, .on_foo, &event_argument);
        scheduler.waitEvent(.on_foo);

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

        var scheduler = CreateScheduler(StorageStub, .{Event(
            "on_foo",
            .{
                SystemStruct.eventSystem,
            },
            .{},
        )}).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity = try storage.createEntity(.{Testing.Component.A{ .value = fail_value }});

        try scheduler.dispatchEvent(&storage, .on_foo, {});
        scheduler.waitEvent(.on_foo);

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

        var scheduler = CreateScheduler(StorageStub, .{
            Event("on_inc_a", .{Systems.incA}, .{}),
            Event("on_inc_b", .{Systems.incB}, .{}),
        }).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const entity1 = try storage.createEntity(.{Testing.Component.A{ .value = 0 }});

        try scheduler.dispatchEvent(&storage, .on_inc_a, {});
        scheduler.waitEvent(.on_inc_a);

        try testing.expectEqual(
            Testing.Component.A{ .value = 1 },
            storage.getComponent(entity1, Testing.Component.A).?,
        );

        // move entity to archetype A, B
        try storage.setComponents(entity1, .{Testing.Component.B{ .value = 0 }});

        try scheduler.dispatchEvent(&storage, .on_inc_a, {});
        scheduler.waitEvent(.on_inc_a);

        try testing.expectEqual(
            Testing.Component.A{ .value = 2 },
            storage.getComponent(entity1, Testing.Component.A).?,
        );

        try scheduler.dispatchEvent(&storage, .on_inc_b, {});
        scheduler.waitEvent(.on_inc_b);

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

        try scheduler.dispatchEvent(&storage, .on_inc_a, {});
        scheduler.waitEvent(.on_inc_a);

        try testing.expectEqual(
            Testing.Component.A{ .value = 1 },
            storage.getComponent(entity2, Testing.Component.A).?,
        );

        try scheduler.dispatchEvent(&storage, .on_inc_b, {});
        scheduler.waitEvent(.on_inc_b);

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

        var scheduler = CreateScheduler(StorageStub, .{Event(
            "on_foo",
            .{
                Systems.incA,
            },
            .{},
        )}).uninitialized;

        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        for (0..100) |_| {
            try scheduler.dispatchEvent(&storage, .on_foo, {});
            scheduler.waitEvent(.on_foo);
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

    var scheduler = CreateScheduler(StorageStub, .{
        Event("on_foo", .{
            Systems.first,
            Systems.second,
            Systems.third,
        }, .{
            .EventArgument = *Resets,
        }),
    }).uninitialized;

    try scheduler.init(.{
        .pool_allocator = std.testing.allocator,
        .query_submit_allocator = std.testing.allocator,
    });
    defer scheduler.deinit();

    var resets = Resets{};

    try scheduler.dispatchEvent(&storage, .on_foo, &resets);

    try std.testing.expect(scheduler.isEventInFlight(.on_foo));
    resets.start[0].set();
    resets.stop[0].wait();

    try std.testing.expect(scheduler.isEventInFlight(.on_foo));
    resets.start[1].set();
    resets.stop[1].wait();

    try std.testing.expect(scheduler.isEventInFlight(.on_foo));
    resets.start[2].set();
    resets.stop[2].wait();

    // Even though we wait on resets.stop[2], this ResetEvent is signaled by the system.
    // We dont have any guarantee that scheduler's internal tracking of on_foo will actually propagate as done
    // before sampling event status with 'isEventInFlight'.
    scheduler.waitEvent(.on_foo);

    try std.testing.expect(!scheduler.isEventInFlight(.on_foo));
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
        const Scheduler = CreateScheduler(RepStorage, .{Event(
            "on_foo",
            .{Systems.addToTracker},
            .{
                .EventArgument = *Tracker,
            },
        )});

        var storage = try RepStorage.init(testing.allocator);
        defer storage.deinit();

        var scheduler = Scheduler.uninitialized;
        try scheduler.init(.{
            .pool_allocator = std.testing.allocator,
            .query_submit_allocator = std.testing.allocator,
        });
        defer scheduler.deinit();

        const inital_state = .{Testing.Component.A{ .value = 1 }};
        _ = try storage.createEntity(inital_state);
        _ = try storage.createEntity(inital_state);

        var tracker = Tracker{ .count = 0 };

        try scheduler.dispatchEvent(&storage, .on_foo, &tracker);
        scheduler.waitEvent(.on_foo);

        _ = try storage.createEntity(inital_state);
        _ = try storage.createEntity(inital_state);

        try scheduler.dispatchEvent(&storage, .on_foo, &tracker);
        scheduler.waitEvent(.on_foo);

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
        const Scheduler = CreateScheduler(RepStorage, .{Event(
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

        var scheduler = Scheduler.uninitialized;
        try scheduler.init(.{
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

        try scheduler.dispatchEvent(&storage, .on_foo, {});
        scheduler.waitEvent(.on_foo);

        const final_state = storage.getComponents(my_entity, Testing.Structure.AB).?;
        try testing.expectEqual(@as(u32, 2), final_state.a.value);
        try testing.expectEqual(@as(u32, 1), final_state.b.value);
    }
}
