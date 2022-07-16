const std = @import("std");
const FnInfo = std.builtin.Type.Fn;

pub const SystemMetadata = struct {
    pub const Arg = enum {
        ptr,
        value,
    };

    function_type: type,
    fn_info: FnInfo,
    args: []const Arg,

    /// initalize metadata for a system using a supplied function type info
    pub fn init(comptime function_type: type, comptime fn_info: FnInfo) SystemMetadata {
        // TODO: include function name in error messages
        //       blocked by issue https://github.com/ziglang/zig/issues/8270
        // used in error messages
        const function_name = @typeName(function_type);
        if (fn_info.is_generic) {
            @compileError("system " ++ function_name ++ " functions cannot use generic arguments");
        }
        if (fn_info.args.len == 0) {
            @compileError("system " ++ function_name ++ " missing component arguments");
        }

        if (fn_info.return_type) |return_type| {
            switch (@typeInfo(return_type)) {
                .ErrorUnion => |err| {
                    if (@typeInfo(err.payload) != .Void) {
                        @compileError("system " ++ function_name ++ " return type has to be void or !void, was " ++ @typeName(return_type));
                    }
                },
                .Void => {}, // continue
                else => @compileError("system " ++ function_name ++ " return type has to be void or !void, was " ++ @typeName(return_type)),
            }
        }

        var args: [fn_info.args.len]Arg = undefined;
        inline for (fn_info.args) |arg, i| {
            if (arg.arg_type) |T| {
                switch (@typeInfo(T)) {
                    .Pointer => |pointer| {
                        if (@typeInfo(pointer.child) != .Struct) {
                            const err_msg = std.fmt.comptimePrint("system {s} argument {d} must point to a component struct", .{
                                function_name,
                                i,
                            });
                            @compileError(err_msg);
                        }
                        args[i] = Arg.ptr;
                    },
                    .Struct => args[i] = Arg.value,
                    else => {
                        const err_msg = std.fmt.comptimePrint("system {s} argument {d} is not a component struct", .{
                            function_name,
                            i,
                        });
                        @compileError(err_msg);
                    },
                }
            } else {
                const err_msg = std.fmt.comptimePrint("system {s} argument {d} is missing component type", .{
                    function_name,
                    i,
                });
                @compileError(err_msg);
            }
        }
        return SystemMetadata{
            .function_type = function_type,
            .fn_info = fn_info,
            .args = args[0..],
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
    /// This function will extrapolate interior types from pointers
    pub fn queryArgTypes(comptime self: SystemMetadata) [self.args.len]type {
        comptime var args: [self.fn_info.args.len]type = undefined;
        inline for (self.fn_info.args) |arg, i| {
            switch (@typeInfo(arg.arg_type.?)) {
                .Pointer => |p| {
                    args[i] = p.child;
                    continue;
                },
                else => {},
            }
            args[i] = arg.arg_type.?;
        }
        return args;
    }

    /// Get the argument types as requested
    /// This function will include pointer types
    pub fn paramArgTypes(comptime self: SystemMetadata) [self.args.len]type {
        comptime var args: [self.fn_info.args.len]type = undefined;
        inline for (self.fn_info.args) |arg, i| {
            args[i] = arg.arg_type.?;
        }
        return args;
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

/// count dispatch systems and verify system argument
pub fn countSystems(comptime systems: anytype) comptime_int {
    const SystemsType = @TypeOf(systems);
    const systems_type_info = @typeInfo(SystemsType);
    if (systems_type_info != .Struct) {
        @compileError("CreateWorld expected tuple or struct argument, found " ++ @typeName(SystemsType));
    }

    const fields_info = systems_type_info.Struct.fields;
    comptime var systems_count = 0;
    // start by counting systems registered
    inline for (fields_info) |field_info, i| {
        switch (@typeInfo(field_info.field_type)) {
            .Fn => systems_count += 1,
            .Type => {
                switch (@typeInfo(systems[i])) {
                    .Struct => |stru| {
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
                    @typeName(field_info.field_type),
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

        metadata: [system_count]SystemMetadata,
        functions: [system_count]*const anyopaque,

        pub fn undef() Self {
            return Self{
                .metadata = undefined,
                .functions = undefined,
            };
        }
    };
}

/// perform compile-time reflection on systems to extrapolate different information about registered ssytems
pub fn systemInfo(comptime system_count: comptime_int, comptime systems: anytype) SystemInfo(system_count) {
    const SystemsType = @TypeOf(systems);
    const systems_type_info = @typeInfo(SystemsType);
    const fields_info = systems_type_info.Struct.fields;
    var systems_info = SystemInfo(system_count).undef();
    {
        comptime var i: usize = 0;
        inline for (fields_info) |field_info, j| {
            switch (@typeInfo(field_info.field_type)) {
                .Fn => |func| {
                    systems_info.metadata[i] = SystemMetadata.init(field_info.field_type, func);
                    systems_info.functions[i] = field_info.default_value.?;
                    i += 1;
                },
                .Type => {
                    switch (@typeInfo(systems[j])) {
                        .Struct => |stru| {
                            inline for (stru.decls) |decl| {
                                const function = @field(systems[j], decl.name);
                                const DeclType = @TypeOf(function);
                                const decl_info = @typeInfo(DeclType);
                                switch (decl_info) {
                                    .Fn => |func| {
                                        // const err_msg = std.fmt.comptimePrint("{d}", .{func.args.len});
                                        // @compileError(err_msg);
                                        systems_info.metadata[i] = SystemMetadata.init(DeclType, func);
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
                        else => {
                            const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct and/or type with functions, got {s}", .{
                                @typeName(field_info.field_type),
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
