const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

pub const Error = error{OutOfMemory};

/// Create an allocator from another allocator to inspect allocation in the tracy profiler
pub fn TracyAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        underlying_allocator: T,

        pub fn init(underlying_allocator: T) @This() {
            return .{
                .underlying_allocator = underlying_allocator,
            };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn getUnderlyingAllocatorPtr(self: *Self) Allocator {
            if (T == Allocator) return self.underlying_allocator;
            return self.underlying_allocator.allocator();
        }

        pub fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self = @as(*Self, @ptrCast(@alignCast(ctx)));

            const underlying = self.getUnderlyingAllocatorPtr();
            const result = underlying.rawAlloc(len, ptr_align, ret_addr);
            if (result) |some| {
                ztracy.Alloc(some, len);
            } else {
                ztracy.Alloc(null, 0);
            }
            return result;
        }

        pub fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self = @as(*Self, @ptrCast(@alignCast(ctx)));

            const underlying = self.getUnderlyingAllocatorPtr();
            ztracy.Free(buf.ptr);
            const result = underlying.rawResize(buf, buf_align, new_len, ret_addr);
            ztracy.Alloc(buf.ptr, new_len);
            return result;
        }

        pub fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
            const self = @as(*Self, @ptrCast(@alignCast(ctx)));

            const underlying = self.getUnderlyingAllocatorPtr();
            underlying.rawFree(buf, buf_align, ret_addr);
            ztracy.Free(buf.ptr);
        }

        pub usingnamespace if (T == Allocator or !@hasDecl(T, "reset")) struct {} else struct {
            pub fn reset(self: *Self) void {
                self.underlying_allocator.reset();
            }
        };
    };
}
