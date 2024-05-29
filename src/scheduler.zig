const std = @import("std");

const ztracy = @import("ztracy");

const ThreadPool = @import("StdThreadPool.zig");
const TracedStdThreadPool = @import("TracedStdThreadPool.zig");
const ResetEvent = std.Thread.ResetEvent;

const meta = @import("meta.zig");
const SystemMetadata = meta.SystemMetadata;

const Color = @import("misc.zig").Color;

pub const Config = struct {
    thread_count: ?u32 = null,
};

/// Allow the user to attach systems to a storage. The user can then trigger events on the scheduler to execute
/// the systems in a multithreaded environment
pub fn CreateScheduler(
    comptime Storage: type,
    comptime events: anytype,
) type {
    const event_count = meta.countAndVerifyEvents(events);

    // Store each individual WaitGroup
    const EventsInFlight = blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        inline for (&fields, events, 0..) |*field, event, i| {
            const default_value = [_]ResetEvent{.{}} ** event.system_count;
            var num_buf: [8:0]u8 = undefined;
            const name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
            num_buf[name.len] = 0;

            field.* = Type.StructField{
                .name = name[0.. :0],
                .type = [event.system_count]ResetEvent,
                .default_value = @ptrCast(&default_value),
                .is_comptime = false,
                .alignment = @alignOf([event.system_count]ResetEvent),
            };
        }

        break :blk @Type(Type{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
        } });
    };

    // Access the dependencies of a system [event_index][system_index] => array
    const DependencyRelations = blk: {
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        inline for (&fields, events, 0..) |*field, event, event_index| {
            var system_fields: [event.system_count]Type.StructField = undefined;
            inline for (&system_fields, 0..) |*system_field, system_index| {
                var num_buf: [8:0]u8 = undefined;
                const name = std.fmt.bufPrint(&num_buf, "{d}", .{system_index}) catch unreachable;
                num_buf[name.len] = 0;

                const default_value = event.systems_info.getDependencySubIndices(system_index);
                const field_type = @TypeOf(default_value);
                system_field.* = Type.StructField{
                    .name = name[0.. :0],
                    .type = field_type,
                    .default_value = @ptrCast(&default_value),
                    .is_comptime = true,
                    .alignment = @alignOf(field_type),
                };
            }

            var num_buf: [8:0]u8 = undefined;
            const name = std.fmt.bufPrint(&num_buf, "{d}", .{event_index}) catch unreachable;
            num_buf[name.len] = 0;

            // For each system in event, create an array of dependency indices
            const EventSystemDepField = @Type(Type{ .Struct = .{
                .layout = .Auto,
                .fields = &system_fields,
                .decls = &[0]Type.Declaration{},
                .is_tuple = true,
            } });
            const default_value = EventSystemDepField{};
            field.* = Type.StructField{
                .name = name[0.. :0],
                .type = EventSystemDepField,
                .default_value = @ptrCast(&default_value),
                .is_comptime = true,
                .alignment = @alignOf(EventSystemDepField),
            };
        }

        break :blk @Type(Type{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
        } });
    };

    const dependency_tracker: DependencyRelations = DependencyRelations{};

    return struct {
        const Scheduler = @This();

        pub const EventsEnum = meta.GenerateEventsEnum(event_count, events);

        thread_pool: *ThreadPool,
        events_in_flight: EventsInFlight,

        /// Initialized the system scheduler. User must make sure to call deinit
        pub fn init(pool_allocator: std.mem.Allocator, config: Config) !Scheduler {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.scheduler);
            defer zone.End();

            const thread_pool = try pool_allocator.create(ThreadPool);
            errdefer pool_allocator.destroy(thread_pool);

            try TracedStdThreadPool.init(thread_pool, .{
                .allocator = pool_allocator,
                .n_jobs = config.thread_count,
            });

            var events_in_flight = EventsInFlight{};
            inline for (0..event_count) |event_index| {
                for (&events_in_flight[event_index]) |*system_in_flight| {
                    system_in_flight.set();
                }
            }

            return Scheduler{
                .thread_pool = thread_pool,
                .events_in_flight = events_in_flight,
            };
        }

        pub fn deinit(self: *Scheduler) void {
            TracedStdThreadPool.deinit(self.thread_pool);
            const allocator = self.thread_pool.allocator;
            allocator.destroy(self.thread_pool);
        }

        /// Trigger an event asynchronously. The caller must make sure to call waitEvent with matching enum identifier
        /// Before relying on the result of a trigger.
        /// Parameters:
        ///     - event:            The event enum identifier. When registering an event on Wolrd creation a identifier is
        ///                         submitted.
        ///     - event_argument:   An event specific argument. Keep in mind that if you submit a pointer as argument data
        ///                         then the lifetime of the argument must ourlive the execution of the event.
        ///     - exclude_types:    A struct of component types to exclude from the event dispatch. Meaning entities with these
        ///                         components will be ignored even though they have all components listed in the arguments of the
        ///                         system
        ///
        /// Example:
        /// ```
        /// const Scheduler = ecez.CreateScheduler(Storage, .{ecez.Event("onMouse", .{onMouseSystem}, MouseArg)})
        /// // ... storage creation etc ...
        /// // trigger mouse handle, exclude any entity with the RatComponent from this event
        /// scheduler.dispatchEvent(&storage, .onMouse, @as(MouseArg, mouse), .{RatComponent});
        /// ```
        pub fn dispatchEvent(self: *Scheduler, storage: *Storage, comptime event: EventsEnum, event_argument: anytype, comptime exclude_types: anytype) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("dispatchEvent {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.scheduler);
            defer zone.End();

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("event exclude types must be a tuple of types");
            }

            const exclude_type_arr = comptime exclude_type_extract_blk: {
                var type_arr: [exclude_type_info.Struct.fields.len]type = undefined;
                for (&type_arr, exclude_type_info.Struct.fields, 0..) |*exclude_type, field, index| {
                    if (field.type != type) {
                        @compileError("event include types field " ++ field.name ++ "must be a component type, was " ++ @typeName(field.type));
                    }

                    exclude_type.* = exclude_types[index];
                }
                break :exclude_type_extract_blk type_arr;
            };
            const exclude_bitmask = comptime include_bit_blk: {
                var bitmask: Storage.ComponentMask.Bits = 0;
                for (exclude_type_arr) |Component| {
                    bitmask |= 1 << Storage.Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };

            const event_index = @intFromEnum(event);
            const event_in_flight = &self.events_in_flight[event_index];
            const triggered_event = events[event_index];
            const event_systems_dependencies = dependency_tracker[event_index];

            comptime meta.disallowEventArgAsComponent(triggered_event.EventArgument, &Storage.component_type_array);

            inline for (triggered_event.systems_info.metadata, 0..) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();

                // TODO: verify systems and arguments in type initialization
                // verify that argument order is matching the storage order
                comptime Storage.validateComponentOrderAndValidity(component_query_types);

                const include_bitmask = include_bits_blk: {
                    comptime var bitmask = 0;
                    inline for (component_query_types) |Component| {
                        bitmask |= 1 << Storage.Container.componentIndex(Component);
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
                    @TypeOf(event_argument),
                );

                // initialized the system job
                const system_job = DispatchJob{
                    .storage = storage,
                    .event_argument = event_argument,
                };

                // Assert current system is not executing
                std.debug.assert(event_in_flight[system_index].isSet());

                // NOTE: Work around compiler crash: dont use reference to empty structs
                const dependencies = comptime if (event_systems_dependencies[system_index].len == 0) [0]u32{} else event_systems_dependencies[system_index];

                TracedStdThreadPool.spawnRe(
                    self.thread_pool,
                    &dependencies,
                    event_in_flight,
                    &event_in_flight[system_index],
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

        fn EventDispatchJob(
            comptime func: *const anyopaque,
            comptime FuncType: type,
            comptime metadata: SystemMetadata,
            comptime include_bitmask: Storage.ComponentMask.Bits,
            comptime exclude_bitmask: Storage.ComponentMask.Bits,
            comptime component_query_types: []const type,
            comptime EventArgument: type,
        ) type {
            return struct {
                const DispatchJob = @This();

                storage: *Storage,
                event_argument: EventArgument,

                pub fn exec(self_job: DispatchJob) void {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();

                    if (metadata == .flush_storage_edit_queue) {
                        // if this is a debug build we do not want inline (to get better error messages), otherwise inline systems for performance
                        const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .always_inline;

                        const system_ptr: FuncType = @ptrCast(func);
                        @call(system_call_modidifer, system_ptr.*, .{self_job.storage});

                        return;
                    }

                    const param_types = comptime metadata.paramArgTypes();
                    var arguments: std.meta.Tuple(param_types) = undefined;

                    var storage_buffer: [component_query_types.len][]u8 = undefined;
                    var storage = Storage.OpaqueArchetype.StorageData{
                        .inner_len = undefined,
                        .outer = &storage_buffer,
                    };

                    var system_invocation_count = comptime if (metadata.hasInvocationCount()) meta.InvocationCount{ .number = 0 } else {};
                    var tree_cursor = Storage.Container.BinaryTree.IterCursor.fromRoot();
                    tree_iter_loop: while (self_job.storage.container.tree.iterate(
                        include_bitmask,
                        exclude_bitmask,
                        &tree_cursor,
                    )) |archetype_index| {
                        self_job.storage.container.archetypes.items[archetype_index].getStorageData(&storage, include_bitmask);

                        const entities = self_job.storage.container.archetypes.items[archetype_index].entities.keys();
                        for (0..storage.inner_len) |inner_index| {
                            defer {
                                if (comptime metadata.hasInvocationCount()) system_invocation_count.number += 1;
                            }

                            inline for (
                                param_types,
                                comptime metadata.paramCategories(),
                                0..,
                            ) |
                                Param,
                                param_category,
                                nth_argument,
                            | {
                                switch (param_category) {
                                    .component_value => {
                                        // get size of the parameter type
                                        const param_size = @sizeOf(Param);
                                        if (param_size > 0) {
                                            const component_index = comptime if (metadata.hasEntityArgument()) nth_argument - 1 else nth_argument;

                                            const from = inner_index * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[component_index][from..to];
                                            arguments[nth_argument] = @as(*Param, @ptrCast(@alignCast(bytes))).*;
                                        }
                                    },
                                    .component_ptr => {
                                        const component_index = comptime if (metadata.hasEntityArgument()) nth_argument - 1 else nth_argument;
                                        const CompQueryType = component_query_types[component_index];

                                        // get size of the pointer child type (Param == *CompQueryType)
                                        const param_size = @sizeOf(CompQueryType);
                                        if (param_size > 0) {
                                            const from = inner_index * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[component_index][from..to];
                                            arguments[nth_argument] = @as(*CompQueryType, @ptrCast(@alignCast(bytes)));
                                        }
                                    },
                                    .entity => arguments[nth_argument] = entities[inner_index],
                                    .query_ptr => {
                                        const Iter = @typeInfo(Param).Pointer.child;
                                        var iter = Iter.init(self_job.storage.container.archetypes.items, self_job.storage.container.tree);
                                        arguments[nth_argument] = &iter;
                                    },
                                    .invocation_number_value => arguments[nth_argument] = system_invocation_count,
                                    .event_argument => arguments[nth_argument] = self_job.event_argument,
                                    .storage_edit_queue => arguments[nth_argument] = &self_job.storage.storage_queue,
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
const DependOn = meta.DependOn;
const InvocationCount = meta.InvocationCount;

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AEntityType = Testing.Archetype.A;
const BEntityType = Testing.Archetype.B;
const AbEntityType = Testing.Archetype.AB;
const AcEntityType = Testing.Archetype.AC;
const BcEntityType = Testing.Archetype.BC;
const AbcEntityType = Testing.Archetype.ABC;

const StorageStub = CreateStorage(Testing.AllComponentsTuple);

test "event can have no entities or even archetype to work with" {
    const SystemStruct = struct {
        pub fn mutateStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value += @as(u32, @intCast(b.value));
        }
    };
    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);
}

test "event can mutate components" {
    const SystemStruct = struct {
        pub fn mutateStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value += @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(
        StorageStub,
        .{Event("onFoo", .{SystemStruct}, .{})},
    ).init(testing.allocator, .{});
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

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{ Testing.Component.B, Testing.Component.C });
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

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{Testing.Component.B});
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

test "DependOn support structs" {
    const SystemStruct1 = struct {
        pub fn func1(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn func2(a: *Testing.Component.B) void {
            a.value += 1;
        }
    };

    const SystemStruct2 = struct {
        pub fn func3(a: *Testing.Component.A) void {
            a.value *= 2;
        }

        pub fn func4(a: *Testing.Component.B) void {
            a.value *= 2;
        }
    };

    const SystemStruct3 = struct {
        pub fn func5(a: *Testing.Component.A) void {
            a.value += 1;
        }

        pub fn func6(a: *Testing.Component.B) void {
            a.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{
        Event("onFoo", .{
            SystemStruct1,
            DependOn(SystemStruct2, .{SystemStruct1}),
            DependOn(SystemStruct3, .{SystemStruct2}),
        }, .{}),
    }).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = Testing.Archetype.AB{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    var entities: [1]Entity = undefined;
    for (&entities) |*entity| {
        entity.* = try storage.createEntity(initial_state);
    }

    // ((0 + 1) * 2) + 1 = 3
    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    // ((3 + 1) * 2) + 1 = 9
    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    // ((9 + 1) * 2) + 1 = 21
    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    // ((21 + 1) * 2) + 1 = 45
    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    const expected_value = 45;
    for (entities) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = expected_value },
            try storage.getComponent(entity, Testing.Component.A),
        );
        try testing.expectEqual(
            Testing.Component.B{ .value = expected_value },
            try storage.getComponent(entity, Testing.Component.B),
        );
    }
}

// https://github.com/Avokadoen/ecez/issues/162
// test "events can be registered through struct or individual function(s)" {
//     const SystemStruct1 = struct {
//         pub fn func1(a: *Testing.Component.A) void {
//             a.value += 1;
//         }

//         pub fn func2(a: *Testing.Component.A) void {
//             a.value += 1;
//         }
//     };

//     const SystemStruct2 = struct {
//         pub fn func3(a: *Testing.Component.B) void {
//             a.value += 1;
//         }
//     };

//     var storage = try StorageStub.init(testing.allocator);
//     defer storage.deinit();

//     var scheduler = try CreateScheduler(StorageStub, .{
//         Event("onFoo", .{
//             SystemStruct1.func1,
//             DependOn(SystemStruct1.func2, .{SystemStruct1.func1}),
//             SystemStruct2,
//         }, .{}),
//     }).init(std.testing.allocator, .{});
//     defer scheduler.deinit();

//     const initial_state = Testing.Archetype.AB{
//         .a = Testing.Component.A{ .value = 0 },
//         .b = Testing.Component.B{ .value = 0 },
//     };
//     const entity = try storage.createEntity(initial_state);

//     scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
//     scheduler.waitEvent(.onFoo);

//     try testing.expectEqual(
//         Testing.Component.A{ .value = 2 },
//         try storage.getComponent(entity, Testing.Component.A),
//     );
//     try testing.expectEqual(
//         Testing.Component.B{ .value = 1 },
//         try storage.getComponent(entity, Testing.Component.B),
//     );
// }

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

    const SystemThree = struct {
        pub fn func(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{
        Event("onFoo", .{SystemType}, .{}),
        Event("onBar", .{SystemThree}, .{}),
    }).init(std.testing.allocator, .{});
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

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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

    scheduler.dispatchEvent(&storage, .onBar, .{}, .{});
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

test "systems can access edit queue" {
    const A = Testing.Component.A;
    const B = Testing.Component.B;

    // define a system type
    const SystemType1 = struct {
        // foreach entity with A
        pub fn system(entity: Entity, a: A, edit_queue: *StorageStub.StorageEditQueue) void {
            // remove A
            edit_queue.queueRemoveComponent(entity, A) catch unreachable;
            // add B with a.value + 1
            edit_queue.queueSetComponent(entity, B{ .value = @intCast(a.value + 1) }) catch unreachable;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    const OnFooEvent = Event("onFoo", .{
        SystemType1,
        meta.FlushEditQueue(StorageStub),
    }, .{});
    var scheduler = try CreateScheduler(StorageStub, .{OnFooEvent}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var entities: [128]Entity = undefined;
    for (&entities, 0..) |*entity, index| {
        const initial_state = AEntityType{
            .a = A{ .value = @intCast(index) },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities, 0..) |entity, index| {
        try testing.expect(storage.hasComponent(entity, Testing.Component.A) == false);
        try testing.expectEqual(B{ .value = @intCast(index + 1) }, try storage.getComponent(entity, Testing.Component.B));
    }
}

test "systems can access current entity" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(entity: Entity, a: *Testing.Component.A) void {
            a.value += @as(u32, @intCast(entity.id));
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(
        StorageStub,
        .{Event("onFoo", .{SystemType}, .{})},
    ).init(testing.allocator, .{});
    defer scheduler.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

test "systems entity access remain correct after single removeComponent" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(entity: Entity, a: *Testing.Component.A) void {
            a.value += @as(u32, @intCast(entity.id));
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemType}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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

test "systems can accepts event related data" {
    const MouseInput = struct {
        x: u32,
        y: u32,
    };
    // define a system type
    const SystemType = struct {
        pub fn systemOne(a: *Testing.Component.A, mouse: MouseInput) void {
            a.value = mouse.x + mouse.y;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemType}, MouseInput)}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = .{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, MouseInput{ .x = 40, .y = 2 }, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event can mutate event extra argument" {
    const MouseEvent = struct {
        value: u32,
    };
    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A, mouse_event: *MouseEvent) void {
            mouse_event.value = a.value;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, MouseEvent)}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    _ = try storage.createEntity(initial_state);

    var mouse_event = MouseEvent{ .value = 0 };

    // make sure test is not modified in an illegal manner
    try testing.expect(initial_state.a.value != mouse_event.value);

    scheduler.dispatchEvent(&storage, .onFoo, &mouse_event, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(initial_state.a.value, mouse_event.value);
}

test "event can request single query with component" {
    const QueryA = StorageStub.Query(
        struct { a: Testing.Component.A },
        .{},
    ).Iter;

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

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
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

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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
    const QueryAMut = StorageStub.Query(
        struct { a: *Testing.Component.A },
        .{},
    ).Iter;

    const QueryAConst = StorageStub.Query(
        struct { a: Testing.Component.A },
        .{},
    ).Iter;

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

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    const entity = try storage.createEntity(initial_state);

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = pass_value },
        try storage.getComponent(entity, Testing.Component.A),
    );
}

test "event can access invocation number" {
    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A, invocation_number: InvocationCount) void {
            a.value = @intCast(invocation_number.number);
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    var entities: [100]Entity = undefined;
    for (&entities) |*entity| {
        const initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 0 },
        };
        entity.* = try storage.createEntity(initial_state);
    }

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    for (entities, 0..) |entity, index| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @intCast(index) },
            try storage.getComponent(entity, Testing.Component.A),
        );
    }
}

// NOTE: we don't use a cache anymore, but the test can stay for now since it might be good for
//       detecting potential regressions
test "event caching works" {
    const System1 = struct {
        pub fn system(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };
    const System2 = struct {
        pub fn system(b: *Testing.Component.B) void {
            b.value += 1;
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{
        Event("onEvent1", .{System1}, .{}),
        Event("onEvent2", .{System2}, .{}),
    }).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const entity1 = blk: {
        const initial_state = AEntityType{
            .a = .{ .value = 0 },
        };
        break :blk try storage.createEntity(initial_state);
    };

    scheduler.dispatchEvent(&storage, .onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 1 }, try storage.getComponent(
        entity1,
        Testing.Component.A,
    ));

    // move entity to archetype A, B
    try storage.setComponent(entity1, Testing.Component.B{ .value = 0 });

    scheduler.dispatchEvent(&storage, .onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 2 }, try storage.getComponent(
        entity1,
        Testing.Component.A,
    ));

    scheduler.dispatchEvent(&storage, .onEvent2, .{}, .{});
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

    scheduler.dispatchEvent(&storage, .onEvent1, .{}, .{});
    scheduler.waitEvent(.onEvent1);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try storage.getComponent(entity2, Testing.Component.A),
    );

    scheduler.dispatchEvent(&storage, .onEvent2, .{}, .{});
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

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{SystemStruct}, .{})}).init(std.testing.allocator, .{});
    defer scheduler.deinit();

    for (0..100) |_| {
        scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
        scheduler.waitEvent(.onFoo);
    }
}

test "DependOn makes a events race free" {
    const AddSystem1 = struct {
        pub fn system(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 3);
            a.value += @as(u32, @intCast(b.value));
        }
    };

    const MultiplySystem2 = struct {
        pub fn system(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 2);
            a.value *= @as(u32, @intCast(b.value));
        }
    };

    const AddSystem3 = struct {
        pub fn system(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += @as(u32, @intCast(b.value));
        }
    };

    const MultiplySystem4 = struct {
        pub fn system(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{
        Event("onEvent", .{
            AddSystem1,
            DependOn(MultiplySystem2, .{AddSystem1}),
            DependOn(AddSystem3, .{MultiplySystem2}),
            DependOn(MultiplySystem4, .{AddSystem3}),
        }, .{}),
    }).init(std.testing.allocator, .{});
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

    scheduler.dispatchEvent(&storage, .onEvent, .{}, .{});
    scheduler.waitEvent(.onEvent);

    scheduler.dispatchEvent(&storage, .onEvent, .{}, .{});
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
    const AddSystem1 = struct {
        pub fn system(a: *Testing.Component.A) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += 1;
        }
    };

    const AddSystem2 = struct {
        pub fn system(b: *Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            b.value += 1;
        }
    };

    const MultiplySystem3 = struct {
        pub fn system(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @as(u32, @intCast(b.value));
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(StorageStub, .{Event("onFoo", .{
        AddSystem1,
        AddSystem2,
        DependOn(MultiplySystem3, .{ AddSystem1, AddSystem2 }),
    }, .{})}).init(std.testing.allocator, .{});
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

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
    scheduler.waitEvent(.onFoo);

    scheduler.dispatchEvent(&storage, .onFoo, .{}, .{});
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

    const OnFooSystem = struct {
        pub fn system(a: *Testing.Component.A, tracker: *Tracker) void {
            tracker.count += a.value;
        }
    };

    const RepStorage = CreateStorage(Testing.AllComponentsTuple);
    const Scheduler = CreateScheduler(RepStorage, .{Event("onFoo", .{OnFooSystem}, Tracker)});

    var storage = try RepStorage.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();

    const inital_state = AEntityType{
        .a = .{ .value = 1 },
    };
    _ = try storage.createEntity(inital_state);
    _ = try storage.createEntity(inital_state);

    var tracker = Tracker{ .count = 0 };

    scheduler.dispatchEvent(&storage, .onFoo, &tracker, .{});
    scheduler.waitEvent(.onFoo);

    _ = try storage.createEntity(inital_state);
    _ = try storage.createEntity(inital_state);

    scheduler.dispatchEvent(&storage, .onFoo, &tracker, .{});
    scheduler.waitEvent(.onFoo);

    // at this point we expect tracker to have a count of:
    // t1: 1 + 1 = 2
    // t2: t1 + 1 + 1 + 1 + 1
    // = 6
    try testing.expectEqual(@as(u32, 6), tracker.count);
}
