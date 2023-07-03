const std = @import("std");

const ztracy = @import("ztracy");

const zjobs = @import("zjobs");
const JobQueue = zjobs.JobQueue(.{});
const JobId = zjobs.JobId;

const meta = @import("meta.zig");
const SystemMetadata = meta.SystemMetadata;

const Color = @import("misc.zig").Color;

/// Allow the user to attach systems to a storage. The user can then trigger events on the scheduler to execute
/// the systems in a multithreaded environment
pub fn CreateScheduler(
    comptime Storage: type,
    comptime events: anytype,
) type {
    const event_count = meta.countAndVerifyEvents(events);
    const EventJobsInFlight = blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        inline for (&fields, events, 0..) |*field, event, i| {
            const default_value = [_]JobId{.none} ** event.system_count;
            var num_buf: [8]u8 = undefined;
            field.* = Type.StructField{
                .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                .type = [event.system_count]JobId,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf([event.system_count]JobId),
            };
        }

        break :blk @Type(Type{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
        } });
    };

    return struct {
        const Scheduler = @This();

        pub const EventsEnum = meta.GenerateEventsEnum(event_count, events);

        storage: *Storage,

        execution_job_queue: JobQueue,
        event_jobs_in_flight: EventJobsInFlight,

        /// Initialized the system scheduler. User must make sure to call deinit
        pub fn init(storage: *Storage) Scheduler {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer zone.End();

            return Scheduler{
                .storage = storage,
                .execution_job_queue = JobQueue.init(),
                .event_jobs_in_flight = EventJobsInFlight{},
            };
        }

        pub fn deinit(self: *Scheduler) void {
            self.execution_job_queue.deinit();
        }

        /// Trigger an event asynchronously. The caller must make sure to call waitEvent with matching enum identifier
        /// Before relying on the result of a trigger.
        /// Parameters:
        ///     - event:                The event enum identifier. When registering an event on Wolrd creation a identifier is
        ///                             submitted.
        ///     - event_extra_argument: An event specific argument. Keep in mind that if you submit a pointer as argument data
        ///                             then the lifetime of the argument must ourlive the execution of the event.
        ///     - exclude_types:        A struct of component types to exclude from the event dispatch. Meaning entities with these
        ///                             components will be ignored even though they have all components listed in the arguments of the
        ///                             system
        ///
        /// Example:
        /// ```
        /// const Scheduler = ecez.CreateScheduler(Storage, .{ecez.Event("onMouse", .{onMouseSystem}, .{MouseArg})})
        /// // ... storage creation etc ...
        /// // trigger mouse handle, exclude any entity with the RatComponent from this event >:)
        /// scheduler.dispatchEvent(.onMouse, @as(MouseArg, mouse), .{RatComponent});
        /// ```
        pub fn dispatchEvent(self: *Scheduler, comptime event: EventsEnum, event_extra_argument: anytype, comptime exclude_types: anytype) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("dispatchEvent {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("event exclude types must be a tuple of types");
            }

            const exclude_type_arr = comptime exclude_type_extract_blk: {
                var type_arr: [exclude_type_info.Struct.fields.len]type = undefined;
                inline for (&type_arr, exclude_type_info.Struct.fields, 0..) |*exclude_type, field, index| {
                    if (field.type != type) {
                        @compileError("event include types field " ++ field.name ++ "must be a component type, was " ++ @typeName(field.type));
                    }

                    exclude_type.* = exclude_types[index];

                    var type_is_component = false;
                    for (Storage.sorted_component_types) |Component| {
                        if (exclude_type.* == Component) {
                            type_is_component = true;
                            break;
                        }
                    }

                    if (type_is_component == false) {
                        @compileError("event include types field " ++ field.name ++ " is not a registered Storage component");
                    }
                }
                break :exclude_type_extract_blk type_arr;
            };
            const exclude_bitmask = comptime include_bit_blk: {
                var bitmask: Storage.ComponentMask.Bits = 0;
                inline for (exclude_type_arr) |Component| {
                    bitmask |= 1 << Storage.Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };

            // initiate job executions for dispatch
            if (self.execution_job_queue.isStarted() == false) {
                self.execution_job_queue.start();
            }

            var event_jobs_in_flight = &self.event_jobs_in_flight[@intFromEnum(event)];
            const triggered_event = events[@intFromEnum(event)];

            // TODO: verify systems and arguments in type initialization
            const EventExtraArgument = @TypeOf(event_extra_argument);
            if (@sizeOf(triggered_event.EventArgument) > 0) {
                if (comptime meta.isSpecialArgument(.event, EventExtraArgument)) {
                    @compileError("event arguments should not be wrapped in EventArgument type when triggering an event");
                }
                if (EventExtraArgument != triggered_event.EventArgument) {
                    @compileError("event " ++ @tagName(event) ++ " was declared to accept " ++ @typeName(triggered_event.EventArgument) ++ " got " ++ @typeName(EventExtraArgument));
                }
            }

            inline for (triggered_event.systems_info.metadata, 0..) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();

                comptime var field_map: [component_query_types.len]usize = undefined;
                const sorted_components: [component_query_types.len]type = comptime sort_comps: {
                    var index: usize = 0;
                    var sort_components: [component_query_types.len]type = undefined;
                    for (Storage.sorted_component_types) |SortedComp| {
                        for (component_query_types, 0..) |QueryComp, query_index| {
                            if (SortedComp == QueryComp) {
                                sort_components[index] = QueryComp;
                                field_map[query_index] = index;
                                index += 1;
                                break;
                            }
                        }
                    }
                    break :sort_comps sort_components;
                };

                const include_bitmask = include_bits_blk: {
                    comptime var bitmask = 0;
                    inline for (sorted_components) |SortedComp| {
                        bitmask |= 1 << Storage.Container.componentIndex(SortedComp);
                    }
                    break :include_bits_blk bitmask;
                };

                const DispatchJob = EventDispatchJob(
                    triggered_event.systems_info.functions[system_index],
                    *const triggered_event.systems_info.function_types[system_index],
                    metadata,
                    include_bitmask,
                    exclude_bitmask,
                    component_query_types,
                    &field_map,
                    @TypeOf(event_extra_argument),
                );

                // initialized the system job
                var system_job = DispatchJob{
                    .storage = self.storage,
                    .extra_argument = event_extra_argument,
                };

                // TODO: should dispatchEvent be synchronous? (move wait until the end of the dispatch function)
                // wait for previous dispatch to finish
                self.execution_job_queue.wait(event_jobs_in_flight[system_index]);

                const job_dependency = job_dep_blk: {
                    switch (metadata) {
                        .depend_on => |depend_on_metadata| {
                            const indices = comptime depend_on_metadata.getIndexRange(triggered_event);
                            var jobs: [indices.len]JobId = undefined;
                            inline for (indices, 0..) |index, i| {
                                jobs[i] = event_jobs_in_flight[index];
                            }

                            break :job_dep_blk self.execution_job_queue.combine(&jobs) catch JobId.none;
                        },
                        .common => break :job_dep_blk JobId.none,
                        .event => break :job_dep_blk JobId.none,
                    }
                };

                event_jobs_in_flight[system_index] = self.execution_job_queue.schedule(job_dependency, system_job) catch |err| {
                    switch (err) {
                        error.Uninitialized => unreachable, // schedule can fail on "Uninitialized" which does not happen since you must init storage
                        error.Stopped => return,
                    }
                };
            }
        }

        /// Wait for all jobs from a dispatchEvent to finish by blocking the calling thread
        /// should only be called from the dispatchEvent thread
        pub fn waitEvent(self: *Scheduler, comptime event: EventsEnum) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("Storage wait event {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            for (self.event_jobs_in_flight[@intFromEnum(event)]) |job_in_flight| {
                self.execution_job_queue.wait(job_in_flight);
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

        fn EventDispatchJob(
            comptime func: *const anyopaque,
            comptime FuncType: type,
            comptime metadata: SystemMetadata,
            comptime include_bitmask: Storage.ComponentMask.Bits,
            comptime exclude_bitmask: Storage.ComponentMask.Bits,
            comptime component_query_types: []const type,
            comptime field_map: []const usize,
            comptime ExtraArgumentType: type,
        ) type {
            // in the case where the extra argument is a pointer we get the pointer child type
            const extra_argument_child_type = blk: {
                const extra_argument_info = @typeInfo(ExtraArgumentType);
                if (extra_argument_info == .Pointer) {
                    break :blk extra_argument_info.Pointer.child;
                }
                break :blk ExtraArgumentType;
            };

            return struct {
                storage: *Storage,
                extra_argument: ExtraArgumentType,

                pub fn exec(self_job: *@This()) void {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    const param_types = comptime metadata.paramArgTypes();
                    var arguments: std.meta.Tuple(param_types) = undefined;

                    var storage_buffer: [component_query_types.len][]u8 = undefined;
                    var storage = Storage.OpaqueArchetype.StorageData{
                        .inner_len = undefined,
                        .outer = &storage_buffer,
                    };

                    var tree_cursor = Storage.Container.BinaryTree.IterCursor.fromRoot();
                    tree_iter_loop: while (self_job.storage.container.tree.iterate(
                        include_bitmask,
                        exclude_bitmask,
                        &tree_cursor,
                    )) |archetype_index| {
                        self_job.storage.container.archetypes.items[archetype_index].getStorageData(&storage, include_bitmask);

                        const entities = self_job.storage.container.archetypes.items[archetype_index].entities.keys();
                        for (0..storage.inner_len) |inner_index| {
                            inline for (
                                param_types,
                                comptime metadata.paramCategories(),
                                0..,
                            ) |Param, param_category, j| {
                                switch (param_category) {
                                    .component_value => {
                                        const component_index = if (comptime metadata.hasEntityArgument()) j - 1 else j;

                                        // get size of the parameter type
                                        const param_size = @sizeOf(Param);
                                        if (param_size > 0) {
                                            const from = inner_index * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[field_map[component_index]][from..to];
                                            arguments[j] = @as(*Param, @ptrCast(@alignCast(bytes))).*;
                                        }
                                    },
                                    .component_ptr => {
                                        const component_index = if (comptime metadata.hasEntityArgument()) j - 1 else j;
                                        const CompQueryType = component_query_types[component_index];

                                        // get size of the pointer child type (Param == *CompQueryType)
                                        const param_size = @sizeOf(CompQueryType);
                                        if (param_size > 0) {
                                            const from = inner_index * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[field_map[component_index]][from..to];
                                            arguments[j] = @as(*CompQueryType, @ptrCast(@alignCast(bytes)));
                                        }
                                    },
                                    .entity => arguments[j] = entities[inner_index],
                                    .query_ptr => {
                                        const Iter = @typeInfo(Param).Pointer.child;
                                        var iter = Iter.init(self_job.storage.container.archetypes.items, self_job.storage.container.tree);
                                        arguments[j] = &iter;
                                    },
                                    .event_argument_value => arguments[j] = @as(*meta.EventArgument(ExtraArgumentType), @ptrCast(&self_job.extra_argument)).*,
                                    .event_argument_ptr => arguments[j] = @as(*meta.EventArgument(extra_argument_child_type), @ptrCast(self_job.extra_argument)),
                                    .shared_state_value => arguments[j] = self_job.storage.getSharedStateWithOuterType(Param),
                                    .shared_state_ptr => arguments[j] = self_job.storage.getSharedStatePtrWithSharedStateType(Param),
                                }
                            }

                            // if this is a debug build we do not want inline (to get better error messages), otherwise inline systems for performance
                            const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .always_inline;

                            if (comptime metadata.returnSystemCommand()) {
                                const system_ptr: FuncType = @ptrCast(func);
                                const return_command: meta.ReturnCommand = @call(system_call_modidifer, system_ptr.*, arguments);

                                if (return_command == .@"break") {
                                    break :tree_iter_loop;
                                }
                            } else {
                                const system_ptr: FuncType = @ptrCast(func);
                                @call(system_call_modidifer, system_ptr.*, arguments);
                            }
                        }
                    }
                }
            };
        }
    };
}

const Testing = @import("Testing.zig");
const testing = std.testing;

const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;

const Event = meta.Event;
const SharedState = meta.SharedState;
const DependOn = meta.DependOn;
const EventArgument = meta.EventArgument;

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AEntityType = Testing.Archetype.A;
const BEntityType = Testing.Archetype.B;
const AbEntityType = Testing.Archetype.AB;
const AcEntityType = Testing.Archetype.AC;
const BcEntityType = Testing.Archetype.BC;
const AbcEntityType = Testing.Archetype.ABC;

const StorageStub = CreateStorage(Testing.AllComponentsTuple, .{});

test "event can mutate components" {
    const SystemStruct = struct {
        pub fn mutateStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value += @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event parameter order is independent" {
    const SystemStruct = struct {
        pub fn mutateStuff(b: Testing.Component.B, c: Testing.Component.C, a: *Testing.Component.A) void {
            _ = c;
            a.value += @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AbcEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event exclude types exclude entities" {
    const SystemStruct = struct {
        pub fn mutateA(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(&storage);
    defer scheduler.deinit();

    const a_entity = try storage.createEntity(AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    });
    const ab_entity = try storage.createEntity(AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{},
    });
    const ac_entity = try storage.createEntity(AcEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .c = Testing.Component.C{},
    });
    const abc_entity = try storage.createEntity(AbcEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    });

    scheduler.dispatchEvent(.onFoo, .{}, .{ Testing.Component.B, Testing.Component.C });
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(a_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try storage.getComponent(ab_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try storage.getComponent(ac_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try storage.getComponent(abc_entity, Testing.Component.A),
    );

    scheduler.dispatchEvent(.onFoo, .{}, .{Testing.Component.B});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try storage.getComponent(a_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try storage.getComponent(ab_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(ac_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try storage.getComponent(abc_entity, Testing.Component.A),
    );
}

test "events can be registered through struct or individual function(s)" {
    const SystemStruct1 = struct {
        pub fn func1(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn func2(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    const SystemStruct2 = struct {
        pub fn func3(a: *Testing.Component.B) void {
            a.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{
        Event("onFoo", .{
            SystemStruct1.func1,
            DependOn(SystemStruct1.func2, .{SystemStruct1.func1}),
            SystemStruct2,
        }, .{}),
    }).init(&storage);
    defer scheduler.deinit();

    const initial_state = Testing.Archetype.AB{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try storage.getComponent(entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try storage.getComponent(entity, Testing.Component.B),
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

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{
        Event("onFoo", .{SystemType}, .{}),
        Event("onBar", .{systemThree}, .{}),
    }).init(&storage);
    defer scheduler.deinit();

    const entity1 = blk: {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 0 },
            .b = Testing.Component.B{ .value = 0 },
        };
        break :blk try storage.createEntity(initial_state);
    };

    const entity2 = blk: {
        const initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 2 },
        };
        break :blk try storage.createEntity(initial_state);
    };

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try storage.getComponent(entity1, Testing.Component.B),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try storage.getComponent(entity2, Testing.Component.A),
    );

    scheduler.dispatchEvent(.onBar, .{}, .{});
    scheduler.waitEvent(.onBar);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try storage.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 4 },
        try storage.getComponent(entity2, Testing.Component.A),
    );
}

test "events can access shared state" {
    const A = Testing.Component.A;
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: *A, shared: SharedState(A)) void {
            a.*.value = shared.value;
        }
    };

    const Storage = CreateStorage(Testing.AllComponentsTuple, .{A});

    const shared_a = A{ .value = 42 };
    var storage = try Storage.init(
        testing.allocator,
        .{shared_a},
    );
    defer storage.deinit();

    var scheduler = CreateScheduler(Storage, .{Event("onFoo", .{SystemType}, .{})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(shared_a, try storage.getComponent(entity, A));
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

    const Storage = CreateStorage(Testing.AllComponentsTuple, .{A});
    var storage = try Storage.init(testing.allocator, .{A{ .value = 1 }});
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = .{},
    };
    _ = try storage.createEntity(initial_state);

    var scheduler = CreateScheduler(Storage, .{Event("onFoo", .{SystemType}, .{})}).init(&storage);
    defer scheduler.deinit();

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(@as(u8, 2), storage.shared_state[0].value);
}

test "event can have many shared state" {
    const A = Testing.Component.A;
    const B = Testing.Component.B;
    const D = struct { value: u8 };

    const SystemStruct = struct {
        pub fn system1(a: *A, shared: SharedState(A)) void {
            a.value += @as(u32, @intCast(shared.value));
        }

        pub fn system2(a: *A, shared: SharedState(B)) void {
            a.value += @as(u32, @intCast(shared.value));
        }

        pub fn system3(a: *A, shared: SharedState(D)) void {
            a.value += @as(u32, @intCast(shared.value));
        }

        pub fn system4(b: *B, shared_a: SharedState(A), shared_b: SharedState(B)) void {
            b.value += @as(u8, @intCast(shared_a.value));
            b.value += @as(u8, @intCast(shared_b.value));
        }

        pub fn system5(b: *B, shared_b: SharedState(B), shared_a: SharedState(A)) void {
            b.value += @as(u8, @intCast(shared_a.value));
            b.value += @as(u8, @intCast(shared_b.value));
        }

        pub fn system6(b: *B, shared_c: SharedState(D), shared_b: SharedState(B), shared_a: SharedState(A)) void {
            b.value += @as(u8, @intCast(shared_a.value));
            b.value += @as(u8, @intCast(shared_b.value));
            b.value += @as(u8, @intCast(shared_c.value));
        }
    };

    const Storage = CreateStorage(Testing.AllComponentsTuple, .{ A, B, D });

    var storage = try Storage.init(testing.allocator, .{
        A{ .value = 1 },
        B{ .value = 2 },
        D{ .value = 3 },
    });
    defer storage.deinit();

    const initial_state_a = AEntityType{
        .a = .{ .value = 0 },
    };
    const entity_a = try storage.createEntity(initial_state_a);
    const initial_state_b = BEntityType{
        .b = .{ .value = 0 },
    };
    const entity_b = try storage.createEntity(initial_state_b);

    var scheduler = CreateScheduler(Storage, .{Event("onFoo", .{
        SystemStruct.system1,
        DependOn(SystemStruct.system2, .{SystemStruct.system1}),
        DependOn(SystemStruct.system3, .{SystemStruct.system2}),
        SystemStruct.system4,
        DependOn(SystemStruct.system5, .{SystemStruct.system4}),
        DependOn(SystemStruct.system6, .{SystemStruct.system5}),
    }, .{})}).init(&storage);
    defer scheduler.deinit();

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(A{ .value = 6 }, try storage.getComponent(entity_a, A));
    try testing.expectEqual(B{ .value = 12 }, try storage.getComponent(entity_b, B));
}

test "events can access current entity" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(entity: Entity, a: *Testing.Component.A) void {
            a.value += @as(u32, @intCast(entity.id));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemType}, .{})}).init(&storage);
    defer scheduler.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

test "events entity access remain correct after single removeComponent" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(entity: Entity, a: *Testing.Component.A) void {
            a.value += @as(u32, @intCast(entity.id));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemType}, .{})}).init(&storage);
    defer scheduler.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities[0..50]) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
    for (entities[51..100]) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

test "events can accepts event related data" {
    const MouseInput = struct {
        x: u32,
        y: u32,
    };
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: *Testing.Component.A, mouse: EventArgument(MouseInput)) void {
            a.value = mouse.x + mouse.y;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemType}, MouseInput)}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = .{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, MouseInput{ .x = 40, .y = 2 }, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event can mutate event extra argument" {
    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A, a_value: *EventArgument(Testing.Component.A)) void {
            a_value.value = a.value;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct.eventSystem}, .{Testing.Component.A})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    _ = try storage.createEntity(initial_state);

    var event_a = Testing.Component.A{ .value = 0 };

    // make sure test is not modified in an illegal manner
    try testing.expect(initial_state.a.value != event_a.value);

    scheduler.dispatchEvent(.onFoo, &event_a, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(initial_state.a, event_a);
}

test "event can request single query with component" {
    const include = @import("query.zig").include;

    const QueryA = StorageStub.Query(.exclude_entity, .{
        include("a", Testing.Component.A),
    }, .{}).Iter;

    const pass_value = 99;
    const fail_value = 100;

    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A, query: *QueryA) void {
            const item = query.next().?;
            if (a.value == item.a.value) {
                a.value = pass_value;
            } else {
                a.value = fail_value;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct.eventSystem}, .{})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = pass_value },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event exit system loop" {
    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A) meta.ReturnCommand {
            if (a.value == 1) {
                a.value = 42;
                return meta.ReturnCommand.@"break";
            } else {
                a.value = 42;
                return meta.ReturnCommand.@"continue";
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct.eventSystem}, .{})}).init(&storage);
    defer scheduler.deinit();

    const entity0 = try storage.createEntity(AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    });
    const entity1 = try storage.createEntity(AEntityType{
        .a = Testing.Component.A{ .value = 1 },
    });
    const entity2 = try storage.createEntity(AEntityType{
        .a = Testing.Component.A{ .value = 2 },
    });

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try storage.getComponent(entity0, Testing.Component.A),
    );

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try storage.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try storage.getComponent(entity2, Testing.Component.A),
    );
}

test "event can request two queries without components" {
    const include = @import("query.zig").include;

    const QueryAMut = StorageStub.Query(.exclude_entity, .{
        include("a", *Testing.Component.A),
    }, .{}).Iter;

    const QueryAConst = StorageStub.Query(.exclude_entity, .{
        include("a", Testing.Component.A),
    }, .{}).Iter;

    const pass_value = 99;
    const fail_value = 100;

    const SystemStruct = struct {
        pub fn eventSystem(query_mut: *QueryAMut, query_const: *QueryAConst) void {
            const mut_item = query_mut.next().?;
            const const_item = query_const.next().?;
            if (mut_item.a.value == const_item.a.value) {
                mut_item.a.value = pass_value;
            } else {
                mut_item.a.value = fail_value;
            }
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct.eventSystem}, .{})}).init(&storage);
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = pass_value },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

// NOTE: we don't use a cache anymore, but the test can stay for now since it might be good for
//       detecting potential regressions
test "event caching works" {
    const SystemStruct = struct {
        pub fn event1System(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn event2System(b: *Testing.Component.B) void {
            b.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{
        Event("onEvent1", .{SystemStruct.event1System}, .{}),
        Event("onEvent2", .{SystemStruct.event2System}, .{}),
    }).init(&storage);
    defer scheduler.deinit();

    const entity1 = blk: {
        const initial_state = AEntityType{
            .a = .{ .value = 0 },
        };
        break :blk try storage.createEntity(initial_state);
    };

    scheduler.dispatchEvent(.onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 1 }, try storage.getComponent(
        entity1,
        Testing.Component.A,
    ));

    // move entity to archetype A, B
    try storage.setComponent(entity1, Testing.Component.B{ .value = 0 });

    scheduler.dispatchEvent(.onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 2 }, try storage.getComponent(
        entity1,
        Testing.Component.A,
    ));

    scheduler.dispatchEvent(.onEvent2, .{}, .{});
    scheduler.waitEvent(.onEvent2);

    try testing.expectEqual(Testing.Component.B{ .value = 1 }, try storage.getComponent(
        entity1,
        Testing.Component.B,
    ));

    const entity2 = blk: {
        const initial_state = AbcEntityType{
            .a = .{ .value = 0 },
            .b = .{ .value = 0 },
            .c = .{},
        };
        break :blk try storage.createEntity(initial_state);
    };

    scheduler.dispatchEvent(.onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(entity2, Testing.Component.A),
    );

    scheduler.dispatchEvent(.onEvent2, .{}, .{});
    scheduler.waitEvent(.onEvent2);

    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try storage.getComponent(entity2, Testing.Component.B),
    );
}

test "Event with no archetypes does not crash" {
    const SystemStruct = struct {
        pub fn event1System(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct.event1System}, .{})}).init(&storage);
    defer scheduler.deinit();

    for (0..100) |_| {
        scheduler.dispatchEvent(.onFoo, .{}, .{});
        scheduler.waitEvent(.onFoo);
    }
}

test "DependOn makes a events race free" {
    const SystemStruct = struct {
        pub fn addStuff1(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 3);
            a.value += @as(u32, @intCast(b.value));
        }

        pub fn multiplyStuff1(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 2);
            a.value *= @as(u32, @intCast(b.value));
        }

        pub fn addStuff2(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += @as(u32, @intCast(b.value));
        }

        pub fn multiplyStuff2(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{
        Event("onEvent", .{
            SystemStruct.addStuff1,
            DependOn(SystemStruct.multiplyStuff1, .{SystemStruct.addStuff1}),
            DependOn(SystemStruct.addStuff2, .{SystemStruct.multiplyStuff1}),
            DependOn(SystemStruct.multiplyStuff2, .{SystemStruct.addStuff2}),
        }, .{}),
    }).init(&storage);
    defer scheduler.deinit();

    const entity_count = 10_000;
    var entities: [entity_count]Entity = undefined;

    const inital_state = AbEntityType{
        .a = .{ .value = 3 },
        .b = .{ .value = 2 },
    };
    for (&entities) |*entity| {
        entity.* = try storage.createEntity(inital_state);
    }

    scheduler.dispatchEvent(.onEvent, .{}, .{});
    scheduler.waitEvent(.onEvent);

    scheduler.dispatchEvent(.onEvent, .{}, .{});
    scheduler.waitEvent(.onEvent);

    for (entities) |entity| {
        // (((3  + 2) * 2) + 2) * 2 =  24
        // (((24 + 2) * 2) + 2) * 2 = 108
        try testing.expectEqual(
            Testing.Component.A{ .value = 108 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

test "event DependOn events can have multiple dependencies" {
    const SystemStruct = struct {
        pub fn addStuff1(a: *Testing.Component.A) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += 1;
        }

        pub fn addStuff2(b: *Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            b.value += 1;
        }

        pub fn multiplyStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = CreateScheduler(StorageStub, .{Event("onFoo", .{
        SystemStruct.addStuff1,
        SystemStruct.addStuff2,
        DependOn(SystemStruct.multiplyStuff, .{ SystemStruct.addStuff1, SystemStruct.addStuff2 }),
    }, .{})}).init(&storage);
    defer scheduler.deinit();

    const entity_count = 100;
    var entities: [entity_count]Entity = undefined;

    const inital_state = AbEntityType{
        .a = .{ .value = 3 },
        .b = .{ .value = 2 },
    };
    for (&entities) |*entity| {
        entity.* = try storage.createEntity(inital_state);
    }

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities) |entity| {
        // (3 + 1) * (2 + 1) = 12
        // (12 + 1) * (3 + 1) = 52
        try testing.expectEqual(
            Testing.Component.A{ .value = 52 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Dispatcher does not include new components to systems previously triggered" {
    const Tracker = struct {
        count: u32,
    };

    const onFooSystem = struct {
        pub fn system(a: *Testing.Component.A, tracker: *SharedState(Tracker)) void {
            tracker.count += a.value;
        }
    }.system;

    const RepStorage = CreateStorage(Testing.AllComponentsTuple, .{Tracker});
    const Dispatcher = CreateScheduler(RepStorage, .{Event("onFoo", .{onFooSystem}, .{})});

    var storage = try RepStorage.init(testing.allocator, .{Tracker{ .count = 0 }});
    defer storage.deinit();

    var scheduler = Dispatcher.init(&storage);
    defer scheduler.deinit();

    var a = Testing.Component.A{ .value = 1 };
    _ = try storage.createEntity(.{a});
    _ = try storage.createEntity(.{a});

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    _ = try storage.createEntity(.{a});
    _ = try storage.createEntity(.{a});

    scheduler.dispatchEvent(.onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    // at this point we expect tracker to have a count of:
    // t1: 1 + 1 = 2
    // t2: t1 + 1 + 1 + 1 + 1
    // = 6
    try testing.expectEqual(@as(u32, 6), storage.getSharedStateInnerType(Tracker).count);
}
