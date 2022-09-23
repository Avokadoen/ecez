const std = @import("std");
const builtin = @import("builtin");

const entity_type = @import("entity_type.zig");
const Entity = entity_type.Entity;
const hashType = @import("query.zig").hashType;

// This code is heavily influenced by std.mem.Allocator

const IArchetype = @This();

pub const Error = error{ EntityMissing, ComponentMissing, OutOfMemory };

// The type erased pointer to the archetype implementation
ptr: *anyopaque,
vtable: *const VTable,

const hasComponentProto = fn (ptr: *anyopaque, type_hash: u64) bool;
const getComponentProto = fn (ptr: *anyopaque, entity: Entity, type_hash: u64) Error![]const u8;
const setComponentProto = fn (ptr: *anyopaque, entity: Entity, type_hash: u64, component: []const u8) Error!void;
const registerEntityProto = fn (ptr: *anyopaque, entity: Entity, data: []const []const u8) Error!void;
const swapRemoveEntityProto = fn (ptr: *anyopaque, entity: Entity, buffer: [][]u8) Error!void;
const getStorageDataProto = fn (ptr: *anyopaque, component_hashes: []u64, storage: *StorageData) Error!void;
const deinitProto = fn (ptr: *anyopaque) void;

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

    registerEntity: switch (builtin.zig_backend) {
        .stage1 => registerEntityProto, // temporary workaround until we replace stage1 with stage2
        else => *const registerEntityProto,
    },

    swapRemoveEntity: switch (builtin.zig_backend) {
        .stage1 => swapRemoveEntityProto, // temporary workaround until we replace stage1 with stage2
        else => *const swapRemoveEntityProto,
    },

    getStorageData: switch (builtin.zig_backend) {
        .stage1 => getStorageDataProto, // temporary workaround until we replace stage1 with stage2
        else => *const getStorageDataProto,
    },

    deinit: switch (builtin.zig_backend) {
        .stage1 => deinitProto, // temporary workaround until we replace stage1 with stage2
        else => *const deinitProto,
    },
};

pub fn init(
    pointer: anytype,
    comptime hasComponentFn: fn (ptr: @TypeOf(pointer), type_hash: u64) bool,
    comptime getComponentFn: fn (ptr: @TypeOf(pointer), entity: Entity, type_hash: u64) Error![]const u8,
    comptime setComponentFn: fn (ptr: @TypeOf(pointer), entity: Entity, type_hash: u64, component: []const u8) Error!void,
    comptime registerEntityFn: fn (ptr: @TypeOf(pointer), entity: Entity, data: []const []const u8) Error!void,
    comptime swapRemoveEntityFn: fn (ptr: @TypeOf(pointer), entity: Entity, buffer: [][]u8) Error!void,
    comptime getStorageDataFn: fn (ptr: @TypeOf(pointer), component_hashes: []u64, storage: *StorageData) Error!void,
    comptime deinitFn: fn (ptr: @TypeOf(pointer)) void,
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

        fn registerEntityImpl(ptr: *anyopaque, entity: Entity, data: []const []const u8) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, registerEntityFn, .{ self, entity, data });
        }

        fn swapRemoveEntityImpl(ptr: *anyopaque, entity: Entity, buffer: [][]u8) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, swapRemoveEntityFn, .{ self, entity, buffer });
        }

        fn getStorageDataImpl(ptr: *anyopaque, component_hashes: []u64, storage: *StorageData) Error!void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, getStorageDataFn, .{ self, component_hashes, storage });
        }

        fn deinitImpl(ptr: *anyopaque) void {
            const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
            return @call(.{ .modifier = .always_inline }, deinitFn, .{self});
        }

        const vtable = VTable{
            .hasComponent = hasComponentImpl,
            .getComponent = getComponentImpl,
            .setComponent = setComponentImpl,
            .registerEntity = registerEntityImpl,
            .swapRemoveEntity = swapRemoveEntityImpl,
            .getStorageData = getStorageDataImpl,
            .deinit = deinitImpl,
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

pub fn registerEntity(self: IArchetype, entity: Entity, data: []const []const u8) Error!void {
    try self.vtable.registerEntity(self.ptr, entity, data);
}

// TODO: buffer should be optional to skip moving the data
pub fn swapRemoveEntity(self: IArchetype, entity: Entity, buffer: [][]u8) Error!void {
    return self.vtable.swapRemoveEntity(self.ptr, entity, buffer);
}

pub const StorageData = struct {
    inner_len: usize,
    outer: [][]u8,
};
pub fn getStorageData(self: IArchetype, component_hashes: []u64, storage: *StorageData) Error!void {
    return self.vtable.getStorageData(self.ptr, component_hashes, storage);
}

pub fn deinit(self: IArchetype) void {
    self.vtable.deinit(self.ptr);
}
