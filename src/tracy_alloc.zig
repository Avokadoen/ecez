const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

pub const Error = error{OutOfMemory};

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
            return Allocator.init(self, alloc, resize, free);
        }

        fn getUnderlyingAllocatorPtr(self: *Self) Allocator {
            if (T == Allocator) return self.underlying_allocator;
            return self.underlying_allocator.allocator();
        }

        pub fn alloc(
            self: *Self,
            n: usize,
            ptr_align: u29,
            len_align: u29,
            ret_addr: usize,
        ) Allocator.Error![]u8 {
            const underlying = self.getUnderlyingAllocatorPtr();
            const result = try underlying.rawAlloc(n, ptr_align, len_align, ret_addr);
            ztracy.Alloc(result.ptr, result.len);
            return result;
        }

        pub fn resize(
            self: *Self,
            buf: []u8,
            buf_align: u29,
            new_len: usize,
            len_align: u29,
            ret_addr: usize,
        ) ?usize {
            const underlying = self.getUnderlyingAllocatorPtr();
            ztracy.Free(buf.ptr);
            const result = underlying.rawResize(buf, buf_align, new_len, len_align, ret_addr);
            ztracy.Alloc(buf.ptr, new_len);
            return result;
        }

        pub fn free(
            self: *Self,
            buf: []u8,
            buf_align: u29,
            ret_addr: usize,
        ) void {
            const underlying = self.getUnderlyingAllocatorPtr();
            ztracy.Free(buf.ptr);
            underlying.rawFree(buf, buf_align, ret_addr);
        }

        pub usingnamespace if (T == Allocator or !@hasDecl(T, "reset")) struct {} else struct {
            pub fn reset(self: *Self) void {
                self.underlying_allocator.reset();
            }
        };
    };
}
