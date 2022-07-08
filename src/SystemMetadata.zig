const std = @import("std");
const FnInfo = std.builtin.Type.Fn;

const max_types = @import("Archetype.zig").max_types;

const SystemMetadata = @This();

pub const Arg = union(enum) {
    immutable: type,
    mutable: type,
};

fn_info: FnInfo,
args: []const Arg,

/// initalize metadata for a system using a supplied function type info
pub fn init(comptime fn_info: FnInfo) SystemMetadata {
    // TODO: include function name in error messages
    if (fn_info.is_generic) {
        @compileError("system " ++ @typeName(@Type(fn_info)) ++ " functions cannot use generic arguments");
    }
    if (fn_info.args.len == 0) {
        @compileError("system " ++ @typeName(@Type(fn_info)) ++ " missing component arguments");
    }

    if (fn_info.return_type) |return_type| {
        switch (@typeInfo(return_type)) {
            .ErrorUnion => |err| {
                if (@typeInfo(err.payload) != .Void) {
                    @compileError("system " ++ @typeName(@Type(fn_info)) ++ " return type has to be void or !void, was " ++ @typeName(return_type));
                }
            },
            .Void => {}, // continue
            else => @compileError("system " ++ @typeName(@Type(fn_info)) ++ " return type has to be void or !void, was " ++ @typeName(return_type)),
        }
    }

    var args: [fn_info.args.len]Arg = undefined;
    inline for (fn_info.args) |arg, i| {
        if (arg.arg_type) |T| {
            switch (@typeInfo(T)) {
                .Pointer => |pointer| {
                    if (@typeInfo(pointer.child) != .Struct) {
                        @compileError("system " ++ @typeName(@Type(fn_info)) ++ " argument " ++ i ++ " type must be components, or pointers to components");
                    }
                    if (pointer.is_const == false) {
                        args[i] = Arg{ .mutable = T };
                        continue;
                    }
                },
                else => {},
            }
            args[i] = Arg{ .immutable = T };
        } else {
            @compileError("system " ++ @typeName(@Type(fn_info)) ++ "argument " ++ i ++ " is missing component type");
        }
    }
    return SystemMetadata{
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

pub fn canReturnError(comptime self: SystemMetadata) bool {
    if (self.fn_info.return_type) |return_type| {
        switch (@typeInfo(return_type)) {
            .ErrorUnion => return true,
            else => {},
        }
    }
    return false;
}
