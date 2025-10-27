struct[src]
Fields

vtable: *const VTable

buffer: []u8

seek: usize

Number of bytes which have been consumed from buffer.

end: usize

In buffer before this are buffered bytes, after this is undefined.
Types

    Hashed
    Limited
    VTable

Values
ending	*Reader
ending_instance	Reader

This is generally safe to @constCast because it has an empty buffer, so there is not really a way to accidentally attempt mutation of these fields.
failing	Reader
Functions

pub fn allocRemaining(r: *Reader, gpa: Allocator, limit: Limit) LimitedAllocError![]u8

    Transfers all bytes from the current position to the end of the stream, up to limit, returning them as a caller-owned allocated slice.
pub fn allocRemainingAlignedSentinel( r: *Reader, gpa: Allocator, limit: Limit, comptime alignment: std.mem.Alignment, comptime sentinel: ?u8, ) LimitedAllocError!(if (sentinel) |s| [:s]align(alignment.toByteUnits()) u8 else []align(alignment.toByteUnits()) u8)
pub fn appendRemaining( r: *Reader, gpa: Allocator, list: *ArrayList(u8), limit: Limit, ) LimitedAllocError!void

    Transfers all bytes from the current position to the end of the stream, up to limit, appending them to list.
pub fn appendRemainingAligned( r: *Reader, gpa: Allocator, comptime alignment: std.mem.Alignment, list: *std.array_list.Aligned(u8, alignment), limit: Limit, ) LimitedAllocError!void

    Transfers all bytes from the current position to the end of the stream, up to limit, appending them to list.
pub fn appendRemainingUnlimited(r: *Reader, gpa: Allocator, list: *ArrayList(u8)) UnlimitedAllocError!void
pub fn buffered(r: *Reader) []u8
pub fn bufferedLen(r: *const Reader) usize
pub fn defaultDiscard(r: *Reader, limit: Limit) Error!usize
pub fn defaultReadVec(r: *Reader, data: [][]u8) Error!usize

    Writes to Reader.buffer or data, whichever has larger capacity.
pub fn defaultRebase(r: *Reader, capacity: usize) RebaseError!void
pub fn discard(r: *Reader, limit: Limit) Error!usize
pub fn discardAll(r: *Reader, n: usize) Error!void

    Skips the next n bytes from the stream, advancing the seek position.
pub fn discardAll64(r: *Reader, n: u64) Error!void
pub fn discardDelimiterExclusive(r: *Reader, delimiter: u8) ShortError!usize

    Reads from the stream until specified byte is found, discarding all data, excluding the delimiter.
pub fn discardDelimiterInclusive(r: *Reader, delimiter: u8) Error!usize

    Reads from the stream until specified byte is found, discarding all data, including the delimiter.
pub fn discardDelimiterLimit(r: *Reader, delimiter: u8, limit: Limit) DiscardDelimiterLimitError!usize

    Reads from the stream until specified byte is found, discarding all data, excluding the delimiter.
pub fn discardRemaining(r: *Reader) ShortError!usize

    Consumes the stream until the end, ignoring all the data, returning the number of bytes discarded.
pub fn discardShort(r: *Reader, n: usize) ShortError!usize

    Skips the next n bytes from the stream, advancing the seek position.
pub fn fill(r: *Reader, n: usize) Error!void

    Fills the buffer such that it contains at least n bytes, without advancing the seek position.
pub fn fillMore(r: *Reader) Error!void

    Without advancing the seek position, does exactly one underlying read, filling the buffer as much as possible. This may result in zero bytes added to the buffer, which is not an end of stream condition. End of stream is communicated via returning error.EndOfStream.
pub fn fixed(buffer: []const u8) Reader

    Constructs a Reader such that it will read from buffer and then end.
pub fn hashed(r: *Reader, hasher: anytype, buffer: []u8) Hashed(@TypeOf(hasher))
pub fn limited(r: *Reader, limit: Limit, buffer: []u8) Limited
pub fn peek(r: *Reader, n: usize) Error![]u8

    Returns the next len bytes from the stream, filling the buffer as necessary.
pub fn peekArray(r: *Reader, comptime n: usize) Error!*[n]u8

    Returns the next n bytes from the stream as an array, filling the buffer as necessary, without advancing the seek position.
pub fn peekByte(r: *Reader) Error!u8

    Returns the next byte from the stream or returns error.EndOfStream.
pub fn peekDelimiterExclusive(r: *Reader, delimiter: u8) DelimiterError![]u8

    Returns a slice of the next bytes of buffered data from the stream until delimiter is found, without advancing the seek position.
pub fn peekDelimiterInclusive(r: *Reader, delimiter: u8) DelimiterError![]u8

    Returns a slice of the next bytes of buffered data from the stream until delimiter is found, without advancing the seek position.
pub fn peekGreedy(r: *Reader, n: usize) Error![]u8

    Returns all the next buffered bytes, after filling the buffer to ensure it contains at least n bytes.
pub inline fn peekInt(r: *Reader, comptime T: type, endian: std.builtin.Endian) Error!T

    Asserts the buffer was initialized with a capacity at least @bitSizeOf(T) / 8.
pub fn peekSentinel(r: *Reader, comptime sentinel: u8) DelimiterError![:sentinel]u8

    Returns a slice of the next bytes of buffered data from the stream until sentinel is found, without advancing the seek position.
pub inline fn peekStruct(r: *Reader, comptime T: type, endian: std.builtin.Endian) Error!T

    Asserts the buffer was initialized with a capacity at least @sizeOf(T).
pub fn peekStructPointer(r: *Reader, comptime T: type) Error!*align(1) T

    Obtains an unaligned pointer to the beginning of the stream, reinterpreted as a pointer to the provided type, without advancing the seek position.
pub fn readAlloc(r: *Reader, allocator: Allocator, len: usize) ReadAllocError![]u8

    Shortcut for calling readSliceAll with a buffer provided by allocator.
pub fn readSliceAll(r: *Reader, buffer: []u8) Error!void

    Fill buffer with the next buffer.len bytes from the stream, advancing the seek position.
pub inline fn readSliceEndian( r: *Reader, comptime Elem: type, buffer: []Elem, endian: std.builtin.Endian, ) Error!void

    Fill buffer with the next buffer.len bytes from the stream, advancing the seek position.
pub inline fn readSliceEndianAlloc( r: *Reader, allocator: Allocator, comptime Elem: type, len: usize, endian: std.builtin.Endian, ) ReadAllocError![]Elem

    The function is inline to avoid the dead code in case endian is comptime-known and matches host endianness.
pub fn readSliceShort(r: *Reader, buffer: []u8) ShortError!usize

    Fill buffer with the next buffer.len bytes from the stream, advancing the seek position.
pub fn readVec(r: *Reader, data: [][]u8) Error!usize

    Writes bytes from the internally tracked stream position to data.
pub fn readVecAll(r: *Reader, data: [][]u8) Error!void
pub fn rebase(r: *Reader, capacity: usize) RebaseError!void

    Ensures capacity data can be buffered without rebasing.
pub fn stream(r: *Reader, w: *Writer, limit: Limit) StreamError!usize
pub fn streamDelimiter(r: *Reader, w: *Writer, delimiter: u8) StreamError!usize

    Appends to w contents by reading from the stream until delimiter is found. Does not write the delimiter itself.
pub fn streamDelimiterEnding( r: *Reader, w: *Writer, delimiter: u8, ) StreamRemainingError!usize

    Appends to w contents by reading from the stream until delimiter is found. Does not write the delimiter itself.
pub fn streamDelimiterLimit( r: *Reader, w: *Writer, delimiter: u8, limit: Limit, ) StreamDelimiterLimitError!usize

    Appends to w contents by reading from the stream until delimiter is found. Does not write the delimiter itself.
pub fn streamExact(r: *Reader, w: *Writer, n: usize) StreamError!void

    "Pump" exactly n bytes from the reader to the writer.
pub fn streamExact64(r: *Reader, w: *Writer, n: u64) StreamError!void

    "Pump" exactly n bytes from the reader to the writer.
pub fn streamExactPreserve(r: *Reader, w: *Writer, preserve_len: usize, n: usize) StreamError!void

    "Pump" exactly n bytes from the reader to the writer.
pub fn streamRemaining(r: *Reader, w: *Writer) StreamRemainingError!usize

    "Pump" data from the reader to the writer, handling error.EndOfStream as a success case.
pub fn take(r: *Reader, n: usize) Error![]u8

    Equivalent to peek followed by toss.
pub fn takeArray(r: *Reader, comptime n: usize) Error!*[n]u8

    Returns the next n bytes from the stream as an array, filling the buffer as necessary and advancing the seek position n bytes.
pub fn takeByte(r: *Reader) Error!u8

    Reads 1 byte from the stream or returns error.EndOfStream.
pub fn takeByteSigned(r: *Reader) Error!i8

    Same as takeByte except the returned byte is signed.
pub fn takeDelimiter(r: *Reader, delimiter: u8) error{ ReadFailed, StreamTooLong }!?[]u8

    Returns a slice of the next bytes of buffered data from the stream until delimiter is found, advancing the seek position past the delimiter.
pub fn takeDelimiterExclusive(r: *Reader, delimiter: u8) DelimiterError![]u8

    Returns a slice of the next bytes of buffered data from the stream until delimiter is found, advancing the seek position up to the delimiter.
pub fn takeDelimiterInclusive(r: *Reader, delimiter: u8) DelimiterError![]u8

    Returns a slice of the next bytes of buffered data from the stream until delimiter is found, advancing the seek position.
pub fn takeEnum(r: *Reader, comptime Enum: type, endian: std.builtin.Endian) TakeEnumError!Enum

    Reads an integer with the same size as the given enum's tag type. If the integer matches an enum tag, casts the integer to the enum tag and returns it. Otherwise, returns error.InvalidEnumTag.
pub fn takeEnumNonexhaustive(r: *Reader, comptime Enum: type, endian: std.builtin.Endian) Error!Enum

    Reads an integer with the same size as the given nonexhaustive enum's tag type.
pub inline fn takeInt(r: *Reader, comptime T: type, endian: std.builtin.Endian) Error!T

    Asserts the buffer was initialized with a capacity at least @bitSizeOf(T) / 8.
pub fn takeLeb128(r: *Reader, comptime Result: type) TakeLeb128Error!Result

    Read a single LEB128 value as type T, or error.Overflow if the value cannot fit.
pub fn takeSentinel(r: *Reader, comptime sentinel: u8) DelimiterError![:sentinel]u8

    Returns a slice of the next bytes of buffered data from the stream until sentinel is found, advancing the seek position.
pub inline fn takeStruct(r: *Reader, comptime T: type, endian: std.builtin.Endian) Error!T

    Asserts the buffer was initialized with a capacity at least @sizeOf(T).
pub fn takeStructPointer(r: *Reader, comptime T: type) Error!*align(1) T

    Obtains an unaligned pointer to the beginning of the stream, reinterpreted as a pointer to the provided type, advancing the seek position.
pub fn takeVarInt(r: *Reader, comptime Int: type, endian: std.builtin.Endian, n: usize) Error!Int

    Asserts the buffer was initialized with a capacity at least n.
pub fn toss(r: *Reader, n: usize) void

    Skips the next n bytes from the stream, advancing the seek position. This is typically and safely used after peek.
pub fn tossBuffered(r: *Reader) void

    Equivalent to toss(r.bufferedLen()).
pub fn writableVector(r: *Reader, buffer: [][]u8, data: []const []u8) Error!struct { usize, usize }
pub fn writableVectorPosix(r: *Reader, buffer: []std.posix.iovec, data: []const []u8) Error!struct { usize, usize }
pub fn writableVectorWsa( r: *Reader, buffer: []std.os.windows.ws2_32.WSABUF, data: []const []u8, ) Error!struct { usize, usize }

Error Sets

    DelimiterError
    DiscardDelimiterLimitError
    Error
    LimitedAllocError
    ReadAllocError
    RebaseError
    ShortError
    StreamDelimiterLimitError
    StreamError
    StreamRemainingError
    TakeEnumError
    TakeLeb128Error
    UnlimitedAllocError
