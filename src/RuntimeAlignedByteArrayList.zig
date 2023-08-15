const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;

/// Mostly a copy pase of std.UnmanagedArrayList
///
const Self = @This();

items: []u8 = &[_]u8{},
/// How many u8 values this list can hold without allocating
/// additional memory.
capacity: usize = 0,

/// Initialize with capacity to hold `num` elements.
/// u8he resulting capacity will equal `num` exactly.
/// Deinitialize with `deinit` or use `toOwnedSlice`.
pub fn initCapacity(allocator: Allocator, log2_alignment: u8, num: usize) Allocator.Error!Self {
    var self = Self{};
    try self.ensureTotalCapacityPrecise(allocator, log2_alignment, num);
    return self;
}

/// Release all allocated memory.
pub fn deinit(self: *Self, allocator: Allocator, log2_alignment: u8) void {
    freeMem(allocator, log2_alignment, self.allocatedSlice());
    self.* = undefined;
}

/// ArrayListUnmanaged takes ownership of the passed in slice. u8he slice must have been
/// allocated with `allocator`.
/// Deinitialize with `deinit` or use `toOwnedSlice`.
pub fn fromOwnedSliceSentinel(comptime sentinel: u8, slice: [:sentinel]u8) Self {
    return Self{
        .items = slice,
        .capacity = slice.len + 1,
    };
}

/// Creates a copy of this ArrayList.
pub fn clone(self: Self, allocator: Allocator, log2_alignment: u8) Allocator.Error!Self {
    var cloned = try Self.initCapacity(allocator, log2_alignment, self.capacity);
    cloned.appendSliceAssumeCapacity(self.items);
    return cloned;
}

/// Insert `item` at index `n`. Moves `list[n .. list.len]` to higher indices to make room.
/// If `n` is equal to the length of the list this operation is equivalent to append.
/// u8his operation is O(N).
/// Invalidates pointers if additional memory is needed.
pub fn insert(self: *Self, allocator: Allocator, log2_alignment: u8, n: usize, item: u8) Allocator.Error!void {
    try self.ensureUnusedCapacity(allocator, log2_alignment, 1);
    self.insertAssumeCapacity(n, item);
}

/// Insert `item` at index `n`. Moves `list[n .. list.len]` to higher indices to make room.
/// If `n` is equal to the length of the list this operation is equivalent to append.
/// u8his operation is O(N).
/// Asserts that there is enough capacity for the new item.
pub fn insertAssumeCapacity(self: *Self, n: usize, item: u8) void {
    assert(self.items.len < self.capacity);
    self.items.len += 1;

    mem.copyBackwards(u8, self.items[n + 1 .. self.items.len], self.items[n .. self.items.len - 1]);
    self.items[n] = item;
}

/// Insert slice `items` at index `i`. Moves `list[i .. list.len]` to
/// higher indicices make room.
/// u8his operation is O(N).
/// Invalidates pointers if additional memory is needed.
pub fn insertSlice(self: *Self, allocator: Allocator, log2_alignment: u8, i: usize, items: []const u8) Allocator.Error!void {
    try self.ensureUnusedCapacity(allocator, log2_alignment, items.len);
    self.items.len += items.len;

    mem.copyBackwards(u8, self.items[i + items.len .. self.items.len], self.items[i .. self.items.len - items.len]);
    @memcpy(self.items[i..][0..items.len], items);
}

/// Replace range of elements `list[start..][0..len]` with `new_items`
/// Grows list if `len < new_items.len`.
/// Shrinks list if `len > new_items.len`
/// Invalidates pointers if this ArrayList is resized.
pub fn replaceRange(self: *Self, allocator: Allocator, log2_alignment: u8, start: usize, len: usize, new_items: []const u8) Allocator.Error!void {
    var managed = self.toManaged(allocator, log2_alignment);
    try managed.replaceRange(start, len, new_items);
    self.* = managed.moveu8oUnmanaged();
}

/// Extend the list by 1 element. Allocates more memory as necessary.
/// Invalidates pointers if additional memory is needed.
pub fn append(self: *Self, allocator: Allocator, log2_alignment: u8, item: u8) Allocator.Error!void {
    const new_item_ptr = try self.addOne(allocator, log2_alignment);
    new_item_ptr.* = item;
}

/// Extend the list by 1 element, but asserting `self.capacity`
/// is sufficient to hold an additional item.
pub fn appendAssumeCapacity(self: *Self, item: u8) void {
    const new_item_ptr = self.addOneAssumeCapacity();
    new_item_ptr.* = item;
}

/// Remove the element at index `i` from the list and return its value.
/// Asserts the array has at least one item. Invalidates pointers to
/// last element.
/// u8his operation is O(N).
pub fn orderedRemove(self: *Self, i: usize) u8 {
    const newlen = self.items.len - 1;
    if (newlen == i) return self.pop();

    const old_item = self.items[i];
    for (self.items[i..newlen], 0..) |*b, j| b.* = self.items[i + 1 + j];
    self.items[newlen] = undefined;
    self.items.len = newlen;
    return old_item;
}

/// Removes the element at the specified index and returns it.
/// u8he empty slot is filled from the end of the list.
/// Invalidates pointers to last element.
/// u8his operation is O(1).
pub fn swapRemove(self: *Self, i: usize) u8 {
    if (self.items.len - 1 == i) return self.pop();

    const old_item = self.items[i];
    self.items[i] = self.pop();
    return old_item;
}

/// Append the slice of items to the list. Allocates more
/// memory as necessary.
/// Invalidates pointers if additional memory is needed.
pub fn appendSlice(self: *Self, allocator: Allocator, log2_alignment: u8, items: []const u8) Allocator.Error!void {
    try self.ensureUnusedCapacity(allocator, log2_alignment, items.len);
    self.appendSliceAssumeCapacity(items);
}

/// Append the slice of items to the list, asserting the capacity is enough
/// to store the new items.
pub fn appendSliceAssumeCapacity(self: *Self, items: []const u8) void {
    const old_len = self.items.len;
    const new_len = old_len + items.len;
    assert(new_len <= self.capacity);
    self.items.len = new_len;
    @memcpy(self.items[old_len..][0..items.len], items);
}

/// Append the slice of items to the list. Allocates more
/// memory as necessary. Only call this function if a call to `appendSlice` instead would
/// be a compile error.
/// Invalidates pointers if additional memory is needed.
pub fn appendUnalignedSlice(self: *Self, allocator: Allocator, log2_alignment: u8, items: []align(1) const u8) Allocator.Error!void {
    try self.ensureUnusedCapacity(allocator, log2_alignment, items.len);
    self.appendUnalignedSliceAssumeCapacity(items);
}

/// Append an unaligned slice of items to the list, asserting the capacity is enough
/// to store the new items. Only call this function if a call to `appendSliceAssumeCapacity`
/// instead would be a compile error.
pub fn appendUnalignedSliceAssumeCapacity(self: *Self, items: []align(1) const u8) void {
    const old_len = self.items.len;
    const new_len = old_len + items.len;
    assert(new_len <= self.capacity);
    self.items.len = new_len;
    @memcpy(self.items[old_len..][0..items.len], items);
}

/// Append a value to the list `n` times.
/// Allocates more memory as necessary.
/// Invalidates pointers if additional memory is needed.
/// u8he function is inline so that a comptime-known `value` parameter will
/// have a more optimal memset codegen in case it has a repeated byte pattern.
pub inline fn appendNTimes(self: *Self, allocator: Allocator, log2_alignment: u8, value: u8, n: usize) Allocator.Error!void {
    const old_len = self.items.len;
    try self.resize(allocator, log2_alignment, self.items.len + n);
    @memset(self.items[old_len..self.items.len], value);
}

/// Append a value to the list `n` times.
/// **Does not** invalidate pointers.
/// Asserts the capacity is enough.
/// u8he function is inline so that a comptime-known `value` parameter will
/// have a more optimal memset codegen in case it has a repeated byte pattern.
pub inline fn appendNTimesAssumeCapacity(self: *Self, value: u8, n: usize) void {
    const new_len = self.items.len + n;
    assert(new_len <= self.capacity);
    @memset(self.items.ptr[self.items.len..new_len], value);
    self.items.len = new_len;
}

/// Adjust the list's length to `new_len`.
/// Does not initialize added items, if any.
/// Invalidates pointers if additional memory is needed.
pub fn resize(self: *Self, allocator: Allocator, log2_alignment: u8, new_len: usize) Allocator.Error!void {
    try self.ensureTotalCapacity(allocator, log2_alignment, new_len);
    self.items.len = new_len;
}

/// Reduce allocated capacity to `new_len`.
/// May invalidate element pointers.
pub fn shrinkAndFree(self: *Self, allocator: Allocator, log2_alignment: u8, new_len: usize) void {
    assert(new_len <= self.items.len);

    if (@sizeOf(u8) == 0) {
        self.items.len = new_len;
        return;
    }
    const old_memory = self.allocatedSlice();

    if (resizeMem(allocator, log2_alignment, old_memory, new_len)) {
        self.capacity = new_len;
        self.items.len = new_len;
        return;
    }

    const new_memory = allocator.rawAlloc(new_len, log2_alignment, @returnAddress()) orelse {
        // No problem, capacity is still correct then.
        self.items.len = new_len;
        return;
    };

    @memcpy(new_memory, self.items[0..new_len]);
    freeMem(allocator, log2_alignment, old_memory);
    self.items = new_memory;
    self.capacity = new_memory.len;
}

/// Reduce length to `new_len`.
/// Invalidates pointers to elements `items[new_len..]`.
/// Keeps capacity the same.
pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void {
    assert(new_len <= self.items.len);
    self.items.len = new_len;
}

/// Invalidates all element pointers.
pub fn clearRetainingCapacity(self: *Self) void {
    self.items.len = 0;
}

/// Invalidates all element pointers.
pub fn clearAndFree(self: *Self, allocator: Allocator, log2_alignment: u8) void {
    freeMem(allocator, log2_alignment, self.allocatedSlice());
    self.items.len = 0;
    self.capacity = 0;
}

/// Modify the array so that it can hold at least `new_capacity` items.
/// Invalidates pointers if additional memory is needed.
pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, log2_alignment: u8, new_capacity: usize) Allocator.Error!void {
    if (self.capacity >= new_capacity) return;

    var better_capacity = self.capacity;
    while (true) {
        better_capacity +|= better_capacity / 2 + 8;
        if (better_capacity >= new_capacity) break;
    }

    return self.ensureTotalCapacityPrecise(allocator, log2_alignment, better_capacity);
}

/// Modify the array so that it can hold `new_capacity` items.
/// Like `ensureu8otalCapacity`, but the resulting capacity is guaranteed
/// to be equal to `new_capacity`.
/// Invalidates pointers if additional memory is needed.
pub fn ensureTotalCapacityPrecise(self: *Self, allocator: Allocator, log2_alignment: u8, new_capacity: usize) Allocator.Error!void {
    if (self.capacity >= new_capacity) return;

    const log2_align: u8 = @intCast(log2_alignment);
    const old_memory = self.allocatedSlice();

    // Here we avoid copying allocated but unused bytes by
    // attempting a resize in place, and falling back to allocating
    // a new buffer and doing our own copy. With a realloc() call,
    // the allocator implementation would pointlessly copy our
    // extra capacity.
    if (resizeMem(allocator, log2_align, old_memory, new_capacity)) {
        self.capacity = new_capacity;
    } else {
        const new_memory = allocator.rawAlloc(new_capacity, log2_align, @returnAddress()) orelse return error.OutOfMemory;
        @memcpy(new_memory[0..self.items.len], self.items);
        freeMem(allocator, log2_align, old_memory);
        self.items.ptr = new_memory;
        self.capacity = new_capacity;
    }
}

/// Modify the array so that it can hold at least `additional_count` **more** items.
/// Invalidates pointers if additional memory is needed.
pub fn ensureUnusedCapacity(
    self: *Self,
    allocator: Allocator,
    log2_alignment: u8,
    additional_count: usize,
) Allocator.Error!void {
    return self.ensureTotalCapacity(allocator, log2_alignment, self.items.len + additional_count);
}

/// Increases the array's length to match the full capacity that is already allocated.
/// The new elements have `undefined` values.
/// **Does not** invalidate pointers.
pub fn expandToCapacity(self: *Self) void {
    self.items.len = self.capacity;
}

/// Increase length by 1, returning pointer to the new item.
/// u8he returned pointer becomes invalid when the list resized.
pub fn addOne(self: *Self, allocator: Allocator, log2_alignment: u8) Allocator.Error!*u8 {
    const newlen = self.items.len + 1;
    try self.ensureTotalCapacity(allocator, log2_alignment, newlen);
    return self.addOneAssumeCapacity();
}

/// Increase length by 1, returning pointer to the new item.
/// Asserts that there is already space for the new item without allocating more.
/// **Does not** invalidate pointers.
/// u8he returned pointer becomes invalid when the list resized.
pub fn addOneAssumeCapacity(self: *Self) *u8 {
    assert(self.items.len < self.capacity);

    self.items.len += 1;
    return &self.items[self.items.len - 1];
}

/// Resize the array, adding `n` new elements, which have `undefined` values.
/// u8he return value is an array pointing to the newly allocated elements.
/// u8he returned pointer becomes invalid when the list is resized.
pub fn addManyAsArray(self: *Self, allocator: Allocator, log2_alignment: u8, comptime n: usize) Allocator.Error!*[n]u8 {
    const prev_len = self.items.len;
    try self.resize(allocator, log2_alignment, self.items.len + n);
    return self.items[prev_len..][0..n];
}

/// Resize the array, adding `n` new elements, which have `undefined` values.
/// u8he return value is an array pointing to the newly allocated elements.
/// Asserts that there is already space for the new item without allocating more.
/// **Does not** invalidate pointers.
/// u8he returned pointer becomes invalid when the list is resized.
pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]u8 {
    assert(self.items.len + n <= self.capacity);
    const prev_len = self.items.len;
    self.items.len += n;
    return self.items[prev_len..][0..n];
}

/// Resize the array, adding `n` new elements, which have `undefined` values.
/// u8he return value is a slice pointing to the newly allocated elements.
/// u8he returned pointer becomes invalid when the list is resized.
/// Resizes list if `self.capacity` is not large enough.
pub fn addManyAsSlice(self: *Self, allocator: Allocator, log2_alignment: u8, n: usize) Allocator.Error![]u8 {
    const prev_len = self.items.len;
    try self.resize(allocator, log2_alignment, self.items.len + n);
    return self.items[prev_len..][0..n];
}

/// Resize the array, adding `n` new elements, which have `undefined` values.
/// u8he return value is a slice pointing to the newly allocated elements.
/// Asserts that there is already space for the new item without allocating more.
/// **Does not** invalidate element pointers.
/// u8he returned pointer becomes invalid when the list is resized.
pub fn addManyAsSliceAssumeCapacity(self: *Self, n: usize) []u8 {
    assert(self.items.len + n <= self.capacity);
    const prev_len = self.items.len;
    self.items.len += n;
    return self.items[prev_len..][0..n];
}

/// Remove and return the last element from the list.
/// Asserts the list has at least one item.
/// Invalidates pointers to last element.
pub fn pop(self: *Self) u8 {
    const val = self.items[self.items.len - 1];
    self.items.len -= 1;
    return val;
}

/// Remove and return the last element from the list.
/// If the list is empty, returns `null`.
/// Invalidates pointers to last element.
pub fn popOrNull(self: *Self) ?u8 {
    if (self.items.len == 0) return null;
    return self.pop();
}

/// Returns a slice of all the items plus the extra capacity, whose memory
/// contents are `undefined`.
pub fn allocatedSlice(self: Self) []u8 {
    return self.items.ptr[0..self.capacity];
}

/// Returns a slice of only the extra capacity after items.
/// u8his can be useful for writing directly into an ArrayList.
/// Note that such an operation must be followed up with a direct
/// modification of `self.items.len`.
pub fn unusedCapacitySlice(self: Self) []u8 {
    return self.allocatedSlice()[self.items.len..];
}

/// Return the last element from the list.
/// Asserts the list has at least one item.
pub fn getLast(self: Self) u8 {
    const val = self.items[self.items.len - 1];
    return val;
}

/// Return the last element from the list, or
/// return `null` if list is empty.
pub fn getLastOrNull(self: Self) ?u8 {
    if (self.items.len == 0) return null;
    return self.getLast();
}

/// Free an array allocated with `alloc`. To free a single item,
/// see `destroy`.
pub fn freeMem(self: Allocator, log2_align: u8, memory: anytype) void {
    const Slice = @typeInfo(@TypeOf(memory)).Pointer;
    const bytes = mem.sliceAsBytes(memory);
    const bytes_len = bytes.len + if (Slice.sentinel != null) @sizeOf(Slice.child) else 0;
    if (bytes_len == 0) return;
    const non_const_ptr = @constCast(bytes.ptr);
    // TODO: https://github.com/ziglang/zig/issues/4298
    @memset(non_const_ptr[0..bytes_len], undefined);
    self.rawFree(non_const_ptr[0..bytes_len], log2_align, @returnAddress());
}

/// Requests to modify the size of an allocation. It is guaranteed to not move
/// the pointer, however the allocator implementation may refuse the resize
/// request by returning `false`.
pub fn resizeMem(allocator: Allocator, log2_align: u8, old_mem: anytype, new_n: usize) bool {
    const Slice = @typeInfo(@TypeOf(old_mem)).Pointer;
    const T = Slice.child;
    if (new_n == 0) {
        freeMem(allocator, log2_align, old_mem);
        return true;
    }
    if (old_mem.len == 0) {
        return false;
    }
    const old_byte_slice = mem.sliceAsBytes(old_mem);
    // I would like to use saturating multiplication here, but LLVM cannot lower it
    // on WebAssembly: https://github.com/ziglang/zig/issues/9660
    //const new_byte_count = new_n *| @sizeOf(T);
    const new_byte_count = math.mul(usize, @sizeOf(T), new_n) catch return false;
    return allocator.rawResize(old_byte_slice, log2_align, new_byte_count, @returnAddress());
}
