Type Function[src]

A contiguous, growable list of arbitrarily aligned items in memory. This is a wrapper around an array of T values aligned to alignment-byte addresses. If the specified alignment is null, then @alignOf(T) is used.

Functions that potentially allocate memory accept an Allocator parameter. Initialize directly or with initCapacity, and deinitialize with deinit or use toOwnedSlice.

Default initialization of this struct is deprecated; use .empty instead.
Parameters

T: type

alignment: ?mem.Alignment

Fields

items: Slice = &[_]T{}

Contents of the list. This field is intended to be accessed directly.

Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation. In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.

capacity: usize = 0

How many T values this list can hold without allocating additional memory.
Types

    SentinelSlice
    Slice

Values
empty	Self

An ArrayList containing no elements.
Functions

pub fn addManyAsArray(self: *Self, gpa: Allocator, comptime n: usize) Allocator.Error!*[n]T

    Resize the array, adding n new elements, which have undefined values. The return value is an array pointing to the newly allocated elements. The returned pointer becomes invalid when the list is resized.
pub fn addManyAsArrayAssumeCapacity(self: *Self, comptime n: usize) *[n]T

    Resize the array, adding n new elements, which have undefined values.
pub fn addManyAsArrayBounded(self: *Self, comptime n: usize) error{OutOfMemory}!*[n]T

    Resize the array, adding n new elements, which have undefined values.
pub fn addManyAsSlice(self: *Self, gpa: Allocator, n: usize) Allocator.Error![]T

    Resize the array, adding n new elements, which have undefined values. The return value is a slice pointing to the newly allocated elements. The returned pointer becomes invalid when the list is resized. Resizes list if self.capacity is not large enough.
pub fn addManyAsSliceAssumeCapacity(self: *Self, n: usize) []T

    Resizes the array, adding n new elements, which have undefined values, returning a slice pointing to the newly allocated elements.
pub fn addManyAsSliceBounded(self: *Self, n: usize) error{OutOfMemory}![]T

    Resizes the array, adding n new elements, which have undefined values, returning a slice pointing to the newly allocated elements.
pub fn addManyAt( self: *Self, gpa: Allocator, index: usize, count: usize, ) Allocator.Error![]T

    Add count new elements at position index, which have undefined values. Returns a slice pointing to the newly allocated elements, which becomes invalid after various ArrayList operations. Invalidates pre-existing pointers to elements at and after index. Invalidates all pre-existing element pointers if capacity must be increased to accommodate the new elements. Asserts that the index is in bounds or equal to the length.
pub fn addManyAtAssumeCapacity(self: *Self, index: usize, count: usize) []T

    Add count new elements at position index, which have undefined values. Returns a slice pointing to the newly allocated elements, which becomes invalid after various ArrayList operations. Invalidates pre-existing pointers to elements at and after index, but does not invalidate any before that. Asserts that the list has capacity for the additional items. Asserts that the index is in bounds or equal to the length.
pub fn addManyAtBounded(self: *Self, index: usize, count: usize) error{OutOfMemory}![]T

    Add count new elements at position index, which have undefined values, returning a slice pointing to the newly allocated elements, which becomes invalid after various ArrayList operations.
pub fn addOne(self: *Self, gpa: Allocator) Allocator.Error!*T

    Increase length by 1, returning pointer to the new item. The returned element pointer becomes invalid when the list is resized.
pub fn addOneAssumeCapacity(self: *Self) *T

    Increase length by 1, returning pointer to the new item.
pub fn addOneBounded(self: *Self) error{OutOfMemory}!*T

    Increase length by 1, returning pointer to the new item.
pub fn allocatedSlice(self: Self) Slice

    Returns a slice of all the items plus the extra capacity, whose memory contents are undefined.
pub fn append(self: *Self, gpa: Allocator, item: T) Allocator.Error!void

    Extend the list by 1 element. Allocates more memory as necessary. Invalidates element pointers if additional memory is needed.
pub fn appendAssumeCapacity(self: *Self, item: T) void

    Extend the list by 1 element.
pub fn appendBounded(self: *Self, item: T) error{OutOfMemory}!void

    Extend the list by 1 element.
pub inline fn appendNTimes(self: *Self, gpa: Allocator, value: T, n: usize) Allocator.Error!void

    Append a value to the list n times. Allocates more memory as necessary. Invalidates element pointers if additional memory is needed. The function is inline so that a comptime-known value parameter will have a more optimal memset codegen in case it has a repeated byte pattern.
pub inline fn appendNTimesAssumeCapacity(self: *Self, value: T, n: usize) void

    Append a value to the list n times.
pub inline fn appendNTimesBounded(self: *Self, value: T, n: usize) error{OutOfMemory}!void

    Append a value to the list n times.
pub fn appendSlice(self: *Self, gpa: Allocator, items: []const T) Allocator.Error!void

    Append the slice of items to the list. Allocates more memory as necessary. Invalidates element pointers if additional memory is needed.
pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void

    Append the slice of items to the list.
pub fn appendSliceBounded(self: *Self, items: []const T) error{OutOfMemory}!void

    Append the slice of items to the list.
pub fn appendUnalignedSlice(self: *Self, gpa: Allocator, items: []align(1) const T) Allocator.Error!void

    Append the slice of items to the list. Allocates more memory as necessary. Only call this function if a call to appendSlice instead would be a compile error. Invalidates element pointers if additional memory is needed.
pub fn appendUnalignedSliceAssumeCapacity(self: *Self, items: []align(1) const T) void

    Append an unaligned slice of items to the list.
pub fn appendUnalignedSliceBounded(self: *Self, items: []align(1) const T) error{OutOfMemory}!void

    Append an unaligned slice of items to the list.
pub fn clearAndFree(self: *Self, gpa: Allocator) void

    Invalidates all element pointers.
pub fn clearRetainingCapacity(self: *Self) void

    Invalidates all element pointers.
pub fn clone(self: Self, gpa: Allocator) Allocator.Error!Self

    Creates a copy of this ArrayList.
pub fn deinit(self: *Self, gpa: Allocator) void

    Release all allocated memory.
pub fn ensureTotalCapacity(self: *Self, gpa: Allocator, new_capacity: usize) Allocator.Error!void

    Modify the array so that it can hold at least new_capacity items. Implements super-linear growth to achieve amortized O(1) append operations. Invalidates element pointers if additional memory is needed.
pub fn ensureTotalCapacityPrecise(self: *Self, gpa: Allocator, new_capacity: usize) Allocator.Error!void

    If the current capacity is less than new_capacity, this function will modify the array so that it can hold exactly new_capacity items. Invalidates element pointers if additional memory is needed.
pub fn ensureUnusedCapacity( self: *Self, gpa: Allocator, additional_count: usize, ) Allocator.Error!void

    Modify the array so that it can hold at least additional_count more items. Invalidates element pointers if additional memory is needed.
pub fn expandToCapacity(self: *Self) void

    Increases the array's length to match the full capacity that is already allocated. The new elements have undefined values. Never invalidates element pointers.
pub fn fromOwnedSlice(slice: Slice) Self

    ArrayList takes ownership of the passed in slice. Deinitialize with deinit or use toOwnedSlice.
pub fn fromOwnedSliceSentinel(comptime sentinel: T, slice: [:sentinel]T) Self

    ArrayList takes ownership of the passed in slice. Deinitialize with deinit or use toOwnedSlice.
pub fn getLast(self: Self) T

    Return the last element from the list. Asserts that the list is not empty.
pub fn getLastOrNull(self: Self) ?T

    Return the last element from the list, or return null if list is empty.
pub fn growCapacity(minimum: usize) usize

    Called when memory growth is necessary. Returns a capacity larger than minimum that grows super-linearly.
pub fn initBuffer(buffer: Slice) Self

    Initialize with externally-managed memory. The buffer determines the capacity, and the length is set to zero.
pub fn initCapacity(gpa: Allocator, num: usize) Allocator.Error!Self

    Initialize with capacity to hold num elements. The resulting capacity will equal num exactly. Deinitialize with deinit or use toOwnedSlice.
pub fn insert(self: *Self, gpa: Allocator, i: usize, item: T) Allocator.Error!void

    Insert item at index i. Moves list[i .. list.len] to higher indices to make room. If i is equal to the length of the list this operation is equivalent to append. This operation is O(N). Invalidates element pointers if additional memory is needed. Asserts that the index is in bounds or equal to the length.
pub fn insertAssumeCapacity(self: *Self, i: usize, item: T) void

    Insert item at index i. Moves list[i .. list.len] to higher indices to make room.
pub fn insertBounded(self: *Self, i: usize, item: T) error{OutOfMemory}!void

    Insert item at index i, moving list[i .. list.len] to higher indices to make room.
pub fn insertSlice( self: *Self, gpa: Allocator, index: usize, items: []const T, ) Allocator.Error!void

    Insert slice items at index i by moving list[i .. list.len] to make room. This operation is O(N). Invalidates pre-existing pointers to elements at and after index. Invalidates all pre-existing element pointers if capacity must be increased to accommodate the new elements. Asserts that the index is in bounds or equal to the length.
pub fn insertSliceAssumeCapacity( self: *Self, index: usize, items: []const T, ) void

    Insert slice items at index i by moving list[i .. list.len] to make room. This operation is O(N). Invalidates pre-existing pointers to elements at and after index. Asserts that the list has capacity for the additional items. Asserts that the index is in bounds or equal to the length.
pub fn insertSliceBounded( self: *Self, index: usize, items: []const T, ) error{OutOfMemory}!void

    Insert slice items at index i by moving list[i .. list.len] to make room. This operation is O(N). Invalidates pre-existing pointers to elements at and after index. If the list lacks unused capacity for the additional items, returns error.OutOfMemory. Asserts that the index is in bounds or equal to the length.
pub fn orderedRemove(self: *Self, i: usize) T

    Remove the element at index i from the list and return its value. Invalidates pointers to the last element. This operation is O(N). Asserts that the index is in bounds.
pub fn orderedRemoveMany(self: *Self, sorted_indexes: []const usize) void

    Remove the elements indexed by sorted_indexes. The indexes to be removed correspond to the array list before deletion.
pub fn pop(self: *Self) ?T

    Remove and return the last element from the list. If the list is empty, returns null. Invalidates pointers to last element.
pub fn print(self: *Self, gpa: Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void
pub fn printAssumeCapacity(self: *Self, comptime fmt: []const u8, args: anytype) void
pub fn printBounded(self: *Self, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void
pub fn replaceRange( self: *Self, gpa: Allocator, start: usize, len: usize, new_items: []const T, ) Allocator.Error!void

    Grows or shrinks the list as necessary. Invalidates element pointers if additional capacity is allocated. Asserts that the range is in bounds.
pub fn replaceRangeAssumeCapacity(self: *Self, start: usize, len: usize, new_items: []const T) void

    Grows or shrinks the list as necessary.
pub fn replaceRangeBounded(self: *Self, start: usize, len: usize, new_items: []const T) error{OutOfMemory}!void

    Grows or shrinks the list as necessary.
pub fn resize(self: *Self, gpa: Allocator, new_len: usize) Allocator.Error!void

    Adjust the list length to new_len. Additional elements contain the value undefined. Invalidates element pointers if additional memory is needed.
pub fn shrinkAndFree(self: *Self, gpa: Allocator, new_len: usize) void

    Reduce allocated capacity to new_len. May invalidate element pointers. Asserts that the new length is less than or equal to the previous length.
pub fn shrinkRetainingCapacity(self: *Self, new_len: usize) void

    Reduce length to new_len. Invalidates pointers to elements items[new_len..]. Keeps capacity the same. Asserts that the new length is less than or equal to the previous length.
pub fn swapRemove(self: *Self, i: usize) T

    Removes the element at the specified index and returns it. The empty slot is filled from the end of the list. Invalidates pointers to last element. This operation is O(1). Asserts that the list is not empty. Asserts that the index is in bounds.
pub fn toManaged(self: *Self, gpa: Allocator) AlignedManaged(T, alignment)

    Convert this list into an analogous memory-managed one. The returned list has ownership of the underlying memory.
pub fn toOwnedSlice(self: *Self, gpa: Allocator) Allocator.Error!Slice

    The caller owns the returned memory. Empties this ArrayList. Its capacity is cleared, making deinit() safe but unnecessary to call.
pub fn toOwnedSliceSentinel(self: *Self, gpa: Allocator, comptime sentinel: T) Allocator.Error!SentinelSlice(sentinel)

    The caller owns the returned memory. ArrayList becomes empty.
pub fn unusedCapacitySlice(self: Self) []T

    Returns a slice of only the extra capacity after items. This can be useful for writing directly into an ArrayList. Note that such an operation must be followed up with a direct modification of self.items.len.
