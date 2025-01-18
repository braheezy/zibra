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

pub const FontWeight = enum {
    Normal,
    Bold,
};

pub const FontSlant = enum {
    Roman,
    Italic,
};

pub const FontCategory = enum {
    latin,
    cjk,
    emoji,
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
        .{ .start = 0x2000, .end = 0x206F }, // General Punctuation
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

const FontEntry = struct {
    name: []const u8,
    category: FontCategory,
    weight: FontWeight,
    slant: FontSlant,
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
            .{
                .name = "Arial Unicode",
                .category = .latin,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Arial Unicode",
                .category = .cjk,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Apple Color Emoji",
                .category = .emoji,
                .weight = .Normal,
                .slant = .Roman,
            },
        },
    },
    .linux => struct {
        paths: []const []const u8,
        fonts: []const FontEntry,
    }{
        .paths = &[_][]const u8{
            "/usr/share/fonts",
            "/usr/local/share/fonts",
            "/usr/share/fonts/google-noto",
            "/usr/share/fonts/google-noto-sans-cjk-vf-fonts",
            "/usr/share/fonts/google-noto-color-emoji-fonts",
            "/home/braheezy/zibra",
            "/usr/share/fonts/twemoji",
        },
        .fonts = &[_]FontEntry{
            .{
                .name = "NotoSans-Regular",
                .category = .latin,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "NotoSans-Bold",
                .category = .latin,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "NotoSans-Italic",
                .category = .latin,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "NotoSans-BoldItalic",
                .category = .latin,
                .weight = .Bold,
                .slant = .Italic,
            },

            .{
                .name = "NotoSansCJK-VF",
                .category = .cjk,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "NotoColorEmoji",
                .category = .emoji,
                .weight = .Normal,
                .slant = .Roman,
            },
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

const CacheEntry = struct {
    glyphs_by_style: std.AutoHashMap(u8, Glyph),
};

pub const Font = struct {
    name: []const u8,
    font_handle: *c.TTF_Font,
    // Glyph cache or atlas.
    glyphs: std.StringHashMap(CacheEntry),
    line_height: i32,
    font_rw: ?*c.SDL_RWops,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: std.StringHashMap(*Font),
    current_font: ?*Font = null,
    min_line_height: i32 = std.math.maxInt(i32),

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

    pub fn deinit(self: *FontManager) void {
        var fonts_it = self.fonts.iterator();
        while (fonts_it.next()) |entry| {
            var f = entry.value_ptr.*;

            var outer_it = f.glyphs.iterator();
            while (outer_it.next()) |outer_entry| {
                self.allocator.free(outer_entry.key_ptr.*);

                // For each style => destroy the texture
                var cache_entry = outer_entry.value_ptr.*;
                var style_it = cache_entry.glyphs_by_style.iterator();
                while (style_it.next()) |style_entry| {
                    c.SDL_DestroyTexture(style_entry.value_ptr.*.texture.?);
                }
                cache_entry.glyphs_by_style.deinit();
            }
            f.glyphs.deinit();

            c.TTF_CloseFont(f.font_handle);

            if (f.font_rw) |rw| {
                std.debug.assert(c.SDL_RWclose(rw) == 0);
            }
            self.allocator.destroy(f);
        }

        self.fonts.deinit();

        std.debug.print("current font glyphs count: {d}\n", .{self.fonts.count()});

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
        if (self.fonts.get(name)) |_| {
            return true;
        }

        const path_z = try sliceToSentinelArray(self.allocator, path);
        defer self.allocator.free(path_z);

        const fh = c.TTF_OpenFontIndex(path_z, size, 0);
        if (fh == null) {
            if (c.TTF_GetError()) |e| if (e[0] != 0) {
                std.log.err("TTF Error in loadFontAtPath: {s}", .{e});
            };
            return false;
        }

        if (c.TTF_SetFontSize(fh, size) != 0) {
            std.log.warn("Failed to set explicit font pixel size: {s}", .{c.TTF_GetError()});
        }

        const font = try self.allocator.create(Font);
        font.* = Font{
            .name = name,
            .font_handle = fh.?,
            .glyphs = std.StringHashMap(CacheEntry).init(self.allocator),
            .line_height = c.TTF_FontLineSkip(fh),
            .font_rw = null,
        };

        try self.fonts.put(name, font);

        if (font.line_height < self.min_line_height) {
            self.min_line_height = font.line_height;
        }

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
                    std.log.debug("Loaded {s} font at size {d}: {s}", .{ @tagName(category), size, font.name });
                } else {
                    std.log.warn("Failed to load {s} font: {s}", .{ @tagName(category), font.name });
                }
            }
        }

        // Ensure at least one font is loaded
        if (self.fonts.count() == 0) {
            return error.NoFontsLoaded;
        }

        // Set the current font if not already set
        if (self.current_font == null) {
            var it = self.fonts.iterator();
            self.current_font = it.next().?.value_ptr.*;
        }
    }

    pub fn getStyledGlyph(
        self: *FontManager,
        gme: []const u8,
        weight: FontWeight,
        slant: FontSlant,
    ) !Glyph {
        var iter = code_point.Iterator{ .bytes = gme };
        const codepoint = iter.next() orelse return error.InvalidGrapheme;

        var styled_font = self.pickFontForCharacterStyle(codepoint.code, weight, slant);
        var style_set = false;
        if (styled_font == null) {
            std.debug.print("styled fallback\n", .{});
            styled_font = self.pickFontForCharacter(codepoint.code);
            if (styled_font == null) return error.NoFontForGlyph;

            var new_style: c_int = 0;
            if (weight == .Bold) new_style |= c.TTF_STYLE_BOLD;
            if (slant == .Italic) new_style |= c.TTF_STYLE_ITALIC;
            c.TTF_SetFontStyle(styled_font.?.font_handle, new_style);
            style_set = true;
        }
        const font = styled_font.?;

        const stable_key = try self.allocator.dupe(u8, gme);
        const maybe_outer = font.glyphs.get(stable_key);
        var cache_entry_opt: ?CacheEntry = null;
        var stable_grapheme_for_glyph: []const u8 = undefined;

        if (maybe_outer) |outer| {
            stable_grapheme_for_glyph = gme;
            self.allocator.free(stable_key);
            cache_entry_opt = outer;
        } else {
            const new_entry = CacheEntry{
                .glyphs_by_style = std.AutoHashMap(u8, Glyph).init(self.allocator),
            };
            try font.glyphs.put(stable_key, new_entry);
            stable_grapheme_for_glyph = stable_key;
            const found = font.glyphs.get(stable_key);
            if (found) |entry| {
                cache_entry_opt = entry;
            } else {
                return error.RenderFailed;
            }
        }

        var cache_entry = cache_entry_opt.?;

        const style_key = styleToKey(weight, slant);
        if (cache_entry.glyphs_by_style.get(style_key)) |cached_glyph| {
            if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
            return cached_glyph;
        }

        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        const glyph_surface = c.TTF_RenderUTF8_Blended(
            font.font_handle,
            sentinel_gme,
            c.SDL_Color{ .r = 0, .g = 0, .b = 0, .a = 255 },
        );
        if (glyph_surface == null) {
            if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
            return error.RenderFailed;
        }
        defer c.SDL_FreeSurface(glyph_surface);

        const glyph_tex = c.SDL_CreateTextureFromSurface(self.renderer, glyph_surface) orelse {
            if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
            return error.RenderFailed;
        };
        if (c.SDL_SetTextureScaleMode(glyph_tex, c.SDL_ScaleModeLinear) != 0) {
            std.log.err("Scale mode error: {s}", .{c.SDL_GetError()});
        }

        const surf = glyph_surface.*;
        const is_emoji = isCodepointEmoji(codepoint.code);

        const new_glyph = if (!is_emoji) Glyph{
            .grapheme = stable_grapheme_for_glyph,
            .texture = glyph_tex,
            .w = surf.w,
            .h = surf.h,
        } else blk: {
            // Get text height from the current font
            var miny: i32 = 0;
            var maxy: i32 = 0;
            var advance: i32 = 0;

            if (c.TTF_GlyphMetrics32(
                font.font_handle,
                codepoint.code,
                null,
                null,
                &miny,
                &maxy,
                &advance,
            ) != 0) {
                std.log.err("Failed to get glyph metrics: {s}", .{c.TTF_GetError()});
            }

            // const text_height = maxy - miny; // Approximate visual text height
            const text_height: i32 = self.min_line_height;

            // Scale emoji proportionally
            var tmp1: f32 = @floatFromInt(text_height);
            const tmp2: f32 = @floatFromInt(surf.h);
            const emoji_scale_factor = tmp1 / tmp2;

            tmp1 = @floatFromInt(surf.w);
            const emoji_width: i32 = @intFromFloat(tmp1 * emoji_scale_factor);
            const emoji_height: i32 = @intFromFloat(tmp2 * emoji_scale_factor);

            break :blk Glyph{
                .grapheme = gme,
                .texture = glyph_tex,
                .w = emoji_width,
                .h = emoji_height,
            };
        };

        if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
        return new_glyph;
    }

    pub fn pickFontForCharacter(self: *FontManager, codepoint: u21) ?*Font {
        const categories = [_]FontCategory{ .latin, .cjk, .emoji };

        for (categories) |category| {
            const ranges = switch (category) {
                .latin => unicode_ranges.latin,
                .cjk => unicode_ranges.cjk,
                .emoji => unicode_ranges.emoji,
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

    pub fn pickFontForCharacterStyle(
        self: *FontManager,
        codepoint: u21,
        weight: FontWeight,
        slant: FontSlant,
    ) ?*Font {
        // 1) Figure out the script
        const category = getCategory(codepoint) orelse return null;

        // 2) Search for a loaded font that matches this script + weight + slant
        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            const font_name = entry.key_ptr.*;
            const font_ptr = entry.value_ptr.*;

            // We must look up which category/weight/slant this font_name represents
            // by comparing to system_fonts. For instance:
            for (system_fonts.fonts) |sf| {
                if (std.mem.eql(u8, sf.name, font_name)) {
                    if (sf.category == category and sf.weight == weight and sf.slant == slant) {
                        return font_ptr;
                    }
                }
            }
        }

        // If we didn’t find an exact match, fallback to "Normal Roman"
        // or whatever logic you like.
        return self.pickFontForCharacter(codepoint);
    }
};

fn sliceToSentinelArray(allocator: std.mem.Allocator, slice: []const u8) ![:0]const u8 {
    const len = slice.len;
    const arr = try allocator.allocSentinel(u8, len, 0);
    @memcpy(arr, slice);
    return arr;
}

fn isCodepointEmoji(codepoint: u21) bool {
    for (unicode_ranges.emoji) |range| {
        if (codepoint >= range.start and codepoint <= range.end) {
            return true;
        }
    }
    return false;
}

fn getCategory(codepoint: u21) ?FontCategory {
    // basically the same logic you had in pickFontForCharacter
    const categories = [_]FontCategory{ .latin, .cjk, .emoji };
    for (categories) |category| {
        const ranges = switch (category) {
            .latin => unicode_ranges.latin,
            .cjk => unicode_ranges.cjk,
            .emoji => unicode_ranges.emoji,
        };
        for (ranges) |range| {
            if (codepoint >= range.start and codepoint <= range.end) {
                return category;
            }
        }
    }
    return null;
}

pub fn styleToKey(weight: FontWeight, slant: FontSlant) u8 {
    // bit 0 = bold flag
    // bit 1 = italic flag
    var bits: u8 = 0;
    if (weight == .Bold) bits |= 1;
    if (slant == .Italic) bits |= 2;
    return bits;
}
