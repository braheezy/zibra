const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known-folders");
const grapheme = @import("grapheme");
const code_point = @import("code_point");

const browser = @import("browser.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const system_fonts_dirs = switch (builtin.target.os.tag) {
    .macos => [_][]const u8{
        "/Library/Fonts",
        "/System/Library/Fonts",
    },
    .linux => [_][]const u8{
        "/usr/share/fonts/google-noto-sans-cjk-vf-fonts",
    },
    else => @compileError("Unsupported operating system"),
};

pub const Glyph = struct {
    grapheme: []const u8,
    texture: *c.SDL_Texture,
    w: i32,
    h: i32,
};

pub const Font = struct {
    font_handle: *c.TTF_Font,
    // Glyph cache or atlas.
    glyphs: std.StringHashMap(*Glyph),
    line_height: i32,
    font_rw: ?*c.SDL_RWops,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: std.StringHashMap(*Font),
    current_font: ?*Font = null,

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer) !FontManager {
        if (c.TTF_WasInit() == 0) {
            if (c.TTF_Init() != 0) return error.InitFailed;
        }

        return FontManager{
            .allocator = allocator,
            .renderer = renderer,
            .fonts = std.StringHashMap(*Font).init(allocator),
        };
    }

    pub fn deinit(self: FontManager) void {
        var fonts = self.fonts;
        defer fonts.deinit();
        var fonts_it = fonts.iterator();
        while (fonts_it.next()) |entry| {
            var f = entry.value_ptr.*;

            // Destroy glyph textures
            var glyphs_it = f.glyphs.iterator();
            while (glyphs_it.next()) |glyph_entry| {
                c.SDL_DestroyTexture(glyph_entry.value_ptr.*.texture);
                self.allocator.free(glyph_entry.value_ptr.*.grapheme);
                self.allocator.destroy(glyph_entry.value_ptr.*);
            }
            f.glyphs.deinit();

            c.TTF_CloseFont(f.font_handle);

            if (f.font_rw) |rw| {
                std.debug.assert(c.SDL_RWclose(rw) == 0);
            }

            self.allocator.destroy(f);
        }

        c.TTF_Quit();
    }

    pub fn loadFontFromEmbed(self: *FontManager, size: i32) !void {
        const embed_file = @embedFile("ocraext.ttf");
        const name = "ocraext";
        const font_rw = c.SDL_RWFromConstMem(@ptrCast(&embed_file[0]), @as(c_int, embed_file.len)) orelse return error.LoadFailed;
        // Note: TTF_OpenFontRW does not copy data, must keep it valid
        const fh = c.TTF_OpenFontRW(font_rw, 0, size) orelse return error.LoadFailed;

        var font: *Font = try self.allocator.create(Font);
        font.font_handle = fh;
        font.glyphs = std.StringHashMap(Glyph).init(self.allocator);
        font.line_height = c.TTF_FontLineSkip(fh);
        font.font_rw = font_rw;

        try self.fonts.put(name, font);
    }

    /// Loads a system font by searching standard macOS font directories.
    pub fn loadSystemFont(self: *FontManager, name: []const u8, size: i32) !void {
        // Get the user's home directory
        const home_dir = try known_folders.getPath(self.allocator, .home) orelse return error.NoHomeDir;
        defer self.allocator.free(home_dir);

        // Construct the user fonts directory: ~/Library/Fonts
        const user_fonts_dir = try std.fmt.allocPrint(self.allocator, "{s}/Library/Fonts", .{home_dir});
        defer self.allocator.free(user_fonts_dir);

        // We'll store all directories to search
        var expanded_font_dirs = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (expanded_font_dirs.items) |dir| {
                self.allocator.free(dir);
            }
            expanded_font_dirs.deinit();
        }

        // Add the user fonts directory
        {
            const copy = try self.allocator.dupe(u8, user_fonts_dir);
            try expanded_font_dirs.append(copy);
        }

        // Add the system font directories
        for (system_fonts_dirs) |sys_dir| {
            const copy = try self.allocator.dupe(u8, sys_dir);
            try expanded_font_dirs.append(copy);
        }

        // Known font file extensions
        const extensions = [_][]const u8{ ".ttf", ".otf", ".ttc" };

        var font_path: ?[]const u8 = null;

        search_dirs: for (expanded_font_dirs.items) |dir| {
            var dir_path = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch continue;
            defer dir_path.close();

            var dir_entries = dir_path.iterate();
            while (try dir_entries.next()) |file_entry| {
                if (file_entry.kind != .file) continue;

                const filename = file_entry.name;
                // Check if filename ends with a known extension
                var matched = false;
                var base_name: []const u8 = filename;
                for (extensions) |ext| {
                    if (std.ascii.endsWithIgnoreCase(filename, ext)) {
                        // Strip the extension from the filename
                        const base_len = filename.len - ext.len;
                        base_name = filename[0..base_len];
                        matched = true;
                        break;
                    }
                }

                if (!matched) continue;

                // Now check for exact (case-insensitive) equality
                if (std.ascii.eqlIgnoreCase(base_name, name)) {
                    font_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
                    break;
                }
            }

            if (font_path != null) break :search_dirs;
        }

        if (font_path == null) {
            std.log.err("System font '{s}' not found.", .{name});
            return error.FontNotFound;
        }

        // Null-terminate the font path for TTF_OpenFont
        const font_path_z = try sliceToSentinelArray(self.allocator, font_path.?);
        defer self.allocator.free(font_path_z);
        defer self.allocator.free(font_path.?);

        // Open the font using TTF_OpenFont
        const fh = c.TTF_OpenFont(font_path_z, size);
        if (fh == null) {
            if (c.TTF_GetError()) |e| {
                if (e[0] != 0) {
                    std.log.err("TTF Error in loadSystemFont: {s}.", .{e});
                }
            }
            return error.LoadFailed;
        }

        // Create the Font struct
        var font: *Font = try self.allocator.create(Font);
        font.font_handle = fh.?;
        font.glyphs = std.StringHashMap(*Glyph).init(self.allocator);
        font.line_height = c.TTF_FontLineSkip(fh.?);
        font.font_rw = null;

        try self.fonts.put(name, font);
        self.current_font = font;
    }

    pub fn getGlyph(self: *FontManager, f: *Font, gme: []const u8) !*Glyph {
        // Duplicate the grapheme to ensure consistent memory allocation for the key
        const key = try self.allocator.dupe(u8, gme);

        // Check if the glyph is already in the cache
        if (f.glyphs.get(key)) |cached_glyph| {
            // Free the duplicate key since it's not needed
            self.allocator.free(key);
            return cached_glyph;
        }

        // Render the grapheme using TTF_RenderUTF8_Solid
        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        const glyph_surface = c.TTF_RenderUTF8_Solid(
            f.font_handle,
            sentinel_gme,
            c.SDL_Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF },
        );
        if (glyph_surface == null) {
            self.allocator.free(key);
            if (c.TTF_GetError()) |e| {
                if (e[0] != 0) std.log.err("TTF Error in getGlyph: {s}.", .{e});
            }
            return error.RenderFailed;
        }
        defer c.SDL_FreeSurface(glyph_surface);

        // Create a texture from the surface
        const glyph_tex = c.SDL_CreateTextureFromSurface(self.renderer, glyph_surface) orelse {
            self.allocator.free(key);
            if (c.SDL_GetError()) |e| if (e[0] != 0) std.log.err("SDL Error in getGlyph: {s}.", .{e});
            return error.RenderFailed;
        };

        // Cache and return the new glyph
        const surf = glyph_surface.*;
        var new_glyph = try self.allocator.create(Glyph);
        new_glyph.grapheme = key;
        new_glyph.texture = glyph_tex;
        new_glyph.w = surf.w;
        new_glyph.h = surf.h;

        try f.glyphs.put(key, new_glyph);

        return new_glyph;
    }

    pub fn renderText(self: *FontManager, text: []const u8, x: i32, y: i32) !void {
        const font = self.fonts.get(self.current_font) orelse return error.LoadFailed;
        var current_x = x;
        var current_y = y;

        const gd = try grapheme.GraphemeData.init(self.allocator);
        defer gd.deinit();

        const window_width: i32 = browser.window_width;

        var iter = grapheme.Iterator.init(text, &gd);
        while (iter.next()) |gc| {
            if (gc.bytes(text)[0] == '\n') {
                current_y += font.line_height;
                current_x = x;
                continue;
            }

            // For each grapheme cluster, render it as a single unit
            const cluster_bytes = gc.bytes(text);
            const glyph = try self.getGlyph(font, cluster_bytes);

            // Wrap text to the next line if it exceeds the window width
            if (current_x + glyph.w > window_width - browser.h_offset) {
                current_y += font.line_height;
                current_x = x;
            }

            var dst_rect: c.SDL_Rect = .{
                .x = current_x,
                .y = current_y,
                .w = glyph.w,
                .h = glyph.h,
            };

            _ = c.SDL_RenderCopy(self.renderer, glyph.texture, null, &dst_rect);
            current_x += glyph.w;
        }
    }
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
