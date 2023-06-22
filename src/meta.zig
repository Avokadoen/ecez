const std = @import("std");
const FnInfo = std.builtin.Type.Fn;
const Type = std.builtin.Type;

const testing = std.testing;

const Entity = @import("entity_type.zig").Entity;

pub const secret_field = "magic_secret_sauce";
pub const shared_secret_field = "shared_magic_secret_sauce";
pub const event_argument_secret_field = "event_magic_secret_sauce";
pub const system_depend_on_secret_field = "system_depend_on_secret_sauce";
pub const view_secret_field = "view_secret_sauce";
pub const event_magic = 0xaa_bb_cc;

const DependOnRange = struct {
    to: u32,
    from: u32,
};

pub const SystemMetadata = struct {
    pub const Arg = enum {
        component_ptr,
        component_value,
        entity,
        event_argument_ptr,
        event_argument_value,
        shared_state_ptr,
        shared_state_value,
        view,
    };

    depend_on_indices_range: ?DependOnRange,

    fn_info: FnInfo,
    component_params_count: usize,
    params: []const Arg,
    has_entity_argument: bool,

    /// initalize metadata for a system using a supplied function type info
    pub fn init(
        comptime depend_on_indices_range: ?DependOnRange,
        comptime function_type: type,
        comptime fn_info: FnInfo,
    ) SystemMetadata {
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

        if (fn_info.return_type) |return_type| {
            switch (@typeInfo(return_type)) {
                .ErrorUnion => |err| {
                    if (@typeInfo(err.payload) != .Void) {
                        @compileError("system " ++ function_name ++ " return type has to be void or !void, was " ++ @typeName(return_type));
                    }
                    // TODO: remove this error: https://github.com/Avokadoen/ecez/issues/57
                    @compileError("systems " ++ function_name ++ "return error which is currently not supported, please see https://github.com/Avokadoen/ecez/issues/57");
                },
                .Void => {}, // continue
                else => @compileError("system " ++ function_name ++ " return type has to be void or !void, was " ++ @typeName(return_type)),
            }
        }

        const ParsingState = enum {
            component_parsing,
            not_component_parsing,
        };

        var has_entity_argument: bool = false;
        var component_params_count: usize = 0;
        var parsing_state = ParsingState.component_parsing;
        var params: [fn_info.params.len]Arg = undefined;
        inline for (&params, fn_info.params, 0..) |*param, param_info, i| {
            const T = param_info.type orelse {
                const err_msg = std.fmt.comptimePrint("system {s} argument {d} is missing type", .{
                    function_name,
                    i,
                });
                @compileError(err_msg);
            };

            if (i == 0 and T == Entity) {
                param.* = Arg.entity;
                has_entity_argument = true;
                continue;
            } else if (T == Entity) {
                @compileError("entity argument must be the first argument");
            }

            // TODO: refactor this beast
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

                    if (parsing_state == .component_parsing) {
                        // if argument is a shared state argument or event we are done parsing components
                        if (@hasField(pointer.child, shared_secret_field)) {
                            parsing_state = .not_component_parsing;
                            param.* = Arg.shared_state_ptr;
                        } else if (@hasField(pointer.child, view_secret_field)) {
                            @compileError("view argument can't be pointers");
                        } else if (@hasField(pointer.child, event_argument_secret_field)) {
                            parsing_state = .not_component_parsing;
                            param.* = Arg.event_argument_ptr;
                        } else {
                            component_params_count = i + if (has_entity_argument) 0 else 1;
                            param.* = Arg.component_ptr;
                        }
                    } else {
                        // we are now done parsing components which means that any argument
                        // must be either shared state, or an event argument
                        if (@hasField(pointer.child, shared_secret_field)) {
                            param.* = Arg.shared_state_ptr;
                        } else if (@hasField(pointer.child, view_secret_field)) {
                            @compileError("view argument can't be pointers");
                        } else if (@hasField(pointer.child, event_argument_secret_field)) {
                            @compileError("event argument can't be pointers");
                        } else {
                            const pre_arg_str = switch (params[i - 1]) {
                                .component_ptr, .component_value => unreachable,
                                .event_argument_value => "event",
                                .shared_state_ptr, .shared_state_value => "shared state",
                                .view => "view",
                                else => {},
                            };
                            const err_msg = std.fmt.comptimePrint("system {s} argument {d} is a component but comes after {s}", .{
                                pre_arg_str,
                                function_name,
                                i,
                            });
                            @compileError(err_msg);
                        }
                    }
                },
                .Struct => {
                    if (parsing_state == .component_parsing) {
                        // if argument is a shared state argument or event we are done parsing components
                        if (@hasField(T, shared_secret_field)) {
                            parsing_state = .not_component_parsing;
                            param.* = Arg.shared_state_value;
                        } else if (@hasField(T, event_argument_secret_field)) {
                            parsing_state = .not_component_parsing;
                            param.* = Arg.event_argument_value;
                        } else if (@hasField(T, view_secret_field)) {
                            parsing_state = .not_component_parsing;
                            param.* = Arg.view;
                        } else {
                            component_params_count = i + if (has_entity_argument) 0 else 1;
                            param.* = Arg.component_value;
                        }
                    } else {
                        // we are now done parsing components which means that any argument
                        // must be either shared state, or an event argument
                        if (@hasField(T, shared_secret_field)) {
                            param.* = Arg.shared_state_value;
                        } else if (@hasField(T, event_argument_secret_field)) {
                            param.* = Arg.event_argument_value;
                        } else if (@hasField(T, view_secret_field)) {
                            param.* = Arg.view;
                        } else {
                            const pre_arg_str = switch (params[i - 1]) {
                                .component_ptr, .component_value => unreachable,
                                .event_argument_value => "event",
                                .shared_state_ptr, .shared_state_value => "shared state",
                                .view => "view",
                                else => {},
                            };
                            const err_msg = std.fmt.comptimePrint("system {s} argument {d} is a component but comes after {s}", .{
                                pre_arg_str,
                                function_name,
                                i,
                            });
                            @compileError(err_msg);
                        }
                    }
                },
                else => {
                    const err_msg = std.fmt.comptimePrint("system {s} argument {d} is not a struct", .{
                        function_name,
                        i,
                    });
                    @compileError(err_msg);
                },
            }
        }
        return SystemMetadata{
            .depend_on_indices_range = depend_on_indices_range,
            .fn_info = fn_info,
            .component_params_count = component_params_count,
            .params = &params,
            .has_entity_argument = has_entity_argument,
        };
    }

    /// get the function error set type if return is a error union
    pub inline fn errorSet(comptime self: SystemMetadata) ?type {
        if (self.fn_info.return_type) |return_type| {
            const return_info = @typeInfo(return_type);
            if (return_info == .ErrorUnion) {
                return return_info.ErrorUnion.error_set;
            }
        }
        return null;
    }

    /// Get the argument types as proper component types
    /// This function will extrapolate inner types from pointers
    pub fn componentQueryArgTypes(comptime self: SystemMetadata) [self.component_params_count]type {
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
    pub fn paramArgTypes(comptime self: SystemMetadata) [self.params.len]type {
        comptime var params: [self.fn_info.params.len]type = undefined;
        inline for (self.fn_info.params, &params) |arg, *param| {
            param.* = arg.type.?;
        }
        return params;
    }

    pub fn canReturnError(comptime self: SystemMetadata) bool {
        if (self.fn_info.return_type) |return_type| {
            switch (@typeInfo(return_type)) {
                .ErrorUnion => return true,
                else => {},
            }
        }
        return false;
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
        pub const name = event_name;
        pub const s = systems;
        pub const magic_secret_sauce = event_magic;
        pub const system_count = countAndVerifySystems(systems);
        pub const systems_info = createSystemInfo(system_count, systems);
        pub const EventArgument = EventArgumentType;
    };
}

pub fn isEventArgument(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .Struct) {
        return @hasField(T, event_argument_secret_field);
    }
    return false;
}

/// count events and verify arguments
pub fn countAndVerifyEvents(comptime events: anytype) comptime_int {
    const EventsType = @TypeOf(events);
    const events_type_info = @typeInfo(EventsType);
    if (events_type_info != .Struct) {
        @compileError("CreateWorld expected tuple or struct argument for events, got " ++ @typeName(EventsType));
    }

    const fields_info = events_type_info.Struct.fields;
    comptime var event_count = 0;
    // start by counting events registered
    inline for (fields_info, 0..) |field_info, i| {
        switch (@typeInfo(field_info.type)) {
            .Type => {
                switch (@typeInfo(events[i])) {
                    .Struct => {
                        const error_msg = "invalid event type, use ecez.Event() to generate event type";
                        if (@hasDecl(events[i], secret_field) == false) {
                            @compileError(error_msg);
                        }
                        if (@field(events[i], secret_field) != event_magic) {
                            @compileError(error_msg);
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
                        // check if struct is a DependOn generated struct
                        if (std.mem.eql(u8, stru.decls[0].name, system_depend_on_secret_field)) {
                            // should be one inner system at this point
                            systems_count += 1;
                        } else {
                            // it's not a DependOn struct, check each member of the struct to find functions
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
        const system_depend_on_secret_sauce = secret_field;
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
                    systems_info.metadata[i] = SystemMetadata.init(null, field_info.type, func);
                    systems_info.function_types[i] = field_info.type;
                    systems_info.functions[i] = field_info.default_value.?;
                    i += 1;
                },
                .Type => {
                    switch (@typeInfo(systems[j])) {
                        .Struct => |stru| {
                            // check if struct is a DependOn generated struct
                            if (std.mem.eql(u8, stru.decls[0].name, system_depend_on_secret_field)) {
                                const system_depend_on_count = countAndVerifySystems(@field(systems[j], "_depend_on_systems"));
                                const dependency_functions = @field(systems[j], "_depend_on_systems");

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

                                    break :blk DependOnRange{ .from = from, .to = to };
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
                                systems_info.metadata[i] = SystemMetadata.init(depend_on_range, DepSystemDeclType, dep_system_decl_info.Fn);
                                systems_info.function_types[i] = DepSystemDeclType;
                                systems_info.functions[i] = &dep_on_function;
                                i += 1;
                            } else {
                                inline for (stru.decls) |decl| {
                                    const function = @field(systems[j], decl.name);
                                    const DeclType = @TypeOf(function);
                                    const decl_info = @typeInfo(DeclType);
                                    switch (decl_info) {
                                        .Fn => |func| {
                                            // const err_msg = std.fmt.comptimePrint("{d}", .{func.params.len});
                                            // @compileError(err_msg);
                                            systems_info.metadata[i] = SystemMetadata.init(null, DeclType, func);
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
                            if (std.mem.eql(u8, stru.decls[0].name, system_depend_on_secret_field)) {
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

/// used by the View function to get a view of data which can be iterated
pub fn ViewIterator(comptime T: type) type {
    return struct {
        const Iter2D = @This();

        // read only view
        internal: []const []const T,
        inner_arr: []const T,

        outer_index: usize,
        inner_index: usize,

        pub inline fn init(internal: []const []const T) Iter2D {
            return Iter2D{
                .internal = internal,
                .inner_arr = undefined,
                .outer_index = 0,
                .inner_index = std.math.maxInt(usize),
            };
        }

        pub fn next(self: *Iter2D) ?T {
            if (self.inner_index >= self.inner_arr.len) {
                if (self.outer_index < self.internal.len) {
                    self.inner_arr = self.internal[self.outer_index];
                    self.outer_index += 1;
                    self.inner_index = 0;
                } else {
                    return null;
                }
            }

            const rtr_index = self.inner_index;
            self.inner_index += 1;
            return self.inner_arr[rtr_index];
        }
    };
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

    const default_value: u8 = 0;
    shared_state_fields[state_info.fields.len] = Type.StructField{
        .name = shared_secret_field,
        .type = u8,
        .default_value = @ptrCast(?*const anyopaque, &default_value),
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

    const default_value: u8 = 0;
    event_fields[argument_info.fields.len] = Type.StructField{
        .name = event_argument_secret_field,
        .type = u8,
        .default_value = @ptrCast(?*const anyopaque, &default_value),
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

test "SystemMetadata errorSet return null with non-failable functions" {
    const A = struct {};
    const testFn = struct {
        pub fn func(a: A) void {
            _ = a;
        }
    }.func;
    const FuncType = @TypeOf(testFn);
    const metadata = SystemMetadata.init(null, FuncType, @typeInfo(FuncType).Fn);

    try testing.expectEqual(@as(?type, null), metadata.errorSet());
}

// TODO: https://github.com/Avokadoen/ecez/issues/57
// test "SystemMetadata errorSet return error set with failable functions" {
//     const A = struct { b: bool };
//     const TestErrorSet = error{ ErrorOne, ErrorTwo };
//     const testFn = struct {
//         pub fn func(a: A) TestErrorSet!void {
//             if (a.b) {
//                 return TestErrorSet.ErrorOne;
//             }
//             return TestErrorSet.ErrorTwo;
//         }
//     }.func;
//     const FuncType = @TypeOf(testFn);
//     const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);

//     try testing.expectEqual(TestErrorSet, metadata.errorSet().?);
// }

test "SystemMetadata componentQueryArgTypes results in queryable types" {
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
    const metadatas = comptime [3]SystemMetadata{
        SystemMetadata.init(null, Func1Type, @typeInfo(Func1Type).Fn),
        SystemMetadata.init(null, Func2Type, @typeInfo(Func2Type).Fn),
        SystemMetadata.init(null, Func3Type, @typeInfo(Func3Type).Fn),
    };

    inline for (metadatas) |metadata| {
        const params = metadata.componentQueryArgTypes();

        try testing.expectEqual(params.len, 2);
        try testing.expectEqual(A, params[0]);
        try testing.expectEqual(B, params[1]);
    }
}

test "SystemMetadata paramArgTypes results in pointer types" {
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
    const metadatas = comptime [_]SystemMetadata{
        SystemMetadata.init(null, Func1Type, @typeInfo(Func1Type).Fn),
        SystemMetadata.init(null, Func2Type, @typeInfo(Func2Type).Fn),
        SystemMetadata.init(null, Func3Type, @typeInfo(Func3Type).Fn),
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

// TODO: https://github.com/Avokadoen/ecez/issues/57
// test "SystemMetadata canReturnError results in correct type" {
//     const A = struct {};
//     const TestFunctions = struct {
//         pub fn func1(a: A) void {
//             _ = a;
//         }
//         pub fn func2(a: A) !void {
//             _ = a;
//             return error.NotFound;
//         }
//     };

//     {
//         const FuncType = @TypeOf(TestFunctions.func1);
//         const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);
//         try testing.expectEqual(false, metadata.canReturnError());
//     }

//     {
//         const FuncType = @TypeOf(TestFunctions.func2);
//         const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);
//         try testing.expectEqual(true, metadata.canReturnError());
//     }
// }

test "isEventArgument correctly identify event types" {
    const A = struct {};
    comptime try testing.expectEqual(false, isEventArgument(A));
    comptime try testing.expectEqual(true, isEventArgument(EventArgument(A)));
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

    try testing.expectEqual(1, info.metadata[0].params.len);
    try testing.expectEqual(1, info.metadata[1].params.len);
    try testing.expectEqual(1, info.metadata[2].params.len);

    const hello_ptr = @ptrCast(*const info.function_types[1], info.functions[1]);
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

test "ViewIterator can iterate a double array" {
    const Iter = ViewIterator(usize);

    const inner_arr = [3]usize{ 0, 1, 2 };
    const arr: [3][]const usize = .{
        &inner_arr,
        &inner_arr,
        &inner_arr,
    };
    var iter = Iter.init(&arr);
    var i: usize = 0;
    while (iter.next()) |elem| {
        try testing.expectEqual(i % 3, elem);
        i += 1;
    }

    try testing.expectEqual(@as(usize, 9), i);
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
