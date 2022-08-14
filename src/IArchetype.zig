const std = @import("std");
const builtin = @import("builtin");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const hashType = @import("query.zig").hashType;

// This code is heavily influenced by std.mem.Allocator

const IArchetype = @This();

pub const Error = error{ EntityMissing, ComponentMissing };

// The type erased pointer to the archetype implementation
ptr: *anyopaque,
vtable: *const VTable,

const hasComponentProto = fn (ptr: *anyopaque, type_hash: u64) bool;
const getComponentProto = fn (ptr: *anyopaque, entity: Entity, type_hash: u64) Error![]const u8;
const setComponentProto = fn (ptr: *anyopaque, entity: Entity, type_hash: u64, component: []const u8) Error!void;

pub const VTable = struct {
    hasComponent: switch (builtin.zig_backend) {
        .stage1 => hasComponentProto, // temporary workaround until we replace stage1 with stage2
        else => *const hasComponentProto,
    },

    getComponent: switch (builtin.zig_backend) {
        .stage1 => getComponentProto, // temporary workaround until we replace stage1 with stage2
        else => *const getComponentProto,
    },

    setComponent: switch (builtin.zig_backend) {
        .stage1 => setComponentProto, // temporary workaround until we replace stage1 with stage2
        else => *const setComponentProto,
    },
};

pub fn init(
    pointer: anytype,
    comptime hasComponentFn: fn (ptr: @TypeOf(pointer), type_hash: u64) bool,
    comptime getComponentFn: fn (ptr: @TypeOf(pointer), entity: Entity, type_hash: u64) Error![]const u8,
    comptime setComponentFn: fn (ptr: @TypeOf(pointer), entity: Entity, type_hash: u64, component: []const u8) Error!void,
) IArchetype {
    const Ptr = @TypeOf(pointer);
    const ptr_info = @typeInfo(Ptr);

    std.debug.assert(ptr_info == .Pointer); // Must be a pointer
    std.debug.assert(ptr_info.Pointer.size == .One); // Must be a single-item pointer

    const alignment = ptr_info.Pointer.alignment;

    const gen = struct {
        fn hasComponentImpl(ptr: *anyopaque, type_hash: u64) bool {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, hasComponentFn, .{ self, type_hash });
        }

        fn getComponentImpl(ptr: *anyopaque, entity: Entity, type_hash: u64) Error![]const u8 {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, getComponentFn, .{ self, entity, type_hash });
        }

        fn setComponentImpl(ptr: *anyopaque, entity: Entity, type_hash: u64, component: []const u8) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, setComponentFn, .{ self, entity, type_hash, component });
        }

        const vtable = VTable{
            .hasComponent = hasComponentImpl,
            .getComponent = getComponentImpl,
            .setComponent = setComponentImpl,
        };
    };

    return IArchetype{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn hasComponent(self: IArchetype, comptime T: type) bool {
    return self.vtable.hasComponent(self.ptr, comptime hashType(T));
}

pub fn getComponent(self: IArchetype, entity: Entity, comptime T: type) Error!T {
    // TODO: this might return stack memory :/
    const bytes = try self.vtable.getComponent(self.ptr, entity, comptime hashType(T));
    if (@sizeOf(T) <= 0) return T{};
    return @ptrCast(*const T, @alignCast(@alignOf(T), bytes.ptr)).*;
}

pub fn setComponent(self: IArchetype, entity: Entity, component: anytype) Error!void {
    const T = @TypeOf(component);
    const bytes = std.mem.asBytes(&component);
    try self.vtable.setComponent(self.ptr, entity, comptime hashType(T), bytes);
}
