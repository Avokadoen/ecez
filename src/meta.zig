const std = @import("std");
const FnInfo = std.builtin.Type.Fn;
const Type = std.builtin.Type;

const testing = std.testing;

const Entity = @import("entity_type.zig").Entity;

const secret_field = "secret_field";

/// Special optional return type for systems that allow systems exit early if needed
pub const ReturnCommand = enum {
    /// indicate that the system should continue to execute as normal
    @"continue",
    /// indicate that the system should exit early
    @"break",
};

pub const ArgType = enum {
    presumed_component,
    query_iter,
    query,
    event,
    shared_state,
};

pub const SystemType = enum {
    common,
    depend_on,
    event,
};

const max_params = 32;
pub const SystemMetadata = union(SystemType) {
    /// A simple system that will be executed for the event
    common: CommonSystem,
    /// A system that will be blocked until the tagged systems finish executing
    depend_on: DependOnSystem,
    /// Metadata for any event is a collection of the other types
    event: void,

    /// Get the argument types as proper component types
    /// This function will extrapolate inner types from pointers
    pub fn componentQueryArgTypes(comptime self: SystemMetadata) []const type {
        switch (self) {
            .common => |common| return &common.componentQueryArgTypes(),
            .depend_on => |depend_on| return &depend_on.common.componentQueryArgTypes(),
            .event => @compileError("ecez library bug, please file a issue if you hit this error"),
        }
    }

    /// Get the argument types as requested
    /// This function will include pointer types
    pub fn paramArgTypes(comptime self: SystemMetadata) []const type {
        switch (self) {
            .common => |common| return &common.paramArgTypes(),
            .depend_on => |depend_on| return &depend_on.common.paramArgTypes(),
            .event => @compileError("ecez library bug, please file a issue if you hit this error"),
        }
    }

    pub fn paramCategories(comptime self: SystemMetadata) []const CommonSystem.ParamCategory {
        return switch (self) {
            .common => |common| common.param_categories,
            .depend_on => |depend_on| depend_on.common.param_categories,
            .event => @compileError("ecez library bug, please file a issue if you hit this error"),
        };
    }

    pub fn hasEntityArgument(comptime self: SystemMetadata) bool {
        switch (self) {
            .common => |common| return common.has_entity_argument,
            .depend_on => |depend_on| return depend_on.common.has_entity_argument,
            .event => @compileError("ecez library bug, please file a issue if you hit this error"),
        }
    }

    pub fn returnSystemCommand(comptime self: SystemMetadata) bool {
        switch (self) {
            .common => |common| return common.returns_system_command,
            .depend_on => |depend_on| return depend_on.common.returns_system_command,
            .event => @compileError("ecez library bug, please file a issue if you hit this error"),
        }
    }
};

pub const CommonSystem = struct {
    pub const ParamCategory = enum {
        component_ptr,
        component_value,
        entity,
        query_ptr,
        query_value,
        event_argument_ptr,
        event_argument_value,
        shared_state_ptr,
        shared_state_value,
    };

    fn_info: FnInfo,
    component_params_count: usize,
    param_category_buffer: [max_params]ParamCategory,
    param_categories: []const ParamCategory,
    has_entity_argument: bool,
    returns_system_command: bool,

    /// initalize metadata for a system using a supplied function type info
    pub fn init(
        comptime function_type: type,
        comptime fn_info: FnInfo,
    ) CommonSystem {
        // blocked by issue https://github.com/ziglang/zig/issues/1291
        if (fn_info.params.len > max_params) {
            @compileError(std.fmt.comptimePrint("system arguments currently only support up to {d} arguments", .{max_params}));
        }

        // TODO: include function name in error messages
        //       blocked by issue https://github.com/ziglang/zig/issues/8270
        // used in error messages
        const function_name = @typeName(function_type);
        if (fn_info.is_generic) {
            @compileError("system " ++ function_name ++ " functions cannot use generic arguments");
        }
        if (fn_info.params.len == 0) {
            @compileError("system " ++ function_name ++ " missing component arguments");
        }

        const returns_system_command = return_validation_blk: {
            if (fn_info.return_type) |return_type| {
                if (return_type == ReturnCommand) {
                    break :return_validation_blk true;
                }
                if (return_type == void) {
                    break :return_validation_blk false;
                }
                @compileError("system " ++ function_name ++ " return type has to be void or " ++ @typeName(ReturnCommand) ++ ", was " ++ @typeName(return_type));
            }
        };

        const param_types = param_type_unroll_blk: {
            var types: [fn_info.params.len]type = undefined;
            for (&types, fn_info.params, 0..) |*T, param_info, index| {
                T.* = param_info.type orelse {
                    @compileError(std.fmt.comptimePrint("system {s} argument {d} is missing type", .{
                        function_name,
                        index,
                    }));
                };
            }

            break :param_type_unroll_blk types;
        };

        var param_category_buffer: [32]ParamCategory = undefined;
        var param_categories = param_category_buffer[0..fn_info.params.len];

        const parse_result = parseParams(function_name, param_categories, &param_types);

        return CommonSystem{
            .fn_info = fn_info,
            .component_params_count = parse_result.component_params_count,
            .param_category_buffer = param_category_buffer,
            .param_categories = param_categories,
            .has_entity_argument = parse_result.has_entity_argument,
            .returns_system_command = returns_system_command,
        };
    }

    /// Get the argument types as proper component types
    /// This function will extrapolate inner types from pointers
    pub fn componentQueryArgTypes(comptime self: CommonSystem) [self.component_params_count]type {
        const start_index = if (self.has_entity_argument) 1 else 0;
        const end_index = self.component_params_count + start_index;

        comptime var params: [self.component_params_count]type = undefined;
        inline for (&params, self.fn_info.params[start_index..end_index]) |*param, arg| {
            switch (@typeInfo(arg.type.?)) {
                .Pointer => |p| {
                    param.* = p.child;
                    continue;
                },
                else => {},
            }
            param.* = arg.type.?;
        }
        return params;
    }

    /// Get the argument types as requested
    /// This function will include pointer types
    pub fn paramArgTypes(comptime self: CommonSystem) [self.param_categories.len]type {
        comptime var params: [self.fn_info.params.len]type = undefined;
        inline for (self.fn_info.params, &params) |arg, *param| {
            param.* = arg.type.?;
        }
        return params;
    }

    const ParseParamResult = struct {
        component_params_count: usize,
        has_entity_argument: bool,
    };
    fn parseParams(
        function_name: [:0]const u8,
        comptime param_categories: []ParamCategory,
        comptime param_types: []const type,
    ) ParseParamResult {
        const ParsingState = enum {
            component_parsing,
            special_arguments,
        };
        const SetParsingState = struct {
            shared_state: ParamCategory,
            event_argument: ParamCategory,
            component: ParamCategory,
            query_iter: ParamCategory,
            type: type,
        };

        var result = ParseParamResult{
            .component_params_count = 0,
            .has_entity_argument = false,
        };

        var parsing_state: ParsingState = .component_parsing;
        for (param_categories, param_types, 0..) |*param, T, i| {
            if (i == 0 and T == Entity) {
                param.* = ParamCategory.entity;
                result.has_entity_argument = true;
                continue;
            } else if (T == Entity) {
                @compileError("entity argument must be the first argument");
            }

            // figure out which Arg enums we should use for the next step
            const parse_set_states: SetParsingState = parse_set_state_blk: {
                switch (@typeInfo(T)) {
                    .Pointer => |pointer| {
                        // we enforce struct arguments because it is easier to identify requested data while
                        // mainting type safety
                        if (@typeInfo(pointer.child) != .Struct) {
                            const err_msg = std.fmt.comptimePrint("system {s} argument {d} must point to a struct", .{
                                function_name,
                                i,
                            });
                            @compileError(err_msg);
                        }

                        break :parse_set_state_blk SetParsingState{
                            .shared_state = ParamCategory.shared_state_ptr,
                            .event_argument = ParamCategory.event_argument_ptr,
                            .component = ParamCategory.component_ptr,
                            .query_iter = ParamCategory.query_ptr,
                            .type = pointer.child,
                        };
                    },
                    .Struct => break :parse_set_state_blk SetParsingState{
                        .shared_state = ParamCategory.shared_state_value,
                        .event_argument = ParamCategory.event_argument_value,
                        .component = ParamCategory.component_value,
                        .query_iter = ParamCategory.query_value,
                        .type = T,
                    },
                    else => @compileError(std.fmt.comptimePrint("system {s} argument {d} is not a struct", .{
                        function_name,
                        i,
                    })),
                }
            };

            // check if we are currently parsing a special argument and register any
            const assigned_special_argument = special_parse_blk: {
                switch (getSepcialArgument(parse_set_states.type)) {
                    .shared_state => {
                        param.* = parse_set_states.shared_state;
                        parsing_state = .special_arguments;
                        break :special_parse_blk true;
                    },
                    .event => {
                        param.* = parse_set_states.event_argument;
                        parsing_state = .special_arguments;
                        break :special_parse_blk true;
                    },
                    .query_iter => {
                        param.* = parse_set_states.query_iter;
                        parsing_state = .special_arguments;
                        break :special_parse_blk true;
                    },
                    .query => @compileError("Query is not legal, use Query.Iter instead"),
                    .presumed_component => {
                        break :special_parse_blk false;
                    },
                }
            };

            if (assigned_special_argument == false) {
                // if we did not parse a special argument, but we are not parsing components then the systems is illegal
                if (parsing_state == .special_arguments) {
                    const pre_arg_str = switch (param_categories[i - 1]) {
                        .component_ptr, .component_value => unreachable,
                        .event_argument_value => "event",
                        .shared_state_ptr, .shared_state_value => "shared state",
                        else => {},
                    };
                    const err_msg = std.fmt.comptimePrint("system {s} argument {d} is a component but comes after {s}", .{
                        function_name,
                        i,
                        pre_arg_str,
                    });
                    @compileError(err_msg);
                }

                result.component_params_count += 1;
                param.* = parse_set_states.component;
            }
        }

        return result;
    }
};

pub const DependOnSystem = struct {
    pub const Range = struct {
        to: u32,
        from: u32,
    };

    common: CommonSystem,
    depend_on_indices_range: Range,

    /// initalize metadata for a system using a supplied function type info
    pub fn init(
        comptime depend_on_indices_range: Range,
        comptime function_type: type,
        comptime fn_info: FnInfo,
    ) DependOnSystem {
        return DependOnSystem{
            .common = CommonSystem.init(function_type, fn_info),
            .depend_on_indices_range = depend_on_indices_range,
        };
    }

    pub fn getIndexRange(comptime self: DependOnSystem, comptime triggered_event: anytype) []const u32 {
        const range = self.depend_on_indices_range;
        return triggered_event.systems_info.depend_on_index_pool[range.from..range.to];
    }
};

/// Create an event which can be triggered and dispatch associated systems
/// Parameters:
///     - event_name:          name of the event
///     - systems:             systems that should be dispatched if this event is triggered
///     - event_argument_type: event specific argument type for each system
pub fn Event(comptime event_name: []const u8, comptime systems: anytype, comptime event_argument_type: anytype) type {
    if (@typeInfo(@TypeOf(systems)) != .Struct) {
        @compileError("systems must be a tuple of systems");
    }

    const EventArgumentType = blk: {
        const info = @typeInfo(@TypeOf(event_argument_type));
        if (info == .Type) {
            break :blk event_argument_type;
        }
        if (info == .Struct) {
            break :blk @TypeOf(event_argument_type);
        }
        @compileError("expected event_argument_type to be type or struct type");
    };

    return struct {
        pub const secret_field = SystemType.event;
        pub const name = event_name;
        pub const s = systems;
        pub const system_count = countAndVerifySystems(systems);
        pub const systems_info = createSystemInfo(system_count, systems);
        pub const EventArgument = EventArgumentType;
    };
}

pub fn getSepcialArgument(comptime T: type) ArgType {
    const info = @typeInfo(T);
    if (info == .Struct) {
        for (info.Struct.fields) |field| {
            if (field.type == ArgType) {
                if (field.default_value) |default| {
                    return @as(*const ArgType, @ptrCast(default)).*;
                }
            }
        }
    }
    return .presumed_component;
}

pub fn isSpecialArgument(comptime arg_type: ArgType, comptime T: type) bool {
    return getSepcialArgument(T) == arg_type;
}

pub fn getSystemType(comptime T: type) SystemType {
    const info = @typeInfo(T);
    if (info == .Struct) {
        for (info.Struct.decls) |decl| {
            if (std.mem.eql(u8, secret_field, decl.name)) {
                const secret = @field(T, decl.name);
                if (@TypeOf(secret) == SystemType) {
                    return secret;
                }
            }
        }
    }
    return .common;
}

pub fn isSystemType(comptime system_type: SystemType, comptime T: type) bool {
    return getSystemType(T) == system_type;
}

/// count events and verify arguments
pub fn countAndVerifyEvents(comptime events: anytype) comptime_int {
    const EventsType = @TypeOf(events);
    const events_type_info = @typeInfo(EventsType);
    if (events_type_info != .Struct) {
        @compileError("CreateWorld expected tuple or struct argument for events, got " ++ @typeName(EventsType));
    }

    comptime var event_count = 0;
    // start by counting events registered
    inline for (events_type_info.Struct.fields, 0..) |field_info, i| {
        switch (@typeInfo(field_info.type)) {
            .Type => {
                switch (@typeInfo(events[i])) {
                    .Struct => {
                        if (isSystemType(.event, events[i]) == false) {
                            @compileError("invalid event type " ++ @typeName(@TypeOf(events[i])) ++ ", use ecez.Event() to generate event type");
                        }
                        event_count += 1;
                    },
                    else => {
                        const err_msg = std.fmt.comptimePrint("CreateWorld expected struct type, got {s}", .{
                            @typeInfo(events[i]),
                        });
                        @compileError(err_msg);
                    },
                }
            },
            else => {
                const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct, got {s}", .{
                    @typeName(field_info.type),
                });
                @compileError(err_msg);
            },
        }
    }
    return event_count;
}

pub fn GenerateEventsEnum(comptime event_count: comptime_int, comptime events: anytype) type {
    const EventsType = @TypeOf(events);
    const events_type_info = @typeInfo(EventsType);
    const fields_info = events_type_info.Struct.fields;

    var enum_fields: [event_count]Type.EnumField = undefined;
    inline for (fields_info, 0..) |_, i| {
        enum_fields[i] = Type.EnumField{
            .name = events[i].name,
            .value = i,
        };
    }

    const event_enum_info = Type{ .Enum = .{
        .tag_type = usize,
        .fields = &enum_fields,
        .decls = &[0]Type.Declaration{},
        .is_exhaustive = true,
    } };

    return @Type(event_enum_info);
}

/// count dispatch systems and verify system argument
pub fn countAndVerifySystems(comptime systems: anytype) comptime_int {
    const SystemsType = @TypeOf(systems);
    const systems_type_info = @typeInfo(SystemsType);
    if (systems_type_info != .Struct) {
        @compileError("CreateWorld system argument expected tuple- or struct type, found " ++ @typeName(SystemsType) ++ "\n\tHint: did you rembember to wrap your depend_on_systems in a tuple '.{system}'?");
    }

    const fields_info = systems_type_info.Struct.fields;
    comptime var systems_count = 0;
    // start by counting systems registered
    inline for (fields_info, 0..) |field_info, i| {
        switch (@typeInfo(field_info.type)) {
            .Fn => systems_count += 1,
            .Type => {
                switch (@typeInfo(systems[i])) {
                    .Struct => |stru| {
                        switch (getSystemType(systems[i])) {
                            .depend_on => {
                                // should be one inner system at this point
                                systems_count += 1;
                            },
                            .common => {
                                // it's not a DependOn, or Zip struct, check each member of the struct to find functions
                                inline for (stru.decls) |decl| {
                                    const DeclType = @TypeOf(@field(systems[i], decl.name));
                                    switch (@typeInfo(DeclType)) {
                                        .Fn => systems_count += 1,
                                        else => {
                                            const err_msg = std.fmt.comptimePrint("CreateWorld expected type of functions, got member {s}", .{
                                                @typeName(DeclType),
                                            });
                                            @compileError(err_msg);
                                        },
                                    }
                                }
                            },
                            .event => @compileError("nested events are not allowed"), // because it does not make sense :)

                        }
                    },
                    else => {
                        const err_msg = std.fmt.comptimePrint("CreateWorld expected struct type, got {s}", .{
                            @typeInfo(systems[i]),
                        });
                        @compileError(err_msg);
                    },
                }
            },
            else => {
                const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct, got {s}", .{
                    @typeName(field_info.type),
                });
                @compileError(err_msg);
            },
        }
    }
    return systems_count;
}

fn SystemInfo(comptime system_count: comptime_int) type {
    return struct {
        const Self = @This();

        // TODO: make size configurable
        depend_on_indices_used: usize,
        depend_on_index_pool: [system_count * 2]u32,
        metadata: [system_count]SystemMetadata,
        function_types: [system_count]type,
        functions: [system_count]*const anyopaque,
    };
}

/// Specifiy a dependency where a system depends on one or more systems
/// Parameters:
///     - system: the system that you are registering
///     - depend_on_systems: a TUPLE of one or more functions that the system depend on
pub fn DependOn(comptime system: anytype, comptime depend_on_systems: anytype) type {
    return struct {
        const secret_field = SystemType.depend_on;
        const _system = system;
        const _depend_on_systems = depend_on_systems;
    };
}

/// perform compile-time reflection on systems to extrapolate different information about registered systems
pub fn createSystemInfo(comptime system_count: comptime_int, comptime systems: anytype) SystemInfo(system_count) {
    const SystemsType = @TypeOf(systems);
    const systems_type_info = @typeInfo(SystemsType);
    const fields_info = systems_type_info.Struct.fields;
    var systems_info: SystemInfo(system_count) = undefined;

    systems_info.depend_on_indices_used = 0;
    {
        comptime var i: usize = 0;
        inline for (fields_info, 0..) |field_info, j| {
            switch (@typeInfo(field_info.type)) {
                .Fn => |func| {
                    systems_info.metadata[i] = SystemMetadata{ .common = CommonSystem.init(field_info.type, func) };
                    systems_info.function_types[i] = field_info.type;
                    systems_info.functions[i] = field_info.default_value.?;
                    i += 1;
                },
                .Type => {
                    switch (@typeInfo(systems[j])) {
                        .Struct => |stru| {
                            switch (getSystemType(systems[j])) {
                                .depend_on => {
                                    const dependency_functions = @field(systems[j], "_depend_on_systems");
                                    const system_depend_on_count = countAndVerifySystems(dependency_functions);

                                    const depend_on_range = blk: {
                                        const from = systems_info.depend_on_indices_used;

                                        inline for (0..system_depend_on_count) |depend_on_index| {
                                            const dependency_func = dependency_functions[depend_on_index];

                                            const previous_system_info_index: usize = indexOfFunctionInSystems(dependency_func, j, systems) orelse {
                                                const err_msg = std.fmt.comptimePrint(
                                                    "System {d} did not find '{s}' in systems tuple, dependencies must be added before system that depend on them",
                                                    .{ i, @typeName(@TypeOf(dependency_func)) },
                                                );
                                                @compileError(err_msg);
                                            };
                                            systems_info.depend_on_index_pool[systems_info.depend_on_indices_used] = previous_system_info_index;
                                            systems_info.depend_on_indices_used += 1;
                                        }
                                        const to = systems_info.depend_on_indices_used;

                                        break :blk DependOnSystem.Range{ .from = from, .to = to };
                                    };

                                    const dep_on_function = @field(systems[j], "_system");
                                    const DepSystemDeclType = @TypeOf(dep_on_function);
                                    const dep_system_decl_info = @typeInfo(DepSystemDeclType);
                                    if (dep_system_decl_info == .Struct) {
                                        @compileError("Struct of system is not yet supported for DependOn");
                                    }
                                    if (dep_system_decl_info != .Fn and dep_system_decl_info != .Struct) {
                                        // TODO: remove if above so this is not so confusing
                                        @compileError("DependOn must be a function or struct");
                                    }
                                    systems_info.metadata[i] = SystemMetadata{
                                        .depend_on = DependOnSystem.init(depend_on_range, DepSystemDeclType, dep_system_decl_info.Fn),
                                    };
                                    systems_info.function_types[i] = DepSystemDeclType;
                                    systems_info.functions[i] = &dep_on_function;
                                    i += 1;
                                },
                                .common => {
                                    inline for (stru.decls) |decl| {
                                        const function = @field(systems[j], decl.name);
                                        const DeclType = @TypeOf(function);
                                        const decl_info = @typeInfo(DeclType);
                                        switch (decl_info) {
                                            .Fn => |func| {
                                                // const err_msg = std.fmt.comptimePrint("{d}", .{func.params.len});
                                                // @compileError(err_msg);
                                                systems_info.metadata[i] = SystemMetadata{ .common = CommonSystem.init(DeclType, func) };
                                                systems_info.function_types[i] = DeclType;
                                                systems_info.functions[i] = &function;
                                                i += 1;
                                            },
                                            else => {
                                                const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                                    @typeName(DeclType),
                                                });
                                                @compileError(err_msg);
                                            },
                                        }
                                    }
                                },
                                .event => @compileError("nested events are not allowed"),
                            }
                        },
                        else => {
                            const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                @typeName(field_info.type),
                            });
                            @compileError(err_msg);
                        },
                    }
                },
                else => unreachable,
            }
        }
    }
    return systems_info;
}

/// Look for the index of a given function in a tuple of functions and structs of functions
/// Returns: index of function, null if function is not in systems
pub fn indexOfFunctionInSystems(comptime function: anytype, comptime stop_at: usize, comptime systems: anytype) ?usize {
    const SystemsType = @TypeOf(systems);
    const systems_type_info = @typeInfo(SystemsType);
    const fields_info = systems_type_info.Struct.fields;

    {
        comptime var i: usize = 0;
        inline for (fields_info, 0..) |field_info, j| {
            switch (@typeInfo(field_info.type)) {
                .Fn => {
                    if (@TypeOf(systems[j]) == @TypeOf(function) and systems[j] == function) {
                        return i;
                    }
                    i += 1;
                },
                .Type => {
                    switch (@typeInfo(systems[j])) {
                        .Struct => |stru| {
                            // check if struct is a DependOn generated struct
                            if (isSystemType(.depend_on, systems[j])) {
                                const dep_on_function = @field(systems[j], "_system");
                                if (@TypeOf(function) == @TypeOf(dep_on_function) and function == dep_on_function) {
                                    return i;
                                }
                                i += 1;
                            } else {
                                inline for (stru.decls) |decl| {
                                    const inner_func = @field(systems[j], decl.name);
                                    const DeclType = @TypeOf(function);
                                    const decl_info = @typeInfo(DeclType);
                                    switch (decl_info) {
                                        .Fn => {
                                            if (@TypeOf(systems[j]) == @TypeOf(function) and function == inner_func) {
                                                return i;
                                            }
                                            i += 1;
                                        },
                                        else => {
                                            const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                                @typeName(DeclType),
                                            });
                                            @compileError(err_msg);
                                        },
                                    }
                                }
                            }
                        },
                        else => {
                            const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                @typeName(field_info.type),
                            });
                            @compileError(err_msg);
                        },
                    }
                },
                else => unreachable,
            }

            if (i >= stop_at) {
                return null;
            }
        }
    }
    return null;
}

/// Generate an archetype's SOA component storage
pub fn ComponentStorage(comptime types: []const type) type {
    var struct_fields: [types.len]Type.StructField = undefined;
    inline for (types, 0..) |T, i| {
        const ArrT = std.ArrayList(T);
        var num_buf: [8]u8 = undefined;
        struct_fields[i] = .{
            .name = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable,
            .type = if (@sizeOf(T) > 0) ArrT else T,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(T) > 0) @alignOf(ArrT) else 0,
        };
    }
    const RtrTypeInfo = Type{ .Struct = .{
        .layout = .Auto,
        .fields = &struct_fields,
        .decls = &[0]Type.Declaration{},
        .is_tuple = true,
    } };
    return @Type(RtrTypeInfo);
}

/// Generate a struct that hold components
pub fn ComponentStruct(comptime field_names: []const []const u8, comptime types: []const type) type {
    var struct_fields: [types.len]Type.StructField = undefined;
    inline for (field_names, types, 0..) |field_name, T, i| {
        struct_fields[i] = .{
            .name = field_name,
            .type = T,
            .default_value = null,
            .is_comptime = false,
            .alignment = if (@sizeOf(T) > 0) @alignOf(T) else 0,
        };
    }
    const RtrTypeInfo = Type{ .Struct = .{
        .layout = .Auto,
        .fields = &struct_fields,
        .decls = &[0]Type.Declaration{},
        .is_tuple = false,
    } };
    return @Type(RtrTypeInfo);
}

pub fn BitMaskFromComponents(comptime submitted_components: []const type) type {
    return struct {
        // A single integer that represent the full path of an opaque archetype
        pub const Bits = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = submitted_components.len,
        } });

        pub const Shift = @Type(std.builtin.Type{ .Int = .{
            .signedness = .unsigned,
            .bits = std.math.log2_int_ceil(Bits, submitted_components.len),
        } });

        pub fn bitsFromComponents(comptime other_components: []const type) Bits {
            comptime var bits: Bits = 0;
            outer_for: inline for (other_components) |OtherComponent| {
                inline for (submitted_components, 0..) |MaskComponent, bit_offset| {
                    if (MaskComponent == OtherComponent) {
                        bits |= 1 << bit_offset;
                        continue :outer_for;
                    }
                }
                @compileError(@tagName(OtherComponent) ++ " is not part of submitted components");
            }
        }
    };
}

/// Given a slice of structures, count how many contains the slice of types t
pub fn countRelevantStructuresContainingTs(comptime structures: []const type, comptime t: []const type) comptime_int {
    comptime var count = 0;
    inline for (structures) |S| {
        const s_info = @typeInfo(S);
        if (s_info != .Struct) {
            @compileError("countRelevantStructuresContainingTs recieved non struct structure");
        }
        comptime var matched = 0;
        inline for (s_info.Struct.fields) |field| {
            inner: inline for (t) |T| {
                if (T == field.type) {
                    matched += 1;
                    break :inner;
                }
            }
        }

        if (matched == t.len) {
            count += 1;
        }
    }
    return count;
}

pub fn indexOfStructuresContainingTs(
    comptime structures: []const type,
    comptime t: []const type,
) [countRelevantStructuresContainingTs(structures, t)]usize {
    comptime var indices: [countRelevantStructuresContainingTs(structures, t)]usize = undefined;
    comptime var i: usize = 0;
    inline for (structures, 0..) |S, j| {
        const s_info = @typeInfo(S);
        if (s_info != .Struct) {
            @compileError("countRelevantStructuresContainingTs recieved non struct structure");
        }
        comptime var matched = 0;
        inline for (s_info.Struct.fields) |field| {
            inner: inline for (t) |T| {
                if (T == field.type) {
                    matched += 1;
                    break :inner;
                }
            }
        }

        if (matched == t.len) {
            indices[i] = j;
            i += 1;
        }
    }
    return indices;
}

pub fn countTypeMapIndices(comptime type_tuple: anytype, comptime runtime_tuple_type: type) comptime_int {
    const type_tuple_info = blk: {
        const info = @typeInfo(@TypeOf(type_tuple));
        if (info != .Struct) {
            @compileError("expected type tuple to be a struct");
        }
        break :blk info.Struct;
    };

    const runtime_struct_info = blk: {
        const info = @typeInfo(runtime_tuple_type);
        if (info != .Struct) {
            @compileError("expected runtime struct to be a struct");
        }
        break :blk info.Struct;
    };

    var counter = 0;
    outer: inline for (type_tuple_info.fields, 0..) |_, i| {
        if (@TypeOf(type_tuple[i]) != type) {
            @compileError("expected type tuple to only have types");
        }
        inline for (runtime_struct_info.fields) |runtime_field| {
            if (type_tuple[i] == runtime_field.type) {
                counter += 1;
                continue :outer;
            }
        }
        @compileError("runtime_struct does not contain type " ++ @typeName(type_tuple[i]) ++ ", but type tuple does");
    }
    return counter;
}

pub fn typeMap(comptime type_tuple: anytype, comptime runtime_tuple_type: type) blk: {
    const rtr_array_size = countTypeMapIndices(type_tuple, runtime_tuple_type);
    break :blk [rtr_array_size]comptime_int;
} {
    const type_tuple_info = @typeInfo(@TypeOf(type_tuple)).Struct;
    const runtime_struct_info = @typeInfo(runtime_tuple_type).Struct;
    const rtr_array_size = countTypeMapIndices(type_tuple, runtime_tuple_type);

    var map: [rtr_array_size]comptime_int = undefined;
    inline for (type_tuple_info.fields, 0..) |_, i| {
        inline for (runtime_struct_info.fields, 0..) |runtime_field, j| {
            if (type_tuple[i] == runtime_field.type) {
                map[i] = j;
            }
        }
    }
    return map;
}

pub fn SharedStateStorage(comptime shared_state: anytype) type {
    const shared_info = blk: {
        const info = @typeInfo(@TypeOf(shared_state));
        if (info != .Struct) {
            @compileError("submitted invalid shared state type, must be a tuple of types");
        }
        break :blk info.Struct;
    };

    // var used_types: [shared_info.fields.len]type = undefined;
    var storage_fields: [shared_info.fields.len]Type.StructField = undefined;
    inline for (shared_info.fields, 0..) |field, i| {
        // // TODO: uncomment this when it does not crash compiler :)
        // for (used_types[0..i]) |used_type| {
        //     if (used_type == shared_state[i]) {
        //         @compileError("duplicate types are not allowed in shared state");
        //     }
        // }

        var num_buf: [8]u8 = undefined;
        const str_i = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;

        if (@typeInfo(field.type) != .Type) {
            @compileError("expected shared state field " ++ str_i ++ " to be a type, was " ++ @typeName(shared_state[i]));
        }
        const ActualStoredSharedState = SharedState(shared_state[i]);
        storage_fields[i] = Type.StructField{
            .name = str_i,
            .type = ActualStoredSharedState,
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(ActualStoredSharedState),
        };
        // used_types[i] = shared_state[i];
    }

    return @Type(Type{ .Struct = .{
        .layout = .Auto,
        .fields = &storage_fields,
        .decls = &[0]Type.Declaration{},
        .is_tuple = true,
    } });
}

/// This function will generate a type that is sufficient to mark a parameter as a shared state type
pub fn SharedState(comptime State: type) type {
    const state_info = blk: {
        const info = @typeInfo(State);
        if (info != .Struct) {
            @compileError("shared state must be of type struct");
        }
        break :blk info.Struct;
    };

    var shared_state_fields: [state_info.fields.len + 1]Type.StructField = undefined;
    inline for (state_info.fields, 0..) |field, i| {
        shared_state_fields[i] = field;
    }

    const default_value = ArgType.shared_state;
    shared_state_fields[state_info.fields.len] = Type.StructField{
        .name = secret_field,
        .type = ArgType,
        .default_value = @ptrCast(&default_value),
        .is_comptime = true,
        .alignment = 0,
    };

    return @Type(Type{ .Struct = .{
        .layout = state_info.layout,
        .fields = &shared_state_fields,
        .decls = &[0]Type.Declaration{},
        .is_tuple = state_info.is_tuple,
    } });
}

/// This function will mark a type as event data
pub fn EventArgument(comptime Argument: type) type {
    const argument_info = blk: {
        const info = @typeInfo(Argument);
        if (info != .Struct) {
            @compileError("event argument must be of type struct");
        }
        break :blk info.Struct;
    };

    var event_fields: [argument_info.fields.len + 1]Type.StructField = undefined;
    inline for (argument_info.fields, 0..) |field, i| {
        event_fields[i] = field;
    }

    const default_value = ArgType.event;
    event_fields[argument_info.fields.len] = Type.StructField{
        .name = secret_field,
        .type = ArgType,
        .default_value = @ptrCast(&default_value),
        .is_comptime = true,
        .alignment = 0,
    };

    return @Type(Type{ .Struct = .{
        .layout = argument_info.layout,
        .fields = &event_fields,
        .decls = argument_info.decls,
        .is_tuple = argument_info.is_tuple,
    } });
}

test "CommonSystem componentQueryArgTypes results in queryable types" {
    const A = struct {};
    const B = struct {};
    const TestSystems = struct {
        pub fn func1(a: A, b: B) void {
            _ = a;
            _ = b;
        }
        pub fn func2(a: *A, b: B) void {
            _ = a;
            _ = b;
        }
        pub fn func3(a: A, b: *B) void {
            _ = a;
            _ = b;
        }
    };

    const Func1Type = @TypeOf(TestSystems.func1);
    const Func2Type = @TypeOf(TestSystems.func2);
    const Func3Type = @TypeOf(TestSystems.func3);
    const metadatas = comptime [3]CommonSystem{
        CommonSystem.init(Func1Type, @typeInfo(Func1Type).Fn),
        CommonSystem.init(Func2Type, @typeInfo(Func2Type).Fn),
        CommonSystem.init(Func3Type, @typeInfo(Func3Type).Fn),
    };

    inline for (metadatas) |metadata| {
        const params = metadata.componentQueryArgTypes();

        try testing.expectEqual(params.len, 2);
        try testing.expectEqual(A, params[0]);
        try testing.expectEqual(B, params[1]);
    }
}

test "CommonSystem paramArgTypes results in pointer types" {
    const A = struct {};
    const B = struct {};
    const TestSystems = struct {
        pub fn func1(a: A, b: B) void {
            _ = a;
            _ = b;
        }
        pub fn func2(a: *A, b: B) void {
            _ = a;
            _ = b;
        }
        pub fn func3(a: A, b: *B) void {
            _ = a;
            _ = b;
        }
    };

    const Func1Type = @TypeOf(TestSystems.func1);
    const Func2Type = @TypeOf(TestSystems.func2);
    const Func3Type = @TypeOf(TestSystems.func3);
    const metadatas = comptime [_]CommonSystem{
        CommonSystem.init(Func1Type, @typeInfo(Func1Type).Fn),
        CommonSystem.init(Func2Type, @typeInfo(Func2Type).Fn),
        CommonSystem.init(Func3Type, @typeInfo(Func3Type).Fn),
    };

    {
        const params = metadatas[0].paramArgTypes();
        try testing.expectEqual(A, params[0]);
        try testing.expectEqual(B, params[1]);
    }
    {
        const params = metadatas[1].paramArgTypes();
        try testing.expectEqual(*A, params[0]);
        try testing.expectEqual(B, params[1]);
    }
    {
        const params = metadatas[2].paramArgTypes();
        try testing.expectEqual(A, params[0]);
        try testing.expectEqual(*B, params[1]);
    }
}

test "isSpecialArgument correctly identify event types" {
    const A = struct {};
    try testing.expectEqual(false, comptime isSpecialArgument(.event, A));
    try testing.expectEqual(true, comptime isSpecialArgument(.event, EventArgument(A)));
}

test "isSpecialArgument correctly identify shared state types" {
    const A = struct {};
    try testing.expectEqual(false, comptime isSpecialArgument(.shared_state, A));
    try testing.expectEqual(true, comptime isSpecialArgument(.shared_state, SharedState(A)));
}

test "isSystemType correctly identify event types" {
    const A = struct {};
    try testing.expectEqual(false, comptime isSystemType(.event, A));
    try testing.expectEqual(true, comptime isSystemType(.event, Event("hello_world", .{}, .{})));
}

test "isSystemType correctly identify DependOn types" {
    const A = struct {};
    try testing.expectEqual(false, comptime isSystemType(.depend_on, A));
    try testing.expectEqual(true, comptime isSystemType(.depend_on, DependOn(.{}, .{})));
}

test "countAndVerifyEvents count events" {
    const event_count = countAndVerifyEvents(.{
        Event("eventZero", .{}, void),
        Event("eventOne", .{}, void),
        Event("eventTwo", .{}, void),
    });
    try testing.expectEqual(3, event_count);
}

test "GenerateEventEnum generate expected enum" {
    const EventEnum = GenerateEventsEnum(3, .{
        Event("eventZero", .{}, void),
        Event("eventOne", .{}, void),
        Event("eventTwo", .{}, void),
    });
    try testing.expectEqual(0, @intFromEnum(EventEnum.eventZero));
    try testing.expectEqual(1, @intFromEnum(EventEnum.eventOne));
    try testing.expectEqual(2, @intFromEnum(EventEnum.eventTwo));
}

test "systemCount count systems" {
    const TestSystems = struct {
        pub fn hello() void {}
        pub fn world() void {}
    };
    const count = countAndVerifySystems(.{ countAndVerifySystems, TestSystems });

    try testing.expectEqual(3, count);
}

test "createSystemInfo generate accurate system information" {
    const A = struct { a: u32 };
    const testFn = struct {
        pub fn func(a: *A) void {
            a.a += 1;
        }
    }.func;

    const TestSystems = struct {
        pub fn hello(a: *A) void {
            a.a += 1;
        }
        pub fn world(b: A) void {
            _ = b;
        }
    };
    const info = createSystemInfo(3, .{ testFn, TestSystems });

    try testing.expectEqual(3, info.functions.len);
    try testing.expectEqual(3, info.metadata.len);

    try testing.expectEqual(1, comptime info.metadata[0].paramCategories().len);
    try testing.expectEqual(1, comptime info.metadata[1].paramCategories().len);
    try testing.expectEqual(1, comptime info.metadata[2].paramCategories().len);

    const hello_ptr: *const info.function_types[1] = @ptrCast(info.functions[1]);
    var a: A = .{ .a = 0 };
    hello_ptr.*(&a);
    try testing.expectEqual(a.a, 1);
}

test "countRelevantStructuresContainingTs count all relevant structures" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const D = struct {};

    const SA = struct { a: A };
    const SAB = struct { a: A, b: B };
    const SABC = struct { a: A, b: B, c: C };
    const SABD = struct { a: A, b: B, c: C, d: D };
    const structs = &[_]type{ SA, SAB, SABC, SABD };

    try testing.expectEqual(1, countRelevantStructuresContainingTs(structs, &[_]type{D}));
    try testing.expectEqual(4, countRelevantStructuresContainingTs(structs, &[_]type{A}));
    try testing.expectEqual(2, countRelevantStructuresContainingTs(structs, &[_]type{ C, A }));
    try testing.expectEqual(1, countRelevantStructuresContainingTs(structs, &[_]type{ D, C, B, A }));
}

test "indexOfStructuresContainingTs get the index of relevant structures" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const D = struct {};

    const SA = struct { a: A };
    const SAB = struct { a: A, b: B };
    const SABC = struct { a: A, b: B, c: C };
    const SABD = struct { a: A, b: B, c: C, d: D };
    const structs = &[_]type{ SA, SAB, SABC, SABD };

    try testing.expectEqual(
        [_]usize{3},
        indexOfStructuresContainingTs(structs, &[_]type{D}),
    );
    try testing.expectEqual(
        [_]usize{ 0, 1, 2, 3 },
        indexOfStructuresContainingTs(structs, &[_]type{A}),
    );
    try testing.expectEqual(
        [_]usize{ 2, 3 },
        indexOfStructuresContainingTs(structs, &[_]type{ C, A }),
    );
    try testing.expectEqual(
        [_]usize{3},
        indexOfStructuresContainingTs(structs, &[_]type{ D, C, B, A }),
    );
}

test "countTypeMapIndices count expected amount" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const type_counter = countTypeMapIndices(.{ A, B, C }, @TypeOf(.{ C{}, B{}, A{} }));
    try testing.expectEqual(3, type_counter);
}

test "typeMap maps a type tuple to a value tuple" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const type_map = typeMap(.{ A, B, C }, @TypeOf(.{ C{}, B{}, A{} }));
    try testing.expectEqual(3, type_map.len);
    try testing.expectEqual(2, type_map[0]);
    try testing.expectEqual(1, type_map[1]);
    try testing.expectEqual(0, type_map[2]);
}

test "SharedStateStorage generate suitable storage tuple" {
    const A = struct { value: u64 };
    const B = struct { value1: i32, value2: u8 };
    const C = struct { value: u8 };

    // generate type at compile time and let the compiler verify that the type is correct
    const Storage = SharedStateStorage(.{ A, B, C });
    var storage: Storage = undefined;
    storage[0].value = std.math.maxInt(u64);
    storage[1].value1 = 2;
    storage[1].value1 = 2;
    storage[2].value = 4;
}

test "ComponentStorage generate suitable storage tuple" {
    const A = struct { value: u64 };
    const B = struct { value1: i32, value2: u8 };
    const C = struct { value: u8 };

    // generate type at compile time and let the compiler verify that the type is correct
    const Storage = ComponentStorage(&[_]type{ A, B, C });
    var storage: Storage = undefined;
    storage[0] = std.ArrayList(A).init(testing.allocator);
    storage[1] = std.ArrayList(B).init(testing.allocator);
    storage[2] = std.ArrayList(C).init(testing.allocator);
}
