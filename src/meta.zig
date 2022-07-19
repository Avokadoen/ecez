const std = @import("std");
const FnInfo = std.builtin.Type.Fn;

const testing = std.testing;

pub const secret_field = "magic_secret_sauce";
pub const event_magic = 0xaa_bb_cc;

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

/// Create an event which can be triggered and dispatch associated systems
/// Parameters:
///     - event_name: the name of the event
///     - systems: the systems that should be dispatched if this event is triggered
pub fn Event(comptime event_name: []const u8, comptime systems: anytype) type {
    if (@typeInfo(@TypeOf(systems)) != .Struct) {
        @compileError("systems must be a tuple of systems");
    }

    return struct {
        pub const name = event_name;
        pub const s = systems;
        pub const magic_secret_sauce = event_magic;
        pub const system_count = countAndVerifySystems(systems);
        pub const systems_info = systemInfo(system_count, systems);
    };
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
    inline for (fields_info) |field_info, i| {
        switch (@typeInfo(field_info.field_type)) {
            .Type => {
                switch (@typeInfo(events[i])) {
                    .Struct => {
                        const Type = events[i];
                        const error_msg = "invalid event type, use ecez.Event() to generate event type";
                        if (@hasDecl(Type, secret_field) == false) {
                            @compileError(error_msg);
                        }
                        if (@field(Type, secret_field) != event_magic) {
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
                    @typeName(field_info.field_type),
                });
                @compileError(err_msg);
            },
        }
    }
    return event_count;
}

pub fn GenerateEventsEnum(comptime event_count: comptime_int, events: anytype) type {
    const EnumField = std.builtin.Type.EnumField;

    const EventsType = @TypeOf(events);
    const events_type_info = @typeInfo(EventsType);
    const fields_info = events_type_info.Struct.fields;

    var enum_fields: [event_count]EnumField = undefined;
    inline for (fields_info) |_, i| {
        enum_fields[i] = EnumField{
            .name = events[i].name,
            .value = i,
        };
    }

    const event_enum_info = std.builtin.Type{ .Enum = .{
        .layout = .Auto,
        .tag_type = usize,
        .fields = &enum_fields,
        .decls = &[0]std.builtin.Type.Declaration{},
        .is_exhaustive = true,
    } };

    return @Type(event_enum_info);
}

/// count dispatch systems and verify system argument
pub fn countAndVerifySystems(comptime systems: anytype) comptime_int {
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

/// perform compile-time reflection on systems to extrapolate different information about registered systems
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

test "SystemMetadata errorSet return null with non-failable functions" {
    const A = struct {};
    const testFn = struct {
        pub fn func(a: A) void {
            _ = a;
        }
    }.func;
    const FuncType = @TypeOf(testFn);
    const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);

    try testing.expectEqual(@as(?type, null), metadata.errorSet());
}

test "SystemMetadata errorSet return error set with failable functions" {
    const A = struct { b: bool };
    const TestErrorSet = error{ ErrorOne, ErrorTwo };
    const testFn = struct {
        pub fn func(a: A) TestErrorSet!void {
            if (a.b) {
                return TestErrorSet.ErrorOne;
            }
            return TestErrorSet.ErrorTwo;
        }
    }.func;
    const FuncType = @TypeOf(testFn);
    const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);

    try testing.expectEqual(TestErrorSet, metadata.errorSet().?);
}

test "SystemMetadata queryArgTypes results in queryable types" {
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
    const metadatas = [3]SystemMetadata{
        SystemMetadata.init(Func1Type, @typeInfo(Func1Type).Fn),
        SystemMetadata.init(Func2Type, @typeInfo(Func2Type).Fn),
        SystemMetadata.init(Func3Type, @typeInfo(Func3Type).Fn),
    };

    inline for (metadatas) |metadata| {
        const args = metadata.queryArgTypes();

        try testing.expectEqual(args.len, 2);
        try testing.expectEqual(A, args[0]);
        try testing.expectEqual(B, args[1]);
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
    const metadatas = [3]SystemMetadata{
        SystemMetadata.init(Func1Type, @typeInfo(Func1Type).Fn),
        SystemMetadata.init(Func2Type, @typeInfo(Func2Type).Fn),
        SystemMetadata.init(Func3Type, @typeInfo(Func3Type).Fn),
    };

    {
        const args = metadatas[0].paramArgTypes();
        try testing.expectEqual(A, args[0]);
        try testing.expectEqual(B, args[1]);
    }
    {
        const args = metadatas[1].paramArgTypes();
        try testing.expectEqual(*A, args[0]);
        try testing.expectEqual(B, args[1]);
    }
    {
        const args = metadatas[2].paramArgTypes();
        try testing.expectEqual(A, args[0]);
        try testing.expectEqual(*B, args[1]);
    }
}

test "SystemMetadata canReturnError results in correct type" {
    const A = struct {};
    const TestFunctions = struct {
        pub fn func1(a: A) void {
            _ = a;
        }
        pub fn func2(a: A) !void {
            _ = a;
            return error.NotFound;
        }
    };

    {
        const FuncType = @TypeOf(TestFunctions.func1);
        const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);
        try testing.expectEqual(false, metadata.canReturnError());
    }

    {
        const FuncType = @TypeOf(TestFunctions.func2);
        const metadata = SystemMetadata.init(FuncType, @typeInfo(FuncType).Fn);
        try testing.expectEqual(true, metadata.canReturnError());
    }
}

test "countEvents count events" {
    const event_count = countAndVerifyEvents(.{
        Event("eventZero", .{}),
        Event("eventOne", .{}),
        Event("eventTwo", .{}),
    });
    try testing.expectEqual(3, event_count);
}

test "GenerateEventEnum generate expected enum" {
    const EventEnum = GenerateEventsEnum(3, .{
        Event("eventZero", .{}),
        Event("eventOne", .{}),
        Event("eventTwo", .{}),
    });
    try testing.expectEqual(0, @enumToInt(EventEnum.eventZero));
    try testing.expectEqual(1, @enumToInt(EventEnum.eventOne));
    try testing.expectEqual(2, @enumToInt(EventEnum.eventTwo));
}

test "systemCount count systems" {
    const TestSystems = struct {
        pub fn hello() void {}
        pub fn world() void {}
    };
    const count = countAndVerifySystems(.{ countAndVerifySystems, TestSystems });

    try testing.expectEqual(3, count);
}

test "systemInfo generate accurate system information" {
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
        pub fn world(b: A) !void {
            _ = b;
            return error.BadStuff;
        }
    };
    const info = systemInfo(3, .{ testFn, TestSystems });

    try testing.expectEqual(3, info.functions.len);
    try testing.expectEqual(3, info.metadata.len);

    try testing.expectEqual(1, info.metadata[0].args.len);
    try testing.expectEqual(1, info.metadata[1].args.len);
    try testing.expectEqual(1, info.metadata[2].args.len);

    const hello_ptr = @ptrCast(*const info.metadata[1].function_type, info.functions[1]);
    var a: A = .{ .a = 0 };
    hello_ptr.*(&a);
    try testing.expectEqual(a.a, 1);
}

test "systemCount count systems" {
    const TestSystems = struct {
        pub fn hello() void {}
        pub fn world() void {}
    };
    const count = countAndVerifySystems(.{ countAndVerifySystems, TestSystems });

    try testing.expectEqual(3, count);
}
