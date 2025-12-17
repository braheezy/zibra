const std = @import("std");

pub const MeasureTime = struct {
    const ThreadInfo = struct {
        tid: std.Thread.Id,
        name: []u8,
    };

    file: std.fs.File,
    allocator: std.mem.Allocator,
    needs_comma: bool,
    lock: std.Thread.Mutex = .{},
    thread_infos: std.ArrayList(ThreadInfo),

    pub fn init(allocator: std.mem.Allocator) !MeasureTime {
        const cwd = std.fs.cwd();
        const file = try cwd.createFile(
            "browser.trace",
            .{
                .truncate = true,
                .mode = 0o644,
            },
        );
        try file.writeAll("{\"traceEvents\": [");
        const ts = @divFloor(std.time.nanoTimestamp(), 1000);
        const metadata = try std.fmt.allocPrint(allocator, "{{ \"name\": \"process_name\", \"ph\": \"M\", \"ts\": {d}, \"pid\": 1, \"cat\": \"__metadata\", \"args\": {{\"name\": \"Browser\"}}}}", .{ts});
        defer allocator.free(metadata);
        try file.writeAll(metadata);
        try file.sync();

        const thread_infos = std.ArrayList(ThreadInfo).empty;
        return MeasureTime{
            .file = file,
            .allocator = allocator,
            .needs_comma = true,
            .lock = .{},
            .thread_infos = thread_infos,
        };
    }

    pub fn time(self: *MeasureTime, name: []const u8) !void {
        try self.writeEvent("B", name);
    }

    pub fn stop(self: *MeasureTime, name: []const u8) !void {
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
        self.lock.lock();
        defer self.lock.unlock();

        if (self.needs_comma) {
            try self.file.writeAll(", ");
        }
        const ts = @divFloor(std.time.nanoTimestamp(), 1000);
        const tid = std.Thread.getCurrentId();
        const tid_num = @as(usize, tid);
        const event = try std.fmt.allocPrint(self.allocator, "{{ \"ph\": \"{s}\", \"cat\": \"_\", \"name\": \"{s}\", \"ts\": {d}, \"pid\": 1, \"tid\": {d} }}", .{ ph, name, ts, tid_num });
        defer self.allocator.free(event);
        try self.file.writeAll(event);
        self.needs_comma = true;
        try self.file.sync();
    }

    pub fn finish(self: *MeasureTime) void {
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
                _ = self.file.writeAll(", ") catch |err| {
                    std.log.warn("Failed to write trace comma: {}", .{err});
                };
            }
            _ = self.file.writeAll(metadata) catch |err| {
                std.log.warn("Failed to write thread metadata: {}", .{err});
            };
            self.needs_comma = true;
            self.allocator.free(info.name);
        }
        self.thread_infos.deinit(self.allocator);

        _ = self.file.writeAll("]}") catch |err| {
            std.log.warn("Failed to finish trace file: {}", .{err});
        };
        _ = self.file.sync() catch |err| {
            std.log.warn("Failed to sync trace file: {}", .{err});
        };
        self.file.close();
    }
};
