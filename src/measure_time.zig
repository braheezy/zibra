const std = @import("std");
const Mutex = @import("sync.zig").Mutex;

pub const MeasureTime = struct {
    const ThreadInfo = struct {
        tid: std.Thread.Id,
        name: []u8,
    };

    file: ?std.Io.File,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    needs_comma: bool,
    lock: Mutex,
    thread_infos: std.ArrayList(ThreadInfo),
    enabled: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
    ) !MeasureTime {
        const enabled = isTracingEnabled(environ);
        var file: ?std.Io.File = null;
        if (enabled) {
            const cwd = std.Io.Dir.cwd();
            const trace_file = try cwd.createFile(
                io,
                "browser.trace",
                .{
                    .truncate = true,
                },
            );
            try trace_file.writeStreamingAll(io, "{\"traceEvents\": [");
            const ts = std.Io.Clock.real.now(io).toMicroseconds();
            const metadata = try std.fmt.allocPrint(allocator, "{{ \"name\": \"process_name\", \"ph\": \"M\", \"ts\": {d}, \"pid\": 1, \"cat\": \"__metadata\", \"args\": {{\"name\": \"Browser\"}}}}", .{ts});
            defer allocator.free(metadata);
            try trace_file.writeStreamingAll(io, metadata);
            file = trace_file;
        }

        const thread_infos = std.ArrayList(ThreadInfo).empty;
        return MeasureTime{
            .file = file,
            .io = io,
            .environ = environ,
            .allocator = allocator,
            .needs_comma = true,
            .lock = .init(io),
            .thread_infos = thread_infos,
            .enabled = enabled,
        };
    }

    pub fn time(self: *MeasureTime, name: []const u8) !void {
        if (!self.enabled) return;
        try self.writeEvent("B", name);
    }

    pub fn stop(self: *MeasureTime, name: []const u8) !void {
        if (!self.enabled) return;
        try self.writeEvent("E", name);
    }

    pub fn begin(self: *MeasureTime, name: []const u8) bool {
        _ = self.time(name) catch |err| {
            std.log.warn("Failed to start {s} trace: {}", .{ name, err });
            return false;
        };
        return true;
    }
    pub fn end(self: *MeasureTime, name: []const u8) void {
        _ = self.stop(name) catch |err| {
            std.log.warn("Failed to stop {s} trace: {}", .{ name, err });
        };
    }

    pub fn registerThread(self: *MeasureTime, name: []const u8) !void {
        if (!self.enabled) return;
        const tid = std.Thread.getCurrentId();
        self.lock.lock();
        defer self.lock.unlock();

        for (self.thread_infos.items) |info| {
            if (info.tid == tid) {
                return;
            }
        }

        const name_buf = try self.allocator.alloc(u8, name.len);
        std.mem.copyForwards(u8, name_buf, name);
        try self.thread_infos.append(self.allocator, .{ .tid = tid, .name = name_buf });
    }

    fn writeEvent(self: *MeasureTime, ph: []const u8, name: []const u8) !void {
        if (!self.enabled) return;
        const file = self.file orelse return;
        self.lock.lock();
        defer self.lock.unlock();

        if (self.needs_comma) {
            try file.writeStreamingAll(self.io, ", ");
        }
        const ts = std.Io.Clock.real.now(self.io).toMicroseconds();
        const tid = std.Thread.getCurrentId();
        const tid_num = @as(usize, tid);
        const event = try std.fmt.allocPrint(self.allocator, "{{ \"ph\": \"{s}\", \"cat\": \"_\", \"name\": \"{s}\", \"ts\": {d}, \"pid\": 1, \"tid\": {d} }}", .{ ph, name, ts, tid_num });
        defer self.allocator.free(event);
        try file.writeStreamingAll(self.io, event);
        self.needs_comma = true;
    }

    pub fn finish(self: *MeasureTime) void {
        if (!self.enabled) return;
        const file = self.file orelse return;
        self.lock.lock();
        defer self.lock.unlock();

        for (self.thread_infos.items) |info| {
            const tid_num = @as(usize, info.tid);
            const tid_str = std.fmt.allocPrint(self.allocator, "{d}", .{tid_num}) catch |err| {
                std.log.warn("Failed to format thread tid: {}", .{err});
                self.allocator.free(info.name);
                continue;
            };
            defer self.allocator.free(tid_str);

            const args_prefix = "{ \"name\": \"";
            const args_suffix = "\" }";
            const args_buf_len = args_prefix.len + info.name.len + args_suffix.len;
            const args_buf = self.allocator.alloc(u8, args_buf_len) catch |err| {
                std.log.warn("Failed to build thread args: {}", .{err});
                self.allocator.free(info.name);
                continue;
            };
            defer self.allocator.free(args_buf);
            std.mem.copyForwards(u8, args_buf[0..args_prefix.len], args_prefix);
            std.mem.copyForwards(u8, args_buf[args_prefix.len .. args_prefix.len + info.name.len], info.name);
            std.mem.copyForwards(u8, args_buf[args_prefix.len + info.name.len ..], args_suffix);

            const metadata_prefix = "{ \"ph\": \"M\", \"name\": \"thread_name\", \"pid\": 1, \"tid\": ";
            const metadata_middle = ", \"args\": ";
            const metadata_suffix = " }";
            const metadata_len = metadata_prefix.len + tid_str.len + metadata_middle.len + args_buf.len + metadata_suffix.len;
            const metadata = self.allocator.alloc(u8, metadata_len) catch |err| {
                std.log.warn("Failed to allocate thread metadata: {}", .{err});
                self.allocator.free(info.name);
                continue;
            };
            defer self.allocator.free(metadata);
            std.mem.copyForwards(u8, metadata[0..metadata_prefix.len], metadata_prefix);
            var write_index = metadata_prefix.len;
            std.mem.copyForwards(u8, metadata[write_index .. write_index + tid_str.len], tid_str);
            write_index += tid_str.len;
            std.mem.copyForwards(u8, metadata[write_index .. write_index + metadata_middle.len], metadata_middle);
            write_index += metadata_middle.len;
            std.mem.copyForwards(u8, metadata[write_index .. write_index + args_buf.len], args_buf);
            write_index += args_buf.len;
            std.mem.copyForwards(u8, metadata[write_index .. write_index + metadata_suffix.len], metadata_suffix);

            if (self.needs_comma) {
                _ = file.writeStreamingAll(self.io, ", ") catch |err| {
                    std.log.warn("Failed to write trace comma: {}", .{err});
                };
            }
            _ = file.writeStreamingAll(self.io, metadata) catch |err| {
                std.log.warn("Failed to write thread metadata: {}", .{err});
            };
            self.needs_comma = true;
            self.allocator.free(info.name);
        }
        self.thread_infos.deinit(self.allocator);

        _ = file.writeStreamingAll(self.io, "]}") catch |err| {
            std.log.warn("Failed to finish trace file: {}", .{err});
        };
        _ = file.sync(self.io) catch |err| {
            std.log.warn("Failed to sync trace file: {}", .{err});
        };
        file.close(self.io);
    }

    fn isTracingEnabled(environ: *const std.process.Environ.Map) bool {
        const env = environ.get("ZIBRA_TRACE") orelse return false;
        if (env.len == 0) return false;
        return !std.mem.eql(u8, env, "0");
    }
};
