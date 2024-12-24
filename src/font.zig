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

pub const FontCategory = enum {
    latin,
    cjk,
    emoji,
    fallback,
};

pub const UnicodeRange = struct {
    start: u21,
    end: u21,
};

pub const FontCategoryRanges = struct {
    latin: []const UnicodeRange,
    cjk: []const UnicodeRange,
    emoji: []const UnicodeRange,
};

const unicode_ranges = FontCategoryRanges{
    .latin = &[_]UnicodeRange{
        .{ .start = 0x0000, .end = 0x024F }, // Basic Latin + Latin-1 Supplement
        .{ .start = 0x1E00, .end = 0x1EFF }, // Latin Extended Additional
    },
    .cjk = &[_]UnicodeRange{
        .{ .start = 0x4E00, .end = 0x9FFF }, // CJK Unified Ideographs
        .{ .start = 0x3400, .end = 0x4DBF }, // CJK Unified Ideographs Extension A
        .{ .start = 0x3000, .end = 0x303F }, // CJK Symbols and Punctuation
        .{ .start = 0xFF00, .end = 0xFFEF }, // Fullwidth Forms
        .{ .start = 0x3040, .end = 0x309F }, // Hiragana
        .{ .start = 0x30A0, .end = 0x30FF }, // Katakana
        .{ .start = 0xAC00, .end = 0xD7A3 }, // Hangul Syllables
    },
    .emoji = &[_]UnicodeRange{
        .{ .start = 0x1F300, .end = 0x1F5FF }, // Miscellaneous Symbols and Pictographs
        .{ .start = 0x1F600, .end = 0x1F64F }, // Emoticons
    },
};

const fo = 128512;

const FontEntry = struct {
    name: []const u8,
    category: FontCategory,
};

const system_fonts = switch (builtin.target.os.tag) {
    .macos => struct {
        paths: []const []const u8,
        fonts: []const FontEntry,
    }{
        .paths = &[_][]const u8{
            "/Library/Fonts",
            "/System/Library/Fonts",
            "/System/Library/Fonts/Supplemental",
        },
        .fonts = &[_]FontEntry{
            .{ .name = "Arial Unicode", .category = .latin },
            .{ .name = "Arial Unicode", .category = .cjk },
            .{ .name = "Apple Color Emoji", .category = .emoji },
        },
    },
    .linux => struct {
        paths: []const []const u8,
        fonts: []const FontEntry,
    }{
        .paths = &[_][]const u8{
            "/usr/share/fonts",
            "/usr/local/share/fonts",
        },
        .fonts = &[_]FontEntry{
            .{ .name = "NotoSerif-Regular", .category = .latin },
            .{ .name = "NotoSerifCJK-Regular", .category = .cjk },
            .{ .name = "NotoColorEmoji", .category = .emoji },
        },
    },
    else => @compileError("Unsupported operating system"),
};

pub const Glyph = struct {
    grapheme: []const u8,
    texture: ?*c.SDL_Texture,
    w: i32,
    h: i32,
};

pub const Font = struct {
    font_handle: *c.TTF_Font,
    // Glyph cache or atlas.
    glyphs: std.StringHashMap(Glyph),
    line_height: i32,
    font_rw: ?*c.SDL_RWops,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: std.StringHashMap(Font),
    current_font: ?*Font = null,

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer) !*FontManager {
        if (c.TTF_WasInit() == 0) {
            if (c.TTF_Init() != 0) return error.InitFailed;
        }

        var font_manager = try allocator.create(FontManager);
        font_manager.allocator = allocator;
        font_manager.renderer = renderer;
        font_manager.fonts = std.StringHashMap(Font).init(allocator);
        return font_manager;

        // return FontManager{
        //     .allocator = allocator,
        //     .renderer = renderer,
        //     .fonts = std.StringHashMap(Font).init(allocator),
        // };
    }

    pub fn deinit(self: *FontManager) void {
        var fonts = self.fonts;
        var fonts_it = fonts.iterator();
        while (fonts_it.next()) |entry| {
            var f = entry.value_ptr.*;

            // Destroy glyph textures
            var glyphs_it = f.glyphs.iterator();
            while (glyphs_it.next()) |glyph_entry| {
                c.SDL_DestroyTexture(glyph_entry.value_ptr.*.texture.?);
                self.allocator.free(glyph_entry.value_ptr.*.grapheme);
            }
            f.glyphs.deinit();

            c.TTF_CloseFont(f.font_handle);

            if (f.font_rw) |rw| {
                std.debug.assert(c.SDL_RWclose(rw) == 0);
            }
        }

        fonts.deinit();

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

    fn collectFontPaths(self: *FontManager) !std.ArrayList([]const u8) {
        var paths = std.ArrayList([]const u8).init(self.allocator);

        // Add user font directory first to prefer them.
        const home_dir = try known_folders.getPath(self.allocator, .home) orelse return error.NoHomeDir;
        defer self.allocator.free(home_dir);

        const user_fonts_dir = try std.fmt.allocPrint(self.allocator, "{s}/Library/Fonts", .{home_dir});
        try paths.append(user_fonts_dir);

        // Add system font directories
        for (system_fonts.paths) |dir| {
            const copy = try self.allocator.dupe(u8, dir);
            try paths.append(copy);
        }

        return paths;
    }

    fn tryLoadFontFromPaths(self: *FontManager, name: []const u8, paths: []const []const u8, size: i32) !bool {
        const extensions = [_][]const u8{ ".ttf", ".otf", ".ttc" };

        for (paths) |dir| {
            var dir_path = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch continue;
            defer dir_path.close();

            var dir_entries = dir_path.iterate();
            while (try dir_entries.next()) |file_entry| {
                if (file_entry.kind != .file) continue;

                const filename = file_entry.name;
                for (extensions) |ext| {
                    if (std.ascii.endsWithIgnoreCase(filename, ext)) {
                        const base_name = filename[0 .. filename.len - ext.len];
                        if (std.ascii.eqlIgnoreCase(base_name, name)) {
                            const font_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
                            defer self.allocator.free(font_path);

                            return self.loadFontAtPath(font_path, name, size);
                        }
                    }
                }
            }
        }

        return false;
    }

    fn loadFontAtPath(self: *FontManager, path: []const u8, name: []const u8, size: i32) !bool {
        const path_z = try sliceToSentinelArray(self.allocator, path);
        defer self.allocator.free(path_z);

        const fh = c.TTF_OpenFont(path_z, size);
        if (fh == null) {
            if (c.TTF_GetError()) |e| if (e[0] != 0) {
                std.log.err("TTF Error in loadFontAtPath: {s}", .{e});
            };
            return false;
        }

        // var font: *Font = try self.allocator.create(Font);
        const font = Font{
            .font_handle = fh.?,
            .glyphs = std.StringHashMap(Glyph).init(self.allocator),
            .line_height = c.TTF_FontLineSkip(fh),
            .font_rw = null,
        };

        try self.fonts.put(name, font);
        if (self.current_font == null) {
            self.current_font = self.fonts.get(name);
        }

        return true;
    }

    /// Load all standard system fonts (Latin, CJK, Emoji)
    pub fn loadSystemFont(self: *FontManager, size: i32) !void {
        // Add user font directory to search paths
        var search_paths = try self.collectFontPaths();
        defer {
            for (search_paths.items) |dir| {
                self.allocator.free(dir);
            }
            search_paths.deinit();
        }

        // Iterate through font categories in order of priority
        const categories = [_]FontCategory{ .latin, .cjk, .emoji };
        for (categories) |category| {
            for (system_fonts.fonts) |font| {
                if (font.category != category) continue; // Skip fonts not matching the current category

                if (try self.tryLoadFontFromPaths(font.name, search_paths.items, size)) {
                    std.log.info("Loaded {s} font: {s}", .{ @tagName(category), font.name });
                    break; // Stop searching for this category once loaded
                } else {
                    std.log.warn("Failed to load {s} font: {s}", .{ @tagName(category), font.name });
                }
            }
        }

        // Ensure at least one font is loaded
        if (self.fonts.count() == 0) {
            std.debug.print("No fonts found\n", .{});
            return error.NoFontsLoaded;
        }

        // Set the current font if not already set
        if (self.current_font == null) {
            var it = self.fonts.iterator();
            self.current_font = it.next().?.value_ptr.*;
        }

        // Get the user's home directory
        // const home_dir = try known_folders.getPath(self.allocator, .home) orelse return error.NoHomeDir;
        // defer self.allocator.free(home_dir);

        // // Construct the user fonts directory: ~/Library/Fonts
        // const user_fonts_dir = try std.fmt.allocPrint(self.allocator, "{s}/Library/Fonts", .{home_dir});
        // defer self.allocator.free(user_fonts_dir);

        // // We'll store all directories to search
        // var expanded_font_dirs = std.ArrayList([]const u8).init(self.allocator);
        // defer {
        //     for (expanded_font_dirs.items) |dir| {
        //         self.allocator.free(dir);
        //     }
        //     expanded_font_dirs.deinit();
        // }

        // // Add the user fonts directory
        // {
        //     const copy = try self.allocator.dupe(u8, user_fonts_dir);
        //     try expanded_font_dirs.append(copy);
        // }

        // // Add the system font directories
        // for (system_fonts_dirs) |sys_dir| {
        //     const copy = try self.allocator.dupe(u8, sys_dir);
        //     try expanded_font_dirs.append(copy);
        // }

        // // Known font file extensions
        // const extensions = [_][]const u8{ ".ttf", ".otf", ".ttc" };

        // var font_path: ?[]const u8 = null;

        // search_dirs: for (expanded_font_dirs.items) |dir| {
        //     var dir_path = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch continue;
        //     defer dir_path.close();

        //     var dir_entries = dir_path.iterate();
        //     while (try dir_entries.next()) |file_entry| {
        //         if (file_entry.kind != .file) continue;

        //         const filename = file_entry.name;
        //         // Check if filename ends with a known extension
        //         var matched = false;
        //         var base_name: []const u8 = filename;
        //         for (extensions) |ext| {
        //             if (std.ascii.endsWithIgnoreCase(filename, ext)) {
        //                 // Strip the extension from the filename
        //                 const base_len = filename.len - ext.len;
        //                 base_name = filename[0..base_len];
        //                 matched = true;
        //                 break;
        //             }
        //         }

        //         if (!matched) continue;

        //         // Now check for exact (case-insensitive) equality
        //         if (std.ascii.eqlIgnoreCase(base_name, name)) {
        //             font_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        //             break;
        //         }
        //     }

        //     if (font_path != null) break :search_dirs;
        // }

        // if (font_path == null) {
        //     std.log.err("System font '{s}' not found.", .{name});
        //     return error.FontNotFound;
        // }

        // // Null-terminate the font path for TTF_OpenFont
        // const font_path_z = try sliceToSentinelArray(self.allocator, font_path.?);
        // defer self.allocator.free(font_path_z);
        // defer self.allocator.free(font_path.?);

        // // Open the font using TTF_OpenFont
        // const fh = c.TTF_OpenFont(font_path_z, size);
        // if (fh == null) {
        //     if (c.TTF_GetError()) |e| {
        //         if (e[0] != 0) {
        //             std.log.err("TTF Error in loadSystemFont: {s}.", .{e});
        //         }
        //     }
        //     return error.LoadFailed;
        // }

        // // Create the Font struct
        // var font: *Font = try self.allocator.create(Font);
        // font.font_handle = fh.?;
        // font.glyphs = std.StringHashMap(*Glyph).init(self.allocator);
        // font.line_height = c.TTF_FontLineSkip(fh.?);
        // font.font_rw = null;

        // try self.fonts.put(name, font);
        // self.current_font = font;
    }

    pub fn getGlyph(self: *FontManager, gme: []const u8) !Glyph {
        var iter = code_point.Iterator{ .bytes = gme };

        const codepoint = iter.next() orelse {
            std.log.warn("Failed to extract code point from grapheme: {s}", .{gme});
            return error.InvalidGrapheme;
        };

        // Select the font based on the code point
        var font = self.pickFontForCharacter(codepoint.code) orelse {
            std.log.warn("No font found for codepoint: {d}", .{codepoint.code});
            return error.NoFontForGlyph;
        };

        // Check if the glyph is already in the cache
        if (font.glyphs.get(gme)) |cached_glyph| {
            return cached_glyph;
        }

        // Duplicate the grapheme to ensure consistent memory allocation for the key
        // const key = try self.allocator.dupe(u8, gme);

        // Render the grapheme using TTF_RenderUTF8_Solid
        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        const glyph_surface = c.TTF_RenderUTF8_Blended(
            font.font_handle,
            sentinel_gme,
            c.SDL_Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF },
        );
        if (glyph_surface == null) {
            // self.allocator.free(key);
            if (c.TTF_GetError()) |e| {
                if (e[0] != 0) std.log.err("TTF Error in getGlyph: {s}.", .{e});
            }
            return error.RenderFailed;
        }
        defer c.SDL_FreeSurface(glyph_surface);

        // Create a texture from the surface
        const glyph_tex = c.SDL_CreateTextureFromSurface(self.renderer, glyph_surface) orelse {
            // self.allocator.free(key);
            if (c.SDL_GetError()) |e| if (e[0] != 0) std.log.err("SDL Error in getGlyph: {s}.", .{e});
            return error.RenderFailed;
        };

        // Cache and return the new glyph
        const surf = glyph_surface.*;
        // var new_glyph = try self.allocator.create(Glyph);
        const new_glyph = Glyph{
            .grapheme = gme,
            .texture = glyph_tex,
            .w = surf.w,
            .h = surf.h,
        };

        try font.glyphs.put(gme, new_glyph);

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
            const glyph = try self.getGlyph(cluster_bytes);

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

            _ = c.SDL_RenderCopy(self.renderer, glyph.texture.?, null, &dst_rect);
            current_x += glyph.w;
        }
    }

    fn pickFontForCharacter(self: *FontManager, codepoint: u21) ?Font {
        const categories = [_]FontCategory{ .latin, .cjk, .emoji };

        for (categories) |category| {
            const ranges = switch (category) {
                .latin => unicode_ranges.latin,
                .cjk => unicode_ranges.cjk,
                .emoji => unicode_ranges.emoji,
                else => continue,
            };

            for (ranges) |range| {
                if (codepoint >= range.start and codepoint <= range.end) {
                    // Search fonts matching the category
                    var it = self.fonts.iterator();
                    while (it.next()) |entry| {
                        const font_name = entry.key_ptr.*;
                        const font = entry.value_ptr.*;

                        // Check the font's category by matching against system_fonts.fonts
                        for (system_fonts.fonts) |sf| {
                            if (std.mem.eql(u8, sf.name, font_name) and sf.category == category) {
                                return font;
                            }
                        }
                    }
                }
            }
        }

        return null; // No matching font found
    }
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}
