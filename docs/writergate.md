Writergate

Previous Scandal

All existing std.io readers and writers are deprecated in favor of the newly provided std.Io.Reader and std.Io.Writer which are non-generic and have the buffer above the vtable - in other words the buffer is in the interface, not the implementation. This means that although Reader and Writer are no longer generic, they are still transparent to optimization; all of the interface functions have a concrete hot path operating on the buffer, and only make vtable calls when the buffer is full.

These changes are extremely breaking. I am sorry for that, but I have carefully examined the situation and acquired confidence that this is the direction that Zig needs to go. I hope you will strap in your seatbelt and come along for the ride; it will be worth it.
Motivation

Systems Distributed 2025 Talk: Don't Forget To Flush

    The old interface was generic, poisoning structs that contain them and forcing all functions to be generic as well with anytype. The new interface is concrete.
        Bonus: the concreteness removes temptation to make APIs operate directly on networking streams, file handles, or memory buffers, giving us a more reusable body of code. For example, http.Server after the change no longer depends on std.net - it operates only on streams now.
    The old interface passed errors through rather than defining its own set of error codes. This made errors in streams about as useful as anyerror. The new interface carefully defines precise error sets for each function with actionable meaning.
    The new interface has the buffer in the interface, rather than as a separate "BufferedReader" / "BufferedWriter" abstraction. This is more optimizer friendly, particularly for debug mode.
    The new interface supports high level concepts such as vectors, splatting, and direct file-to-file transfer, which can propagate through an entire graph of readers and writers, reducing syscall overhead, memory bandwidth, and CPU usage.
    The new interface has "peek" functionality - a buffer awareness that offers API convenience for the user as well as simplicity for the implementation.

Adapter API

If you have an old stream and you need a new one, you can use adaptToNewApi() like this:

fn foo(old_writer: anytype) !void {
    var adapter = old_writer.adaptToNewApi(&.{});
    const w: *std.Io.Writer = &adapter.new_interface;
    try w.print("{s}", .{"example"});
    // ...
}

New std.Io.Writer and std.Io.Reader API

These ring buffers have a bunch of handy new APIs that are more convenient, perform better, and are not generic. For instance look at how reading until a delimiter works now:

while (reader.takeDelimiterExclusive('\n')) |line| {
    // do something with line...
} else |err| switch (err) {
    error.EndOfStream, // stream ended not on a line break
    error.StreamTooLong, // line could not fit in buffer
    error.ReadFailed, // caller can check reader implementation for diagnostics
    => |e| return e,
}

These streams also feature some unique concepts compared with other languages' stream implementations:

    The concept of discarding when reading: allows efficiently ignoring data. For instance a decompression stream, when asked to discard a large amount of data, can skip decompression of entire frames.
    The concept of splatting when writing: this allows a logical "memset" operation to pass through I/O pipelines without actually doing any memory copying, turning an O(M*N) operation into O(M) operation, where M is the number of streams in the pipeline and N is the number of repeated bytes. In some cases it can be even more efficient, such as when splatting a zero value that ends up being written to a file; this can be lowered as a seek forward.
    Sending a file when writing: this allows an I/O pipeline to do direct fd-to-fd copying when the operating system supports it.
    The stream user provides the buffer, but the stream implementation decides the minimum buffer size. This effectively moves state from the stream implementation into the user's buffer

std.fs.File.Reader and std.fs.File.Writer

std.fs.File.Reader memoizes key information about a file handle such as:

    The size from calling stat, or the error that occurred therein.
    The current seek position.
    The error that occurred when trying to seek.
    Whether reading should be done positionally or streaming.
    Whether reading should be done via fd-to-fd syscalls (e.g. sendfile)
    versus plain variants (e.g. read).

Fulfills the std.Io.Reader interface.

This API turned out to be super handy in practice. Having a concrete type to pass around that memoizes file size is really nice. Most code that previously was calling seek functions on a file handle should be updated to operate on this API instead, causing those seeks to become no-ops thanks to positional reads, while still supporting a fallback to streaming reading.

std.fs.File.Writer is the same idea but for writing.
Upgrading std.io.getStdOut().writer().print()

Please use buffering! And don't forget to flush!

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

// ...

try stdout.print("...", .{});

// ...

try stdout.flush();

reworked std.compress.flate
Carmen the Allocgator

std.compress API restructured everything to do with flate, which includes zlib and gzip. std.compress.flate.Decompress is your main API now and it has a container parameter.

New API example:

var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &decompress_buffer);
const decompress_reader: *std.Io.Reader = &decompress.reader;

If decompress_reader will be piped entirely to a particular *Writer, then give it an empty buffer:

var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &.{});
const n = try decompress.streamRemaining(writer);

Compression functionality was removed. Sorry, you will have to copy the old code into your application, or use a third party package.

It will be nice to get deflate back into the Zig standard library, but for now, progressing the language takes priority over progressing the standard library, and this change is on the path towards locking in the final language design with respect to I/O as an Interface.

Some notable factors:

    New implementation does not calculate a checksum since it can be done out-of-band.
    New implementation has the fancy match logic replaced with a naive for loop. In the future it would be nice to add a memory copying utility for this that zstd would also use. Despite this, the new implementation performs roughly 10% better in an untar implementation, while reducing compiler code size by 2%. #24614

CountingWriter Deleted

    If you were discarding the bytes, use std.Io.Writer.Discarding, which has a count.
    If you were allocating the bytes, use std.Io.Writer.Allocating, since you can check how much was allocated.
    If you were writing to a fixed buffer, use std.Io.Writer.fixed, and then check the end position.
    Otherwise, try not to create an entire node in the stream graph solely for counting bytes. It's very disruptive to optimal buffering.

BufferedWriter Deleted

const stdout_file = std.fs.File.stdout().writer();
var bw = std.io.bufferedWriter(stdout_file);
const stdout = bw.writer();

try stdout.print("Run `zig build test` to run the tests.\n", .{});

try bw.flush(); // Don't forget to flush!

⬇️

var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

try stdout.print("Run `zig build test` to run the tests.\n", .{});

try stdout.flush(); // Don't forget to flush!

Consider making your stdout buffer global.
"{f}" Required to Call format Methods

Turn on -freference-trace to help you find all the format string breakage.

Example:

std.debug.print("{}", .{std.zig.fmtId("example")});

This will now cause a compile error:

error: ambiguous format string; specify {f} to call format method, or {any} to skip it

Fixed by:

std.debug.print("{f}", .{std.zig.fmtId("example")});

Motivation: eliminate these two footguns:

Introducing a format method to a struct caused a bug if there was formatting code somewhere that prints with {} and then starts rendering differently.

Removing a format method to a struct caused a bug if there was formatting code somewhere that prints with {} and is now changed without notice.

Now, introducing a format method will cause compile errors at all {} sites. In the future, it will have no effect.

Similarly, eliminating a format method will not change any sites that use {}.

Using {f} always tries to call a format method, causing a compile error if none exists.
Format Methods No Longer Have Format Strings or Options

pub fn format(
    this: @This(),
    comptime format_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void { ... }

⬇️

pub fn format(this: @This(), writer: *std.io.Writer) std.io.Writer.Error!void { ... }

The deleted FormatOptions are now for numbers only.

Any state that you got from the format string, there are three suggested alternatives:

    different format methods

pub fn formatB(foo: Foo, writer: *std.io.Writer) std.io.Writer.Error!void { ... }

This can be called with "{f}", .{std.fmt.alt(Foo, .formatB)}.

    std.fmt.Alt

pub fn bar(foo: Foo, context: i32) std.fmt.Alt(F, F.baz) {
    return .{ .data = .{ .context = context } };
}
const F = struct {
    context: i32,
    pub fn baz(f: F, writer: *std.io.Writer) std.io.Writer.Error!void { ... }
};

This can be called with "{f}", .{foo.bar(1234)}.

    return a struct instance that has a format method, combined with {f}.

pub fn bar(foo: Foo, context: i32) F {
    return .{ .context = 1234 };
}
const F = struct {
    context: i32,
    pub fn format(f: F, writer: *std.io.Writer) std.io.Writer.Error!void { ... }
};

This can be called with "{f}", .{foo.bar(1234)}.
Formatted Printing No Longer Deals with Unicode

If you were relying on alignment combined with Unicode codepoints, it is now ASCII/bytes only. The previous implementation was not fully Unicode-aware. If you want to align Unicode strings you need full Unicode support which the standard library does not provide.
New Formatted Printing Specifiers

    {t} is shorthand for @tagName() and @errorName()
    {d} and other integer printing can be used with custom types which calls formatNumber method.
    {b64}: output string as standard base64
