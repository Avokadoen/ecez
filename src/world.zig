const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ztracy = @import("ztracy");
const zjobs = @import("zjobs");
const JobQueue = zjobs.JobQueue(.{});
const JobId = zjobs.JobId;

const meta = @import("meta.zig");
const archetype_container = @import("archetype_container.zig");
const opaque_archetype = @import("opaque_archetype.zig");

const ecez_error = @import("error.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const Color = @import("misc.zig").Color;
const SystemMetadata = meta.SystemMetadata;

const query = @import("query.zig");
const iterator = @import("iterator.zig");

const Testing = @import("Testing.zig");

/// Create an event which can be triggered and dispatch associated systems
/// Parameters:
///     - event_name: the name of the event
///     - systems: the systems that should be dispatched if this event is triggered
pub const Event = meta.Event;

/// Mark system arguments as shared state
pub const SharedState = meta.SharedState;
pub const EventArgument = meta.EventArgument;
pub const DependOn = meta.DependOn;

/// Create a ecs instance by gradually defining application types, systems and events.
pub fn WorldBuilder() type {
    return WorldIntermediate(.{}, .{}, .{});
}

// temporary type state for world
fn WorldIntermediate(comptime prev_components: anytype, comptime prev_shared_state: anytype, comptime prev_events: anytype) type {
    return struct {
        const Self = @This();

        /// define world components
        /// Parameters:
        ///     - components: structures of components that will used by the worls
        pub fn WithComponents(comptime components: anytype) type {
            return WorldIntermediate(components, prev_shared_state, prev_events);
        }

        /// define world shared state
        /// Parameters:
        ///     - shared_state: structures of shared state(s) that will used by systems
        pub fn WithSharedState(comptime shared_state: anytype) type {
            return WorldIntermediate(prev_components, shared_state, prev_events);
        }

        /// define world events that can be triggered programmatically
        ///     - events: a tuple of events created using the ecez.Event function
        pub fn WithEvents(comptime events: anytype) type {
            return WorldIntermediate(prev_components, prev_shared_state, events);
        }

        pub fn Build() type {
            return CreateWorld(prev_components, prev_shared_state, prev_events);
        }

        /// build the world instance which can be initialized
        pub fn init(allocator: Allocator, shared_state: anytype) error{OutOfMemory}!CreateWorld(prev_components, prev_shared_state, prev_events) {
            return CreateWorld(prev_components, prev_shared_state, prev_events).init(allocator, shared_state);
        }
    };
}

fn CreateWorld(
    comptime components: anytype,
    comptime shared_state_types: anytype,
    comptime events: anytype,
) type {
    @setEvalBranchQuota(10_000);
    const sorted_component_types = blk: {
        const components_info = @typeInfo(@TypeOf(components));
        if (components_info != .Struct) {
            @compileError("components was not a tuple of types");
        }
        var types: [components_info.Struct.fields.len]type = undefined;
        for (components_info.Struct.fields, 0..) |_, i| {
            types[i] = components[i];
            if (@typeInfo(types[i]) != .Struct) {
                @compileError("expected " ++ @typeName(types[i]) ++ " component type to be a struct");
            }
        }
        break :blk query.sortTypes(&types);
    };

    const ComponentMask = meta.BitMaskFromComponents(&sorted_component_types);
    const Container = archetype_container.FromComponents(&sorted_component_types, ComponentMask);
    const OpaqueArchetype = opaque_archetype.FromComponentMask(ComponentMask);
    const SharedStateStorage = meta.SharedStateStorage(shared_state_types);

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
        const World = @This();

        pub const EventsEnum = meta.GenerateEventsEnum(event_count, events);

        allocator: Allocator,
        container: Container,
        shared_state: SharedStateStorage,

        execution_job_queue: JobQueue,
        event_jobs_in_flight: EventJobsInFlight,

        /// intialize the world structure
        /// Parameters:
        ///     - allocator: allocator used when initiating entities
        ///     - shared_state: a tuple with an initial state for ALL shared state data declared when constructing world type
        pub fn init(allocator: Allocator, shared_state: anytype) error{OutOfMemory}!World {
            const zone = ztracy.ZoneNC(@src(), "World init", Color.world);
            defer zone.End();

            var actual_shared_state: SharedStateStorage = undefined;
            const shared_state_map = meta.typeMap(shared_state_types, @TypeOf(shared_state));
            inline for (shared_state_map, 0..) |index, i| {
                const shared_info = @typeInfo(@TypeOf(shared_state[index]));
                // copy all data except the added magic field
                inline for (shared_info.Struct.fields) |field| {
                    @field(actual_shared_state[i], field.name) = @field(shared_state[index], field.name);
                }
            }

            const container = try Container.init(allocator);
            errdefer container.deinit();

            var execution_job_queue = JobQueue.init();
            errdefer execution_job_queue.deinit();

            return World{
                .allocator = allocator,
                .container = container,
                .shared_state = actual_shared_state,
                .execution_job_queue = execution_job_queue,
                .event_jobs_in_flight = EventJobsInFlight{},
            };
        }

        pub fn deinit(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World deinit", Color.world);
            defer zone.End();

            self.execution_job_queue.deinit();
            self.container.deinit();
        }

        /// Clear world memory for reuse. All entities will become invalid.
        pub fn clearRetainingCapacity(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World clear", Color.world);
            defer zone.End();

            self.waitIdle();
            self.container.clearRetainingCapacity();
        }

        /// Create an entity and returns the entity handle
        /// Parameters:
        ///     - entity_state: the components that the new entity should be assigned
        pub fn createEntity(self: *World, entity_state: anytype) error{OutOfMemory}!Entity {
            const zone = ztracy.ZoneNC(@src(), "World createEntity", Color.world);
            defer zone.End();

            var create_result = try self.container.createEntity(entity_state);
            return create_result.entity;
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn setComponent(self: *World, entity: Entity, component: anytype) error{ EntityMissing, OutOfMemory }!void {
            const zone = ztracy.ZoneNC(@src(), "World setComponent", Color.world);
            defer zone.End();

            const new_archetype_created = try self.container.setComponent(entity, component);
            _ = new_archetype_created;
        }

        /// Remove a component owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn removeComponent(self: *World, entity: Entity, comptime Component: type) error{ EntityMissing, OutOfMemory }!void {
            const zone = ztracy.ZoneNC(@src(), "World removeComponent", Color.world);
            defer zone.End();
            const new_archetype_created = try self.container.removeComponent(entity, Component);
            _ = new_archetype_created;
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
        pub fn getComponent(self: *World, entity: Entity, comptime Component: type) error{ ComponentMissing, EntityMissing }!Component {
            const zone = ztracy.ZoneNC(@src(), "World getComponent", Color.world);
            defer zone.End();
            return self.container.getComponent(entity, Component);
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
        /// const World = WorldBuilder.WithEvents(.{Event("onMouse", .{onMouseSystem}, .{MouseArg})}
        /// // ... world creation etc ...
        /// world.triggerEvent(.onMouse, @as(MouseArg, mouse), .{RatComponent});
        /// ```
        pub fn triggerEvent(self: *World, comptime event: EventsEnum, event_extra_argument: anytype, comptime exclude_types: anytype) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("World trigger {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.world);
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
                    for (sorted_component_types) |Component| {
                        if (exclude_type.* == Component) {
                            type_is_component = true;
                            break;
                        }
                    }

                    if (type_is_component == false) {
                        @compileError("event include types field " ++ field.name ++ " is not a registered World component");
                    }
                }
                break :exclude_type_extract_blk type_arr;
            };
            const exclude_bitmask = comptime include_bit_blk: {
                var bitmask: ComponentMask.Bits = 0;
                inline for (exclude_type_arr) |Component| {
                    bitmask |= 1 << Container.componentIndex(Component);
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
                    for (sorted_component_types) |SortedComp| {
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
                        bitmask |= 1 << Container.componentIndex(SortedComp);
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
                    .world = self,
                    .extra_argument = event_extra_argument,
                };

                // TODO: should triggerEvent be synchronous? (move wait until the end of the dispatch function)
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
                        error.Uninitialized => unreachable, // schedule can fail on "Uninitialized" which does not happen since you must init world
                        error.Stopped => return,
                    }
                };
            }
        }

        /// Wait for all jobs from a triggerEvent to finish by blocking the calling thread
        /// should only be called from the triggerEvent thread
        pub fn waitEvent(self: *World, comptime event: EventsEnum) void {
            const tracy_zone_name = comptime std.fmt.comptimePrint("World wait event {s}", .{@tagName(event)});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.world);
            defer zone.End();

            for (self.event_jobs_in_flight[@intFromEnum(event)]) |job_in_flight| {
                self.execution_job_queue.wait(job_in_flight);
            }
        }

        /// Force the world to flush all current in flight jobs before continuing
        pub fn waitIdle(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World wait idle", Color.world);
            defer zone.End();

            inline for (0..events.len) |event_enum_int| {
                self.waitEvent(@enumFromInt(event_enum_int));
            }
        }

        /// get a shared state using the inner type
        pub fn getSharedStateInnerType(self: World, comptime InnerType: type) meta.SharedState(InnerType) {
            return self.getSharedStateWithOuterType(meta.SharedState(InnerType));
        }

        /// get a shared state using ecez.SharedState(InnerType) retrieve it's current value
        pub fn getSharedStateWithOuterType(self: World, comptime T: type) T {
            const index = indexOfSharedType(T);
            return self.shared_state[index];
        }

        /// set a shared state using the shared state's inner type
        pub fn setSharedState(self: *World, state: anytype) void {
            const ActualType = meta.SharedState(@TypeOf(state));
            const index = indexOfSharedType(ActualType);
            self.shared_state[index] = @as(*const ActualType, @ptrCast(&state)).*;
        }

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

        pub const EntityQuery = enum {
            exclude_entity,
            include_entity,
        };
        /// Query components which can be iterated upon.
        /// Parameters:
        ///     - entity_query: wether to include the entity variable in the iterator item
        ///     - include_types: all the components you would like to iterate over with the specified field name that should map to the
        ///                      component type. (see IncludeType)
        ///     - exclude_types: all the components that should be excluded from the query result
        ///
        /// Example:
        /// ```
        /// var a_iter = World.Query(.exclude_entity, .{ world.include("a", A) }, .{B}).submit(world, std.testing.allocator);
        /// defer a_iter.deinit();
        ///
        /// while (a_iter.next()) |item| {
        ///    std.debug.print("{any}", .{item.a});
        /// }
        /// ```
        pub fn Query(comptime entity_query: EntityQuery, comptime include_types: anytype, comptime exclude_types: anytype) type {
            const include_type_info = @typeInfo(@TypeOf(include_types));
            if (include_type_info != .Struct) {
                @compileError("query include types must be a tuple of types");
            }

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }

            comptime var query_result_names: [include_type_info.Struct.fields.len][]const u8 = undefined;
            comptime var include_inner_type_arr: [include_type_info.Struct.fields.len]type = undefined;
            comptime var include_outer_type_arr: [include_type_info.Struct.fields.len]type = undefined;
            inline for (
                &query_result_names,
                &include_inner_type_arr,
                &include_outer_type_arr,
                include_types,
                0..,
            ) |*query_result_name, *inner_type, *outer_type, include_type, index| {
                if (@TypeOf(include_type) != query.IncludeType) {
                    const compile_error = std.fmt.comptimePrint(
                        "expected include type number {d} to be of type IncludeType, actual type was {any}",
                        .{ index, @TypeOf(include_type) },
                    );
                    @compileError(compile_error);
                }

                query_result_name.* = include_type.name;
                outer_type.* = include_type.type;
                inner_type.* = blk: {
                    const field_info = @typeInfo(include_type.type);
                    if (field_info != .Pointer) {
                        break :blk include_type.type;
                    }

                    break :blk field_info.Pointer.child;
                };

                var type_is_component = false;
                for (sorted_component_types) |Component| {
                    if (inner_type.* == Component) {
                        type_is_component = true;
                        break;
                    }
                }

                if (type_is_component == false) {
                    @compileError("query include types field " ++ include_type.name ++ " is not a registered World component");
                }
            }
            query_result_names = query.sortBasedOnTypes(&include_inner_type_arr, []const u8, &query_result_names);
            include_outer_type_arr = query.sortBasedOnTypes(&include_inner_type_arr, type, &include_outer_type_arr);
            include_inner_type_arr = query.sortTypes(&include_inner_type_arr);

            var exclude_type_arr: [exclude_type_info.Struct.fields.len]type = undefined;
            inline for (&exclude_type_arr, exclude_type_info.Struct.fields, 0..) |*exclude_type, field, index| {
                if (field.type != type) {
                    @compileError("query include types field " ++ field.name ++ "must be a component type, was " ++ @typeName(field.type));
                }

                exclude_type.* = exclude_types[index];

                var type_is_component = false;
                for (sorted_component_types) |Component| {
                    if (exclude_type.* == Component) {
                        type_is_component = true;
                        break;
                    }
                }

                if (type_is_component == false) {
                    @compileError("query include types field " ++ field.name ++ " is not a registered World component");
                }
            }

            const include_bitmask = comptime include_bit_blk: {
                var bitmask: ComponentMask.Bits = 0;
                inline for (include_inner_type_arr) |Component| {
                    bitmask |= 1 << Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };
            const exclude_bitmask = comptime include_bit_blk: {
                var bitmask: ComponentMask.Bits = 0;
                inline for (exclude_type_arr) |Component| {
                    bitmask |= 1 << Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };

            inline for (include_inner_type_arr) |IncType| {
                inline for (exclude_type_arr) |ExType| {
                    if (IncType == ExType) {
                        // illegal query, you are doing something wrong :)
                        @compileError(@typeName(IncType) ++ " is used as an include type, and as a exclude type");
                    }
                }
            }

            const IterType = iterator.FromTypes(
                entity_query == .include_entity,
                &query_result_names,
                &include_outer_type_arr,
                include_bitmask,
                exclude_bitmask,
                OpaqueArchetype,
                Container.BinaryTree,
            );

            return struct {
                pub const Iter = IterType;

                pub fn submit(world: World) Iter {
                    const zone = ztracy.ZoneNC(@src(), "Query submit", Color.world);
                    defer zone.End();

                    return Iter.init(world.container.archetypes.items, world.container.tree);
                }
            };
        }

        fn indexOfSharedType(comptime Shared: type) comptime_int {
            const shared_storage_fields = @typeInfo(SharedStateStorage).Struct.fields;
            inline for (shared_storage_fields, 0..) |field, i| {
                if (field.type == Shared) {
                    return i;
                }
            }
            @compileError(@typeName(Shared) ++ " is not a shared state");
        }

        fn EventDispatchJob(
            comptime func: *const anyopaque,
            comptime FuncType: type,
            comptime metadata: SystemMetadata,
            comptime include_bitmask: ComponentMask.Bits,
            comptime exclude_bitmask: ComponentMask.Bits,
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
                world: *World,
                extra_argument: ExtraArgumentType,

                pub fn exec(self_job: *@This()) void {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.world);
                    defer zone.End();

                    const param_types = comptime metadata.paramArgTypes();
                    var arguments: std.meta.Tuple(param_types) = undefined;

                    var storage_buffer: [component_query_types.len][]u8 = undefined;
                    var storage = OpaqueArchetype.StorageData{
                        .inner_len = undefined,
                        .outer = &storage_buffer,
                    };

                    var tree_cursor = Container.BinaryTree.IterCursor.fromRoot();
                    while (self_job.world.container.tree.iterate(
                        include_bitmask,
                        exclude_bitmask,
                        &tree_cursor,
                    )) |archetype_index| {
                        self_job.world.container.archetypes.items[archetype_index].getStorageData(&storage, include_bitmask);

                        const entities = self_job.world.container.archetypes.items[archetype_index].entities.keys();
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
                                    .event_argument_value => arguments[j] = @as(*meta.EventArgument(ExtraArgumentType), @ptrCast(&self_job.extra_argument)).*,
                                    .event_argument_ptr => arguments[j] = @as(*meta.EventArgument(extra_argument_child_type), @ptrCast(self_job.extra_argument)),
                                    .shared_state_value => arguments[j] = self_job.world.getSharedStateWithOuterType(Param),
                                    .shared_state_ptr => arguments[j] = self_job.world.getSharedStatePtrWithSharedStateType(Param),
                                }
                            }

                            // if this is a debug build we do not want inline (to get better error messages), otherwise inline systems for performance
                            const system_call_modidifer: std.builtin.CallModifier = if (@import("builtin").mode == .Debug) .never_inline else .always_inline;

                            const system_ptr: FuncType = @ptrCast(func);
                            @call(system_call_modidifer, system_ptr.*, arguments);
                        }
                    }
                }
            };
        }
    };
}

// world without systems
const WorldStub = WorldBuilder().WithComponents(Testing.AllComponentsTuple);

// TODO: we cant use tuples here becuase of https://github.com/ziglang/zig/issues/12963
//       when this is resolve, the git history can be checked on how you should initialize an entity
const AEntityType = struct {
    a: Testing.Component.A,
};
const BEntityType = struct {
    b: Testing.Component.B,
};
const AbEntityType = struct {
    a: Testing.Component.A,
    b: Testing.Component.B,
};
const AcEntityType = struct {
    a: Testing.Component.A,
    c: Testing.Component.C,
};
const BcEntityType = struct {
    b: Testing.Component.B,
    c: Testing.Component.C,
};
const AbcEntityType = struct {
    a: Testing.Component.A,
    b: Testing.Component.B,
    c: Testing.Component.C,
};

test "init() + deinit() is idempotent" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity0 = try world.createEntity(initial_state);
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try world.createEntity(initial_state);
    try testing.expectEqual(entity1.id, 1);
}

test "createEntity() can create empty entities" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(.{});
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.A));

    const a = Testing.Component.A{ .value = 123 };
    {
        try world.setComponent(entity, a);
        try testing.expectEqual(a.value, (try world.getComponent(entity, Testing.Component.A)).value);
    }

    const b = Testing.Component.B{ .value = 8 };
    {
        try world.setComponent(entity, b);
        try testing.expectEqual(b.value, (try world.getComponent(entity, Testing.Component.B)).value);
        try testing.expectEqual(a.value, (try world.getComponent(entity, Testing.Component.A)).value);
    }
}

test "setComponent() component moves entity to correct archetype" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity1 = blk: {
        const initial_state = AEntityType{
            .a = Testing.Component.A{},
        };
        break :blk try world.createEntity(initial_state);
    };

    const a = Testing.Component.A{ .value = 123 };
    try world.setComponent(entity1, a);

    const b = Testing.Component.B{ .value = 42 };
    try world.setComponent(entity1, b);

    const stored_a = try world.getComponent(entity1, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
    const stored_b = try world.getComponent(entity1, Testing.Component.B);
    try testing.expectEqual(b, stored_b);

    try testing.expectEqual(@as(usize, 1), world.container.entity_references.items.len);
}

test "setComponent() update entities component state" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{},
        .b = Testing.Component.B{},
    };
    const entity = try world.createEntity(initial_state);

    const a = Testing.Component.A{ .value = 123 };
    try world.setComponent(entity, a);

    const stored_a = try world.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
}

test "setComponent() with empty component moves entity" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{},
        .b = Testing.Component.B{},
    };
    const entity = try world.createEntity(initial_state);

    const c = Testing.Component.C{};
    try world.setComponent(entity, c);

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.C));
}

test "removeComponent() removes the component as expected" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = BcEntityType{
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    };
    const entity = try world.createEntity(initial_state);

    try world.setComponent(entity, Testing.Component.A{});
    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.A));

    try world.removeComponent(entity, Testing.Component.A);
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.A));

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.B));

    try world.removeComponent(entity, Testing.Component.B);
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.B));
}

test "removeComponent() removes all components from entity" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity = try world.createEntity(initial_state);

    try world.removeComponent(entity, Testing.Component.A);
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.A));
}

test "hasComponent() responds as expected" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AcEntityType{
        .a = Testing.Component.A{},
        .c = Testing.Component.C{},
    };
    const entity = try world.createEntity(initial_state);

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.B));
}

test "getComponent() retrieve component value" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    var initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    _ = try world.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 1 };
    _ = try world.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 2 };
    _ = try world.createEntity(initial_state);

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    const entity = try world.createEntity(entity_initial_state);

    initial_state.a = Testing.Component.A{ .value = 3 };
    _ = try world.createEntity(initial_state);
    initial_state.a = Testing.Component.A{ .value = 4 };
    _ = try world.createEntity(initial_state);

    try testing.expectEqual(entity_initial_state.a, try world.getComponent(entity, Testing.Component.A));
}

test "getComponent() can mutate component value with ptr" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    const entity = try world.createEntity(initial_state);

    var a_ptr = try world.getComponent(entity, *Testing.Component.A);
    try testing.expectEqual(initial_state.a, a_ptr.*);

    const mutate_a_value = Testing.Component.A{ .value = 42 };

    // mutate a value ptr
    a_ptr.* = mutate_a_value;

    try testing.expectEqual(mutate_a_value, try world.getComponent(entity, Testing.Component.A));
}

test "clearRetainingCapacity() allow world reuse" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    var first_entity: Entity = undefined;

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    var entity: Entity = undefined;

    for (0..100) |i| {
        world.clearRetainingCapacity();

        var initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 0 },
        };
        _ = try world.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 1 };
        _ = try world.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 2 };
        _ = try world.createEntity(initial_state);

        if (i == 0) {
            first_entity = try world.createEntity(entity_initial_state);
        } else {
            entity = try world.createEntity(entity_initial_state);
        }

        initial_state.a = Testing.Component.A{ .value = 3 };
        _ = try world.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 4 };
        _ = try world.createEntity(initial_state);
    }

    try testing.expectEqual(first_entity, entity);
    const entity_a = try world.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(entity_initial_state.a, entity_a);
}

test "getSharedState retrieve state" {
    var world = try WorldStub.WithSharedState(.{ Testing.Component.A, Testing.Component.B }).init(testing.allocator, .{
        Testing.Component.A{ .value = 4 },
        Testing.Component.B{ .value = 2 },
    });
    defer world.deinit();

    try testing.expectEqual(@as(u32, 4), world.getSharedStateInnerType(Testing.Component.A).value);
    try testing.expectEqual(@as(u8, 2), world.getSharedStateInnerType(Testing.Component.B).value);
}

test "setSharedState retrieve state" {
    var world = try WorldStub.WithSharedState(.{ Testing.Component.A, Testing.Component.B }).init(testing.allocator, .{
        Testing.Component.A{ .value = 0 },
        Testing.Component.B{ .value = 0 },
    });
    defer world.deinit();

    const new_shared_a = Testing.Component.A{ .value = 42 };
    world.setSharedState(new_shared_a);

    try testing.expectEqual(
        new_shared_a,
        @as(*Testing.Component.A, @ptrCast(world.getSharedStatePtrWithSharedStateType(*meta.SharedState(Testing.Component.A)))).*,
    );
}

test "event can mutate components" {
    const SystemStruct = struct {
        pub fn mutateStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value += @as(u32, @intCast(b.value));
        }
    };

    var world = try WorldStub.WithEvents(.{Event("onFoo", .{SystemStruct}, .{})}).init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
    };
    const entity = try world.createEntity(initial_state);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "event parameter order is independent" {
    const SystemStruct = struct {
        pub fn mutateStuff(b: Testing.Component.B, c: Testing.Component.C, a: *Testing.Component.A) void {
            _ = c;
            a.value += @as(u32, @intCast(b.value));
        }
    };

    var world = try WorldStub.WithEvents(.{Event("onFoo", .{SystemStruct}, .{})}).init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AbcEntityType{
        .a = Testing.Component.A{ .value = 1 },
        .b = Testing.Component.B{ .value = 2 },
        .c = Testing.Component.C{},
    };
    const entity = try world.createEntity(initial_state);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "event exclude types exclude entities" {
    const SystemStruct = struct {
        pub fn mutateA(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var world = try WorldStub.WithEvents(.{Event("onFoo", .{SystemStruct}, .{})}).init(testing.allocator, .{});
    defer world.deinit();

    const a_entity = try world.createEntity(AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    });
    const ab_entity = try world.createEntity(AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{},
    });
    const ac_entity = try world.createEntity(AcEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .c = Testing.Component.C{},
    });
    const abc_entity = try world.createEntity(AbcEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    });

    world.triggerEvent(.onFoo, .{}, .{ Testing.Component.B, Testing.Component.C });
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(a_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try world.getComponent(ab_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try world.getComponent(ac_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try world.getComponent(abc_entity, Testing.Component.A),
    );

    world.triggerEvent(.onFoo, .{}, .{Testing.Component.B});
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try world.getComponent(a_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try world.getComponent(ab_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(ac_entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 0 },
        try world.getComponent(abc_entity, Testing.Component.A),
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

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{
            SystemStruct1.func1,
            DependOn(SystemStruct1.func2, .{SystemStruct1.func1}),
            SystemStruct2,
        }, .{}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = Testing.Archetype.AB{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try world.createEntity(initial_state);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try world.getComponent(entity, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try world.getComponent(entity, Testing.Component.B),
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

    const entity1 = blk: {
        const initial_state = AbEntityType{
            .a = Testing.Component.A{ .value = 0 },
            .b = Testing.Component.B{ .value = 0 },
        };
        break :blk try world.createEntity(initial_state);
    };

    const entity2 = blk: {
        const initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 2 },
        };
        break :blk try world.createEntity(initial_state);
    };

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

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

    world.triggerEvent(.onBar, .{}, .{});
    world.waitEvent(.onBar);

    try testing.expectEqual(
        Testing.Component.A{ .value = 2 },
        try world.getComponent(entity1, Testing.Component.A),
    );
    try testing.expectEqual(
        Testing.Component.A{ .value = 4 },
        try world.getComponent(entity2, Testing.Component.A),
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

    const shared_a = A{ .value = 42 };
    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).WithSharedState(.{A}).init(testing.allocator, .{shared_a});

    defer world.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    const entity = try world.createEntity(initial_state);
    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(shared_a, try world.getComponent(entity, A));
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

    const initial_state = AEntityType{
        .a = .{},
    };
    _ = try world.createEntity(initial_state);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(@as(u8, 2), world.shared_state[0].value);
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

    var world = try WorldStub.WithEvents(.{Event("onFoo", .{
        SystemStruct.system1,
        DependOn(SystemStruct.system2, .{SystemStruct.system1}),
        DependOn(SystemStruct.system3, .{SystemStruct.system2}),
        SystemStruct.system4,
        DependOn(SystemStruct.system5, .{SystemStruct.system4}),
        DependOn(SystemStruct.system6, .{SystemStruct.system5}),
    }, .{})}).WithSharedState(.{
        A, B, D,
    }).init(testing.allocator, .{
        A{ .value = 1 },
        B{ .value = 2 },
        D{ .value = 3 },
    });
    defer world.deinit();

    const initial_state_a = AEntityType{
        .a = .{ .value = 0 },
    };
    const entity_a = try world.createEntity(initial_state_a);
    const initial_state_b = BEntityType{
        .b = .{ .value = 0 },
    };
    const entity_b = try world.createEntity(initial_state_b);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(A{ .value = 6 }, try world.getComponent(entity_a, A));
    try testing.expectEqual(B{ .value = 12 }, try world.getComponent(entity_b, B));
}

test "events can access current entity" {
    // define a system type
    const SystemType = struct {
        pub fn systemOne(entity: Entity, a: *Testing.Component.A) void {
            a.value += @as(u32, @intCast(entity.id));
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try world.createEntity(initial_state);
    }

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    for (entities) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try world.getComponent(entity, Testing.Component.A),
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

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    var entities: [100]Entity = undefined;
    for (&entities, 0..) |*entity, iter| {
        const initial_state = AEntityType{
            .a = .{ .value = @as(u32, @intCast(iter)) },
        };
        entity.* = try world.createEntity(initial_state);
    }

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    for (entities[0..50]) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try world.getComponent(entity, Testing.Component.A),
        );
    }
    for (entities[51..100]) |entity| {
        try testing.expectEqual(
            Testing.Component.A{ .value = @as(u32, @intCast(entity.id)) * 2 },
            try world.getComponent(entity, Testing.Component.A),
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

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, MouseInput),
    }).init(testing.allocator, .{});

    defer world.deinit();

    const initial_state = AEntityType{
        .a = .{ .value = 0 },
    };
    const entity = try world.createEntity(initial_state);

    world.triggerEvent(.onFoo, MouseInput{ .x = 40, .y = 2 }, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "Event can mutate event extra argument" {
    const SystemStruct = struct {
        pub fn eventSystem(a: *Testing.Component.A, a_value: *EventArgument(Testing.Component.A)) void {
            a_value.value = a.value;
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemStruct.eventSystem}, .{Testing.Component.A}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 42 },
    };
    _ = try world.createEntity(initial_state);

    var event_a = Testing.Component.A{ .value = 0 };

    // make sure test is not modified in an illegal manner
    try testing.expect(initial_state.a.value != event_a.value);

    world.triggerEvent(.onFoo, &event_a, .{});
    world.waitEvent(.onFoo);

    try testing.expectEqual(initial_state.a, event_a);
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

    var world = try WorldStub.WithEvents(.{
        Event("onEvent1", .{SystemStruct.event1System}, .{}),
        Event("onEvent2", .{SystemStruct.event2System}, .{}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    const entity1 = blk: {
        const initial_state = AEntityType{
            .a = .{ .value = 0 },
        };
        break :blk try world.createEntity(initial_state);
    };

    world.triggerEvent(.onEvent1, .{}, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 1 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    // move entity to archetype A, B
    try world.setComponent(entity1, Testing.Component.B{ .value = 0 });
    world.triggerEvent(.onEvent1, .{}, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 2 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    world.triggerEvent(.onEvent2, .{}, .{});
    world.waitEvent(.onEvent2);

    try testing.expectEqual(Testing.Component.B{ .value = 1 }, try world.getComponent(
        entity1,
        Testing.Component.B,
    ));

    const entity2 = blk: {
        const initial_state = AbcEntityType{
            .a = .{ .value = 0 },
            .b = .{ .value = 0 },
            .c = .{},
        };
        break :blk try world.createEntity(initial_state);
    };

    world.triggerEvent(.onEvent1, .{}, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(entity2, Testing.Component.A),
    );

    world.triggerEvent(.onEvent2, .{}, .{});
    world.waitEvent(.onEvent2);

    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try world.getComponent(entity2, Testing.Component.B),
    );
}

test "Event with no archetypes does not crash" {
    const SystemStruct = struct {
        pub fn event1System(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var world = try WorldStub.WithEvents(.{
        Event("onEvent1", .{SystemStruct.event1System}, .{}),
    }).init(testing.allocator, .{});
    defer world.deinit();

    for (0..100) |_| {
        world.triggerEvent(.onEvent1, .{}, .{});
        world.waitEvent(.onEvent1);
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

    const World = WorldStub.WithEvents(.{
        Event("onEvent", .{
            SystemStruct.addStuff1,
            DependOn(SystemStruct.multiplyStuff1, .{SystemStruct.addStuff1}),
            DependOn(SystemStruct.addStuff2, .{SystemStruct.multiplyStuff1}),
            DependOn(SystemStruct.multiplyStuff2, .{SystemStruct.addStuff2}),
        }, .{}),
    }).Build();

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    const entity_count = 10_000;
    var entities: [entity_count]Entity = undefined;

    const inital_state = AbEntityType{
        .a = .{ .value = 3 },
        .b = .{ .value = 2 },
    };
    for (&entities) |*entity| {
        entity.* = try world.createEntity(inital_state);
    }

    world.triggerEvent(.onEvent, .{}, .{});
    world.waitEvent(.onEvent);

    world.triggerEvent(.onEvent, .{}, .{});
    world.waitEvent(.onEvent);

    for (entities) |entity| {
        // (((3  + 2) * 2) + 2) * 2 =  24
        // (((24 + 2) * 2) + 2) * 2 = 108
        try testing.expectEqual(
            Testing.Component.A{ .value = 108 },
            try world.getComponent(entity, Testing.Component.A),
        );
    }
}

test "Event DependOn events can have multiple dependencies" {
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

    const World = WorldStub.WithEvents(.{Event("onFoo", .{
        SystemStruct.addStuff1,
        SystemStruct.addStuff2,
        DependOn(SystemStruct.multiplyStuff, .{ SystemStruct.addStuff1, SystemStruct.addStuff2 }),
    }, .{})}).Build();

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    const entity_count = 100;
    var entities: [entity_count]Entity = undefined;

    const inital_state = AbEntityType{
        .a = .{ .value = 3 },
        .b = .{ .value = 2 },
    };
    for (&entities) |*entity| {
        entity.* = try world.createEntity(inital_state);
    }

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    for (entities) |entity| {
        // (3 + 1) * (2 + 1) = 12
        // (12 + 1) * (3 + 1) = 52
        try testing.expectEqual(
            Testing.Component.A{ .value = 52 },
            try world.getComponent(entity, Testing.Component.A),
        );
    }
}

test "query with single include type works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    for (0..100) |index| {
        _ = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = World.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(world);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with multiple include type works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    for (0..100) |index| {
        _ = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var a_b_iter = World.Query(.exclude_entity, .{
            query.include("a", Testing.Component.A),
            query.include("b", Testing.Component.B),
        }, .{}).submit(world);

        var index: usize = 0;
        while (a_b_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            try std.testing.expectEqual(Testing.Component.B{
                .value = @as(u8, @intCast(index)),
            }, item.b);

            index += 1;
        }
    }
}

test "query with single ptr include type works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    for (0..100) |index| {
        _ = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = World.Query(
            .exclude_entity,
            .{query.include("a_ptr", *Testing.Component.A)},
            .{},
        ).submit(world);

        while (a_iter.next()) |item| {
            item.a_ptr.value += 1;
            index += 1;
        }
    }

    {
        var index: usize = 1;
        var a_iter = World.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(world);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and single exclude works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    for (0..100) |index| {
        _ = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try world.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = World.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{Testing.Component.B},
        ).submit(world);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and multiple exclude works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    for (0..100) |index| {
        _ = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try world.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (200..300) |index| {
        _ = try world.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = World.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{ Testing.Component.B, Testing.Component.C },
        ).submit(world);

        var index: usize = 200;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with entity only works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try world.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = World.Query(
            .include_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(world);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            index += 1;
        }
    }
}

test "query with entity and include and exclude only works" {
    const World = WorldStub.Build();
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try world.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try world.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = World.Query(
            .include_entity,
            .{query.include("a", Testing.Component.A)},
            .{Testing.Component.B},
        ).submit(world);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);
            index += 1;
        }
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by adding additional components to entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepWorld = WorldBuilder().WithComponents(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata }).Build();

    var world = try RepWorld.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(.{});
    const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 0, .c = undefined };
    try world.setComponent(entity, obj);

    try testing.expectEqual(
        obj,
        try world.getComponent(entity, RenderContext.ObjectMetadata),
    );

    const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
    try world.setComponent(entity, instance);

    try testing.expectEqual(
        obj,
        try world.getComponent(entity, RenderContext.ObjectMetadata),
    );
    try testing.expectEqual(
        instance,
        try world.getComponent(entity, Editor.InstanceHandle),
    );
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by having more than one entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepWorld = WorldBuilder().WithComponents(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata }).Build();

    var world = try RepWorld.init(testing.allocator, .{});
    defer world.deinit();

    {
        const entity = try world.createEntity(.{});
        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 5, .c = undefined };
        try world.setComponent(entity, obj);
        const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
        try world.setComponent(entity, instance);

        const entity_obj = try world.getComponent(entity, RenderContext.ObjectMetadata);
        try testing.expectEqual(
            obj.a,
            entity_obj.a,
        );
        try testing.expectEqual(
            obj.b,
            entity_obj.b,
        );
        try testing.expectEqual(
            instance,
            try world.getComponent(entity, Editor.InstanceHandle),
        );
    }
    {
        const entity = try world.createEntity(.{});
        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 2, .c = undefined };
        try world.setComponent(entity, obj);
        const instance = Editor.InstanceHandle{ .a = 1, .b = 1, .c = 1 };
        try world.setComponent(entity, instance);

        const entity_obj = try world.getComponent(entity, RenderContext.ObjectMetadata);
        try testing.expectEqual(
            obj.a,
            entity_obj.a,
        );
        try testing.expectEqual(
            obj.b,
            entity_obj.b,
        );
        try testing.expectEqual(
            instance,
            try world.getComponent(entity, Editor.InstanceHandle),
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

    const RepWorld = WorldStub.WithEvents(
        .{Event("onFoo", .{onFooSystem}, .{})},
    ).WithSharedState(.{Tracker}).Build();

    var world = try RepWorld.init(testing.allocator, .{Tracker{ .count = 0 }});
    defer world.deinit();

    var a = Testing.Component.A{ .value = 1 };
    _ = try world.createEntity(.{a});
    _ = try world.createEntity(.{a});

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    _ = try world.createEntity(.{a});
    _ = try world.createEntity(.{a});

    world.triggerEvent(.onFoo, .{}, .{});
    world.waitEvent(.onFoo);

    // at this point we expect tracker to have a count of:
    // t1: 1 + 1 = 2
    // t2: t1 + 1 + 1 + 1 + 1
    // = 6
    try testing.expectEqual(@as(u32, 6), world.getSharedStateInnerType(Tracker).count);
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Removing component cause storage to become in invalid state for dispatch" {
    const InstanceHandle = packed struct {
        a: u16,
        b: u32,
        c: u16,
    };
    const Transform = struct {
        mat: [4]@Vector(4, f32),
    };
    const Position = struct {
        vec: @Vector(4, f32),
    };
    const Rotation = struct {
        quat: @Vector(4, f32),
    };
    const Scale = struct {
        vec: @Vector(4, f32),
    };
    const ObjectMetadata = struct {
        a: Entity,
        b: u8,
        c: [64]u8,
    };

    const RepWorld = WorldBuilder().WithComponents(.{
        ObjectMetadata,
        Transform,
        Position,
        Rotation,
        Scale,
        InstanceHandle,
    }).Build();

    var world = try RepWorld.init(testing.allocator, .{});
    defer world.deinit();

    var instance_handle = InstanceHandle{ .a = 3, .b = 3, .c = 3 };
    var transform = Transform{ .mat = .{
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
    } };
    var position = Position{ .vec = [4]f32{ 3, 3, 3, 3 } };
    var rotation = Rotation{ .quat = [4]f32{ 3, 3, 3, 3 } };
    var scale = Scale{ .vec = [4]f32{ 3, 3, 3, 3 } };
    var obj = ObjectMetadata{ .a = Entity{ .id = 3 }, .b = 3, .c = undefined };

    _ = try world.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });
    const entity = try world.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });
    _ = try world.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });

    try testing.expectEqual(instance_handle, try world.getComponent(entity, InstanceHandle));
    try testing.expectEqual(transform, try world.getComponent(entity, Transform));
    try testing.expectEqual(position, try world.getComponent(entity, Position));
    try testing.expectEqual(rotation, try world.getComponent(entity, Rotation));
    try testing.expectEqual(scale, try world.getComponent(entity, Scale));

    _ = try world.removeComponent(entity, Position);

    try testing.expectEqual(instance_handle, try world.getComponent(entity, InstanceHandle));
    try testing.expectEqual(transform, try world.getComponent(entity, Transform));
    try testing.expectEqual(rotation, try world.getComponent(entity, Rotation));
    try testing.expectEqual(scale, try world.getComponent(entity, Scale));
}
