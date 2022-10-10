const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ztracy = @import("ztracy");
const zjobs = @import("zjobs");
const JobQueue = zjobs.JobQueue(.{});
const JobId = zjobs.JobId;

const meta = @import("meta.zig");
const archetype_container = @import("archetype_container.zig");
const archetype_cache = @import("archetype_cache.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const Color = @import("misc.zig").Color;
const OpaqueArchetype = @import("OpaqueArchetype.zig");
const SystemMetadata = meta.SystemMetadata;

const query = @import("query.zig");
const Query = query.Query;
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
    return WorldIntermediate(.{}, .{}, .{}, .{});
}

// temporary type state for world
fn WorldIntermediate(comptime prev_components: anytype, comptime prev_shared_state: anytype, comptime prev_systems: anytype, comptime prev_events: anytype) type {
    return struct {
        const Self = @This();

        /// define application components
        /// Parameters:
        ///     - components: structures of components that will used by the application
        pub fn WithComponents(comptime components: anytype) type {
            return WorldIntermediate(components, prev_shared_state, prev_systems, prev_events);
        }

        /// define application shared state
        /// Parameters:
        ///     - archetypes: structures of archetypes that will used by the application
        pub fn WithSharedState(comptime shared_state: anytype) type {
            return WorldIntermediate(prev_components, shared_state, prev_systems, prev_events);
        }

        /// define application systems which should run on each dispatch
        /// Parameters:
        ///     - systems: a tuple of each system used by the world each frame
        pub fn WithSystems(comptime systems: anytype) type {
            return WorldIntermediate(prev_components, prev_shared_state, systems, prev_events);
        }

        /// define application events that can be triggered programmatically
        ///     - events: a tuple of events created using the ecez.Event function
        pub fn WithEvents(comptime events: anytype) type {
            return WorldIntermediate(prev_components, prev_shared_state, prev_systems, events);
        }

        pub fn Build() type {
            return CreateWorld(prev_components, prev_shared_state, prev_systems, prev_events);
        }

        /// build the world instance which can be initialized
        pub fn init(allocator: Allocator, shared_state: anytype) !CreateWorld(prev_components, prev_shared_state, prev_systems, prev_events) {
            return CreateWorld(prev_components, prev_shared_state, prev_systems, prev_events).init(allocator, shared_state);
        }
    };
}

fn CreateWorld(
    comptime components: anytype,
    comptime shared_state_types: anytype,
    comptime systems: anytype,
    comptime events: anytype,
) type {
    @setEvalBranchQuota(10_000);
    const component_types = blk: {
        const components_info = @typeInfo(@TypeOf(components));
        if (components_info != .Struct) {
            @compileError("components was not a tuple of types");
        }
        var types: [components_info.Struct.fields.len]type = undefined;
        for (components_info.Struct.fields) |_, i| {
            types[i] = components[i];
            if (@typeInfo(types[i]) != .Struct) {
                @compileError("expected " ++ @typeName(types[i]) ++ " component type to be a struct");
            }
        }
        break :blk types;
    };
    const Container = archetype_container.FromComponents(&component_types);

    const SharedStateStorage = meta.SharedStateStorage(shared_state_types);

    const system_count = meta.countAndVerifySystems(systems);
    const systems_info = meta.createSystemInfo(system_count, systems);
    const event_count = meta.countAndVerifyEvents(events);

    const CacheMask = archetype_cache.ArchetypeCacheMask(&components);
    const DispatchCacheStorage = archetype_cache.ArchetypeCacheStorage(system_count);
    const EventCacheStorages = blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (fields) |*field, i| {
            const event_system_count = events[i].system_count;
            const EventCacheStorage = archetype_cache.ArchetypeCacheStorage(event_system_count);

            var num_buf: [8]u8 = undefined;
            field.* = Type.StructField{
                .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                .field_type = EventCacheStorage,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(EventCacheStorage),
            };
        }

        break :blk @Type(Type{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &[0]Type.Declaration{},
            .is_tuple = true,
        } });
    };
    const EventJobsInFlight = blk: {
        // TODO: move to meta
        const Type = std.builtin.Type;
        var fields: [event_count]Type.StructField = undefined;
        for (fields) |*field, i| {
            const event_system_count = events[i].system_count;
            var num_buf: [8]u8 = undefined;
            field.* = Type.StructField{
                .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
                .field_type = [event_system_count]JobId,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf([event_system_count]JobId),
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

        // the dispatch cache used to store archetypes for each system
        dispatch_cache_mask: CacheMask,
        dispatch_cache_storage: DispatchCacheStorage,

        // the trigger event cache used to store archetypes for each system
        event_cache_masks: [event_count]CacheMask,
        event_cache_storages: EventCacheStorages,

        execution_job_queue: JobQueue,
        system_jobs_in_flight: [system_count]JobId,
        event_jobs_in_flight: EventJobsInFlight,

        // TODO: event jobs in flight

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

            var event_cache_masks: [event_count]CacheMask = undefined;
            for (event_cache_masks) |*mask| {
                mask.* = CacheMask.init();
            }

            var event_cache_storages: EventCacheStorages = undefined;
            {
                const event_cache_storages_info = @typeInfo(EventCacheStorages).Struct;
                inline for (event_cache_storages_info.fields) |field, i| {
                    event_cache_storages[i] = field.field_type.init();
                }
            }

            const container = try Container.init(allocator);
            errdefer container.deinit();

            var execution_job_queue = JobQueue.init();
            errdefer execution_job_queue.deinit();

            const system_jobs_in_flight = [_]JobId{JobId.none} ** system_count;

            var event_jobs_in_flight: EventJobsInFlight = undefined;
            {
                const event_jobs_in_flight_info = @typeInfo(EventJobsInFlight).Struct;
                inline for (event_jobs_in_flight_info.fields) |_, i| {
                    event_jobs_in_flight[i] = [_]JobId{JobId.none} ** events[i].system_count;
                }
            }

            return World{
                .allocator = allocator,
                .container = container,
                .shared_state = actual_shared_state,
                .dispatch_cache_mask = CacheMask.init(),
                .dispatch_cache_storage = DispatchCacheStorage.init(),
                .event_cache_masks = event_cache_masks,
                .event_cache_storages = event_cache_storages,
                .execution_job_queue = execution_job_queue,
                .system_jobs_in_flight = system_jobs_in_flight,
                .event_jobs_in_flight = event_jobs_in_flight,
            };
        }

        pub fn deinit(self: *World) void {
            const zone = ztracy.ZoneNC(@src(), "World deinit", Color.world);
            defer zone.End();

            self.execution_job_queue.deinit();

            self.dispatch_cache_storage.deinit(self.allocator);

            const event_cache_storages_info = @typeInfo(EventCacheStorages).Struct;
            inline for (event_cache_storages_info.fields) |_, i| {
                self.event_cache_storages[i].deinit(self.allocator);
            }

            self.container.deinit();
        }

        /// Create an entity and returns the entity handle
        /// Parameters:
        ///     - entity_state: the components that the new entity should be assigned
        pub fn createEntity(self: *World, entity_state: anytype) !Entity {
            const zone = ztracy.ZoneNC(@src(), "World createEntity", Color.world);
            defer zone.End();

            var entity: Entity = undefined;
            var new_archetype_created: bool = undefined;
            {
                var result = try self.container.createEntity(entity_state);
                entity = result[1];
                new_archetype_created = result[0];
            }
            if (new_archetype_created) {
                self.markAllCacheMasks(entity);
            }
            return entity;
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn setComponent(self: *World, entity: Entity, component: anytype) !void {
            const zone = ztracy.ZoneNC(@src(), "World setComponent", Color.world);
            defer zone.End();

            const new_archetype_created = try self.container.setComponent(entity, component);
            if (new_archetype_created) {
                self.markAllCacheMasks(entity);
            }
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn removeComponent(self: *World, entity: Entity, comptime Component: type) !void {
            const zone = ztracy.ZoneNC(@src(), "World removeComponent", Color.world);
            defer zone.End();
            const new_archetype_created = try self.container.removeComponent(entity, Component);
            if (new_archetype_created) {
                self.markAllCacheMasks(entity);
            }
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
        pub fn dispatch(self: *World) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), "World dispatch", Color.world);
            defer zone.End();

            // prime job execution for dispatch
            if (self.execution_job_queue.isStarted() == false) {
                self.execution_job_queue.start();
            }

            // at the end of the function all bits should be coherent
            defer self.dispatch_cache_mask.setAllCoherent();

            inline for (systems_info.metadata) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();

                const component_hashes: [component_query_types.len]u64 = comptime blk: {
                    var hashes: [component_query_types.len]u64 = undefined;
                    inline for (component_query_types) |T, i| {
                        hashes[i] = query.hashType(T);
                    }
                    break :blk hashes;
                };

                const DispatchJob = SystemDispatchJob(
                    systems_info.functions[system_index],
                    *const systems_info.function_types[system_index],
                    metadata,
                    &component_query_types,
                    &component_hashes,
                );

                // extract data relative to system for each relevant archetype
                const opaque_archetypes = blk: {
                    // if cache is invalid
                    if (self.dispatch_cache_mask.isCoherent(&component_query_types) == false) {
                        comptime var sorted_component_hashes: [component_query_types.len]u64 = undefined;
                        comptime {
                            std.mem.copy(u64, &sorted_component_hashes, &component_hashes);
                            const lessThan = struct {
                                fn cmp(context: void, lhs: u64, rhs: u64) bool {
                                    _ = context;
                                    return lhs < rhs;
                                }
                            }.cmp;
                            std.sort.sort(u64, &sorted_component_hashes, {}, lessThan);
                        }

                        // store new cache result
                        self.dispatch_cache_storage.assignCacheEntry(
                            self.allocator,
                            system_index,
                            try self.container.getArchetypesWithComponents(self.allocator, &sorted_component_hashes),
                        );
                    }

                    break :blk self.dispatch_cache_storage.cache[system_index];
                };

                // initialized the system job
                var system_job = DispatchJob{
                    .world = self,
                    .opaque_archetypes = opaque_archetypes,
                };

                // TODO: should dispatch be synchronous? (move wait until the end of the dispatch function)
                // wait for previous dispatch to finish
                self.execution_job_queue.wait(self.system_jobs_in_flight[system_index]);

                const dependency_job_indices = comptime getMetadataIndexRange(metadata);

                if (dependency_job_indices) |indices| {
                    var jobs: [indices.len]JobId = undefined;
                    for (indices) |index, i| {
                        jobs[i] = self.system_jobs_in_flight[index];
                    }

                    const combinded_job = self.execution_job_queue.combine(&jobs) catch JobId.none;
                    self.system_jobs_in_flight[system_index] = self.execution_job_queue.schedule(combinded_job, system_job) catch |err| {
                        switch (err) {
                            error.Uninitialized => unreachable, // schedule can fail on "Uninitialized" which does not happen since you must init world
                            error.Stopped => return,
                        }
                    };
                } else {
                    self.system_jobs_in_flight[system_index] = self.execution_job_queue.schedule(JobId.none, system_job) catch |err| {
                        switch (err) {
                            error.Uninitialized => unreachable, // schedule can fail on "Uninitialized" which does not happen since you must init world
                            error.Stopped => return,
                        }
                    };
                }
            }
        }

        /// Wait for all jobs from a dispatch to finish by blocking the calling thread
        /// should only be called from the dispatch thread
        pub fn waitDispatch(self: *World) void {
            for (self.system_jobs_in_flight) |job_in_flight| {
                self.execution_job_queue.wait(job_in_flight);
            }
        }

        pub fn triggerEvent(self: *World, comptime event: EventsEnum, event_extra_argument: anytype) error{OutOfMemory}!void {
            const tracy_zone_name = std.fmt.comptimePrint("World trigger {any}", .{event});
            const zone = ztracy.ZoneNC(@src(), tracy_zone_name, Color.world);
            defer zone.End();

            // prime job execution for dispatch
            if (self.execution_job_queue.isStarted() == false) {
                self.execution_job_queue.start();
            }

            var event_cache_mask = &self.event_cache_masks[@enumToInt(event)];
            var event_jobs_in_flight = &self.event_jobs_in_flight[@enumToInt(event)];

            // at the end of the function all bits should be coherent
            defer event_cache_mask.setAllCoherent();
            const triggered_event = events[@enumToInt(event)];

            // TODO: verify systems and arguments in type initialization
            const EventExtraArgument = @TypeOf(event_extra_argument);
            if (@sizeOf(triggered_event.EventArgument) > 0) {
                if (comptime meta.isEventArgument(EventExtraArgument)) {
                    @compileError("event arguments should not be wrapped in EventArgument type when triggering an event");
                }
                if (EventExtraArgument != triggered_event.EventArgument) {
                    @compileError("event " ++ @tagName(event) ++ " was declared to accept " ++ @typeName(triggered_event.EventArgument) ++ " got " ++ @typeName(EventExtraArgument));
                }
            }

            inline for (triggered_event.systems_info.metadata) |metadata, system_index| {
                const component_query_types = comptime metadata.componentQueryArgTypes();

                const component_hashes: [component_query_types.len]u64 = comptime blk: {
                    var hashes: [component_query_types.len]u64 = undefined;
                    inline for (component_query_types) |T, i| {
                        hashes[i] = query.hashType(T);
                    }
                    break :blk hashes;
                };

                const DispatchJob = EventDispatchJob(
                    triggered_event.systems_info.functions[system_index],
                    *const triggered_event.systems_info.function_types[system_index],
                    metadata,
                    &component_query_types,
                    &component_hashes,
                    @TypeOf(event_extra_argument),
                );

                // extract data relative to system for each relevant archetype
                const opaque_archetypes = blk: {
                    var event_cache_storage = &self.event_cache_storages[@enumToInt(event)];
                    // if the cache is no longer valid
                    if (event_cache_mask.isCoherent(&component_query_types) == false) {
                        comptime var sorted_component_hashes: [component_query_types.len]u64 = undefined;
                        comptime {
                            std.mem.copy(u64, &sorted_component_hashes, &component_hashes);
                            const lessThan = struct {
                                fn cmp(context: void, lhs: u64, rhs: u64) bool {
                                    _ = context;
                                    return lhs < rhs;
                                }
                            }.cmp;
                            std.sort.sort(u64, &sorted_component_hashes, {}, lessThan);
                        }

                        // update the stored cache
                        event_cache_storage.assignCacheEntry(
                            self.allocator,
                            system_index,
                            try self.container.getArchetypesWithComponents(self.allocator, &sorted_component_hashes),
                        );
                    }

                    break :blk event_cache_storage.cache[system_index];
                };

                // initialized the system job
                var system_job = DispatchJob{
                    .world = self,
                    .opaque_archetypes = opaque_archetypes,
                    .extra_argument = event_extra_argument,
                };

                // TODO: should triggerEvent be synchronous? (move wait until the end of the dispatch function)
                // wait for previous dispatch to finish
                self.execution_job_queue.wait(event_jobs_in_flight[system_index]);

                event_jobs_in_flight[system_index] = self.execution_job_queue.schedule(zjobs.JobId.none, system_job) catch |err| {
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
            for (self.event_jobs_in_flight[@enumToInt(event)]) |job_in_flight| {
                self.execution_job_queue.wait(job_in_flight);
            }
        }

        /// get a shared state using the inner type
        pub fn getSharedState(self: *World, comptime T: type) meta.SharedState(T) {
            return self.getSharedStateWithSharedStateType(meta.SharedState(T));
        }

        /// get a shared state using ecez.SharedState(InnerType) retrieve it's current value
        pub fn getSharedStateWithSharedStateType(self: *World, comptime T: type) T {
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

        inline fn markAllCacheMasks(self: *World, entity: Entity) void {
            if (self.container.getTypeHashes(entity)) |type_hashes| {
                self.dispatch_cache_mask.setIncoherentBitWithTypeHashes(type_hashes);

                for (self.event_cache_masks) |*mask| {
                    mask.setIncoherentBitWithTypeHashes(type_hashes);
                }
            }
        }

        fn SystemDispatchJob(
            func: *const anyopaque,
            comptime FuncType: type,
            comptime metadata: SystemMetadata,
            comptime component_query_types: []const type,
            comptime component_hashes: []const u64,
        ) type {
            return struct {
                world: *World,
                opaque_archetypes: []OpaqueArchetype,

                pub fn exec(self_job: *@This()) void {
                    const param_types = comptime metadata.paramArgTypes();

                    var storage_buffer: [component_query_types.len][]u8 = undefined;
                    var storage = OpaqueArchetype.StorageData{
                        .inner_len = undefined,
                        .outer = &storage_buffer,
                    };

                    for (self_job.opaque_archetypes) |*opaque_archetype| {
                        // TODO: try instead of catch ..
                        opaque_archetype.rawGetStorageData(component_hashes, &storage) catch unreachable;
                        var i: usize = 0;
                        while (i < storage.inner_len) : (i += 1) {
                            var arguments: std.meta.Tuple(&param_types) = undefined;
                            inline for (param_types) |Param, j| {
                                switch (metadata.args[j]) {
                                    .component_value => {
                                        // get size of the parameter type
                                        const param_size = @sizeOf(Param);
                                        if (param_size > 0) {
                                            const from = i * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[j][from..to];
                                            arguments[j] = @ptrCast(*Param, @alignCast(@alignOf(Param), bytes.ptr)).*;
                                        } else {
                                            arguments[j] = Param{};
                                        }
                                    },
                                    .component_ptr => {
                                        // get size of the type the pointer is pointing to
                                        const param_size = @sizeOf(component_query_types[j]);
                                        if (param_size > 0) {
                                            const from = i * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[j][from..to];
                                            arguments[j] = @ptrCast(Param, @alignCast(@alignOf(component_query_types[j]), bytes.ptr));
                                        } else {
                                            arguments[j] = &component_query_types[j]{};
                                        }
                                    },
                                    .event_argument_value => @compileError("event arguments are illegal for dispatch systems"),
                                    .shared_state_value => arguments[j] = self_job.world.getSharedStateWithSharedStateType(Param),
                                    .shared_state_ptr => arguments[j] = self_job.world.getSharedStatePtrWithSharedStateType(Param),
                                }
                            }
                            const system_ptr = @ptrCast(FuncType, func);
                            callWrapper(system_ptr.*, arguments);
                        }
                    }
                }
            };
        }

        fn EventDispatchJob(
            comptime func: *const anyopaque,
            comptime FuncType: type,
            comptime metadata: SystemMetadata,
            comptime component_query_types: []const type,
            comptime component_hashes: []const u64,
            comptime ExtraArgumentType: type,
        ) type {
            return struct {
                world: *World,
                opaque_archetypes: []OpaqueArchetype,
                extra_argument: ExtraArgumentType,

                pub fn exec(self_job: *@This()) void {
                    const param_types = comptime metadata.paramArgTypes();

                    var storage_buffer: [component_hashes.len][]u8 = undefined;
                    var storage = OpaqueArchetype.StorageData{
                        .inner_len = undefined,
                        .outer = &storage_buffer,
                    };

                    for (self_job.opaque_archetypes) |*opaque_archetype| {
                        // TODO: try
                        opaque_archetype.rawGetStorageData(component_hashes, &storage) catch unreachable;
                        var i: usize = 0;
                        while (i < storage.inner_len) : (i += 1) {
                            var arguments: std.meta.Tuple(&param_types) = undefined;
                            inline for (param_types) |Param, j| {
                                switch (metadata.args[j]) {
                                    .component_value => {
                                        // get size of the parameter type
                                        const param_size = @sizeOf(Param);
                                        if (param_size > 0) {
                                            const from = i * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[j][from..to];
                                            arguments[j] = @ptrCast(*Param, @alignCast(@alignOf(Param), bytes.ptr)).*;
                                        } else {
                                            arguments[j] = Param{};
                                        }
                                    },
                                    .component_ptr => {
                                        // get size of the type the pointer is pointing to
                                        const param_size = @sizeOf(component_query_types[j]);
                                        if (param_size > 0) {
                                            const from = i * param_size;
                                            const to = from + param_size;
                                            const bytes = storage.outer[j][from..to];
                                            arguments[j] = @ptrCast(Param, @alignCast(@alignOf(Param), bytes.ptr));
                                        } else {
                                            arguments[j] = &component_query_types[j]{};
                                        }
                                    },
                                    .event_argument_value => arguments[j] = @bitCast(meta.EventArgument(ExtraArgumentType), self_job.extra_argument),
                                    .shared_state_value => arguments[j] = self_job.world.getSharedStateWithSharedStateType(Param),
                                    .shared_state_ptr => arguments[j] = self_job.world.getSharedStatePtrWithSharedStateType(Param),
                                }
                            }

                            if (comptime metadata.canReturnError()) {
                                // TODO: remove this error: https://github.com/Avokadoen/ecez/issues/57
                                //failableCallWrapper(system_ptr.*, arguments);
                                @compileError("system that can fail are currently unsupported");
                            } else {
                                const system_ptr = @ptrCast(FuncType, func);
                                callWrapper(system_ptr.*, arguments);
                            }
                        }
                    }
                }
            };
        }

        inline fn getMetadataIndexRange(comptime metadata: SystemMetadata) ?[]const u32 {
            if (metadata.depend_on_indices_range) |range| {
                return systems_info.depend_on_index_pool[range.from..range.to];
            }
            return null;
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
const WorldStub = WorldBuilder().WithComponents(Testing.AllComponentsTuple);

test "init() + deinit() is idempotent" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity0 = try world.createEntity(.{Testing.Component.A{}});
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try world.createEntity(.{Testing.Component.A{}});
    try testing.expectEqual(entity1.id, 1);
}

test "setComponent() component moves entity to correct archetype" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity1 = try world.createEntity(.{Testing.Component.A{}});

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

    const entity = try world.createEntity(.{ Testing.Component.A{}, Testing.Component.B{} });

    const a = Testing.Component.A{ .value = 123 };
    try world.setComponent(entity, a);

    const stored_a = try world.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
}

test "removeComponent() removes the component as expected" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(.{ Testing.Component.B{}, Testing.Component.C{} });

    try world.setComponent(entity, Testing.Component.A{});
    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.A));

    try world.removeComponent(entity, Testing.Component.A);
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.A));

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.B));

    try world.removeComponent(entity, Testing.Component.B);
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.B));
}

test "hasComponent() responds as expected" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(.{ Testing.Component.A{}, Testing.Component.C{} });

    try testing.expectEqual(true, world.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, world.hasComponent(entity, Testing.Component.B));
}

test "getComponent() retrieve component value" {
    var world = try WorldStub.init(testing.allocator, .{});
    defer world.deinit();

    _ = try world.createEntity(.{Testing.Component.A{ .value = 0 }});
    _ = try world.createEntity(.{Testing.Component.A{ .value = 1 }});
    _ = try world.createEntity(.{Testing.Component.A{ .value = 2 }});

    const a = Testing.Component.A{ .value = 123 };
    const entity = try world.createEntity(.{a});

    _ = try world.createEntity(.{Testing.Component.A{ .value = 3 }});
    _ = try world.createEntity(.{Testing.Component.A{ .value = 4 }});

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

    const entity = try world.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.B{ .value = 2 },
    });

    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "system parameter order is independent" {
    const SystemStruct = struct {
        pub fn mutateStuff(b: Testing.Component.B, c: Testing.Component.C, a: *Testing.Component.A) void {
            _ = c;
            a.value += @intCast(u32, b.value);
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).init(testing.allocator, .{});
    defer world.deinit();

    const entity = try world.createEntity(.{
        Testing.Component.A{ .value = 1 },
        Testing.Component.B{ .value = 2 },
        Testing.Component.C{},
    });

    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(
        Testing.Component.A{ .value = 3 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "systems can access shared state" {
    const A = Testing.Component.A;

    const SystemStruct = struct {
        pub fn aSystem(a: *A, shared: SharedState(A)) void {
            a.* = @bitCast(A, shared);
        }
    };

    const shared_state = A{ .value = 8 };
    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).WithSharedState(.{A}).init(testing.allocator, .{
        shared_state,
    });
    defer world.deinit();

    const entity = try world.createEntity(.{A{ .value = 0 }});
    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(shared_state, try world.getComponent(entity, A));
}

test "systems can mutate shared state" {
    const A = struct {
        value: u8,
    };
    const SystemStruct = struct {
        pub fn func(a: Testing.Component.A, shared: *SharedState(A)) void {
            _ = a;
            shared.value += 1;
        }

        pub fn bSystem(a: Testing.Component.A, b: Testing.Component.B, shared: *SharedState(A)) void {
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

    _ = try world.createEntity(.{ Testing.Component.A{}, Testing.Component.B{} });
    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(@as(u8, 2), world.shared_state[0].value);
}

// TODO: https://github.com/Avokadoen/ecez/issues/57
// test "systems can have many shared state" {
//     const A = struct {
//         value: u8,
//     };
//     const B = struct {
//         value: u8,
//     };
//     const C = struct {
//         value: u8,
//     };

//     const SystemStruct = struct {
//         pub fn system1(a: Testing.Component.A, shared: SharedState(A)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 0), shared.value);
//         }

//         pub fn system2(a: Testing.Component.A, shared: SharedState(B)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 1), shared.value);
//         }

//         pub fn system3(a: Testing.Component.A, shared: SharedState(C)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 2), shared.value);
//         }

//         pub fn system4(a: Testing.Component.A, shared_a: SharedState(A), shared_b: SharedState(B)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 0), shared_a.value);
//             try testing.expectEqual(@as(u8, 1), shared_b.value);
//         }

//         pub fn system5(a: Testing.Component.A, shared_b: SharedState(B), shared_a: SharedState(A)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 0), shared_a.value);
//             try testing.expectEqual(@as(u8, 1), shared_b.value);
//         }

//         pub fn system6(a: Testing.Component.A, shared_c: SharedState(C), shared_b: SharedState(B), shared_a: SharedState(A)) !void {
//             _ = a;
//             try testing.expectEqual(@as(u8, 0), shared_a.value);
//             try testing.expectEqual(@as(u8, 1), shared_b.value);
//             try testing.expectEqual(@as(u8, 2), shared_c.value);
//         }
//     };

//     var world = try WorldStub.WithSystems(.{
//         SystemStruct,
//     }).WithSharedState(.{
//         A, B, C,
//     }).init(testing.allocator, .{
//         A{ .value = 0 },
//         B{ .value = 1 },
//         C{ .value = 2 },
//     });
//     defer world.deinit();

//     _ = try world.createEntity(.{Testing.Component.A{}});

//     try world.dispatch();
// }

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

    const entity = try world.createEntity(.{Testing.Component.A{
        .value = 0,
    }});

    try world.dispatch();
    world.waitDispatch();

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

    const entity1 = try world.createEntity(.{ Testing.Component.A{
        .value = 0,
    }, Testing.Component.B{
        .value = 0,
    } });
    const entity2 = try world.createEntity(.{Testing.Component.A{
        .value = 2,
    }});

    try world.triggerEvent(.onFoo, .{});
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

    try world.triggerEvent(.onBar, .{});
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
            a.* = @bitCast(A, shared);
        }
    };

    const shared_a = A{ .value = 42 };
    var world = try WorldStub.WithEvents(.{
        Event("onFoo", .{SystemType}, .{}),
    }).WithSharedState(.{A}).init(testing.allocator, .{shared_a});

    defer world.deinit();

    const entity = try world.createEntity(.{A{ .value = 0 }});
    try world.triggerEvent(.onFoo, .{});
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

    _ = try world.createEntity(.{Testing.Component.A{}});

    try world.triggerEvent(.onFoo, .{});
    world.waitEvent(.onFoo);

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

    const entity = try world.createEntity(.{Testing.Component.A{ .value = 0 }});

    try world.triggerEvent(.onFoo, MouseInput{ .x = 40, .y = 2 });
    world.waitEvent(.onFoo);

    try testing.expectEqual(
        Testing.Component.A{ .value = 42 },
        try world.getComponent(entity, Testing.Component.A),
    );
}

test "dispatch cache works" {
    const SystemStruct = struct {
        pub fn aSystem(a: *Testing.Component.A) void {
            a.value += 1;
        }
    };

    var world = try WorldStub.WithSystems(.{
        SystemStruct,
    }).init(testing.allocator, .{});
    defer world.deinit();

    const entity1 = try world.createEntity(.{Testing.Component.A{ .value = 0 }});
    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(Testing.Component.A{ .value = 1 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    // move entity to archetype A, B
    try world.setComponent(entity1, Testing.Component.B{});
    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(Testing.Component.A{ .value = 2 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    const entity2 = try world.createEntity(.{
        Testing.Component.A{ .value = 0 },
        Testing.Component.B{},
        Testing.Component.C{},
    });
    try world.dispatch();
    world.waitDispatch();

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(entity2, Testing.Component.A),
    );
}

test "event cache works" {
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

    const entity1 = try world.createEntity(.{Testing.Component.A{ .value = 0 }});

    try world.triggerEvent(.onEvent1, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 1 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    // move entity to archetype A, B
    try world.setComponent(entity1, Testing.Component.B{ .value = 0 });
    try world.triggerEvent(.onEvent1, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(Testing.Component.A{ .value = 2 }, try world.getComponent(
        entity1,
        Testing.Component.A,
    ));

    try world.triggerEvent(.onEvent2, .{});
    world.waitEvent(.onEvent2);

    try testing.expectEqual(Testing.Component.B{ .value = 1 }, try world.getComponent(
        entity1,
        Testing.Component.B,
    ));

    const entity2 = try world.createEntity(.{
        Testing.Component.A{ .value = 0 },
        Testing.Component.B{ .value = 0 },
        Testing.Component.C{},
    });

    try world.triggerEvent(.onEvent1, .{});
    world.waitEvent(.onEvent1);

    try testing.expectEqual(
        Testing.Component.A{ .value = 1 },
        try world.getComponent(entity2, Testing.Component.A),
    );

    try world.triggerEvent(.onEvent2, .{});
    world.waitEvent(.onEvent2);

    try testing.expectEqual(
        Testing.Component.B{ .value = 1 },
        try world.getComponent(entity2, Testing.Component.B),
    );
}

test "DependOn makes a system race free" {
    const SystemStruct = struct {
        pub fn addStuff1(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 3);
            a.value += @intCast(u32, b.value);
        }

        pub fn multiplyStuff1(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us * 2);
            a.value *= @intCast(u32, b.value);
        }

        pub fn addStuff2(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += @intCast(u32, b.value);
        }

        pub fn multiplyStuff2(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @intCast(u32, b.value);
        }
    };

    const World = WorldStub.WithSystems(.{
        SystemStruct.addStuff1,
        DependOn(SystemStruct.multiplyStuff1, .{SystemStruct.addStuff1}),
        DependOn(SystemStruct.addStuff2, .{SystemStruct.multiplyStuff1}),
        DependOn(SystemStruct.multiplyStuff2, .{SystemStruct.addStuff2}),
    }).Build();

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    const entity_count = 10_000;
    var entities: [entity_count]Entity = undefined;

    for (entities) |*entity| {
        entity.* = try world.createEntity(.{
            Testing.Component.A{ .value = 3 },
            Testing.Component.B{ .value = 2 },
        });
    }

    try world.dispatch();
    world.waitDispatch();

    try world.dispatch();
    world.waitDispatch();

    for (entities) |entity| {
        // (((3  + 2) * 2) + 2) * 2 =  24
        // (((24 + 2) * 2) + 2) * 2 = 108
        try testing.expectEqual(
            Testing.Component.A{ .value = 108 },
            try world.getComponent(entity, Testing.Component.A),
        );
    }
}

test "DependOn can have multiple dependencies" {
    const SystemStruct = struct {
        pub fn addStuff1(a: *Testing.Component.A) void {
            std.time.sleep(std.time.ns_per_us * 2);
            a.value += 1;
        }

        pub fn addStuff2(a: *Testing.Component.A, b: Testing.Component.B) void {
            std.time.sleep(std.time.ns_per_us);
            a.value += b.value;
        }

        pub fn multiplyStuff(a: *Testing.Component.A, b: Testing.Component.B) void {
            a.value *= @intCast(u32, b.value);
        }
    };

    const World = WorldStub.WithSystems(.{
        SystemStruct.addStuff1,
        SystemStruct.addStuff2,
        DependOn(SystemStruct.multiplyStuff, .{ SystemStruct.addStuff1, SystemStruct.addStuff2 }),
    }).Build();

    var world = try World.init(testing.allocator, .{});
    defer world.deinit();

    const entity_count = 10_000;
    var entities: [entity_count]Entity = undefined;

    for (entities) |*entity| {
        entity.* = try world.createEntity(.{
            Testing.Component.A{ .value = 3 },
            Testing.Component.B{ .value = 2 },
        });
    }

    try world.dispatch();
    world.waitDispatch();

    try world.dispatch();
    world.waitDispatch();

    for (entities) |entity| {
        // (3  + 1 + 2) * 2 = 12
        // (12 + 1 + 2) * 2 = 30
        try testing.expectEqual(
            Testing.Component.A{ .value = 30 },
            try world.getComponent(entity, Testing.Component.A),
        );
    }
}
