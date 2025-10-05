const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known-folders");
const grapheme = @import("grapheme");
const code_point = @import("code_point");

const browser = @import("browser.zig");

const sdl = @import("sdl.zig");
const c = sdl.c;

pub const hyphen_codepoint = 0x00AD;

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
    monospace,
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
        .{ .start = 0x1F900, .end = 0x1F9FF }, // Supplemental Symbols and Pictographs
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
                .name = "Arial",
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
            .{
                .name = "Arial Bold",
                .category = .latin,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "Arial Italic",
                .category = .latin,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "Arial Bold Italic",
                .category = .latin,
                .weight = .Bold,
                .slant = .Italic,
            },
            .{
                .name = "Andale Mono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "Andale Mono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Italic,
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
            .{
                .name = "DejaVuSansMono",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Roman,
            },
            .{
                .name = "DejaVuSansMono-Bold",
                .category = .monospace,
                .weight = .Bold,
                .slant = .Roman,
            },
            .{
                .name = "DejaVuSansMono-Oblique",
                .category = .monospace,
                .weight = .Normal,
                .slant = .Italic,
            },
            .{
                .name = "DejaVuSansMono-BoldOblique",
                .category = .monospace,
                .weight = .Bold,
                .slant = .Italic,
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
    ascent: i32,
    descent: i32,
    is_superscript: bool = false,
    is_soft_hyphen: bool = false,
};

pub const Font = struct {
    name: []const u8,
    font_handle: *c.TTF_Font,
    // Glyph cache or atlas.
    glyphs: std.AutoHashMap(u64, Glyph),
    line_height: i32,
    font_rw: ?*c.SDL_RWops,
};

pub const FontKey = struct {
    category: FontCategory,
    weight: FontWeight,
    slant: FontSlant,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: std.StringHashMap(*Font),
    styled_fonts: std.AutoHashMap(FontKey, *Font),
    category_fonts: std.AutoHashMap(FontCategory, *Font),
    current_font: ?*Font = null,
    min_line_height: i32 = std.math.maxInt(i32),
    loaded_sizes: std.AutoHashMap(i32, void),

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer) !FontManager {
        if (c.TTF_WasInit() == 0) {
            if (c.TTF_Init() != 0) return error.InitFailed;
        }

        return FontManager{
            .allocator = allocator,
            .renderer = renderer,
            .fonts = std.StringHashMap(*Font).init(allocator),
            .styled_fonts = std.AutoHashMap(FontKey, *Font).init(allocator),
            .category_fonts = std.AutoHashMap(FontCategory, *Font).init(allocator),
            .loaded_sizes = std.AutoHashMap(i32, void).init(allocator),
        };
    }

    pub fn deinit(self: *FontManager) void {
        var fonts_it = self.fonts.iterator();
        while (fonts_it.next()) |entry| {
            var f = entry.value_ptr.*;

            var outer_it = f.glyphs.iterator();
            while (outer_it.next()) |outer_entry| {
                // self.allocator.free(outer_entry.key_ptr.*);

                // For each style => destroy the texture
                const cache_entry = outer_entry.value_ptr.*;
                c.SDL_DestroyTexture(cache_entry.texture.?);
            }
            f.glyphs.deinit();

            c.TTF_CloseFont(f.font_handle);

            if (f.font_rw) |rw| {
                std.debug.assert(c.SDL_RWclose(rw) == 0);
            }
            self.allocator.destroy(f);
        }

        self.styled_fonts.deinit();
        self.category_fonts.deinit();
        self.fonts.deinit();
        self.loaded_sizes.deinit();

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
        var paths = std.ArrayList([]const u8).empty;

        // Add user font directory first to prefer them.
        const home_dir = try known_folders.getPath(self.allocator, .home) orelse return error.NoHomeDir;
        defer self.allocator.free(home_dir);

        // Add system font directories
        for (system_fonts.paths) |dir| {
            const copy = try self.allocator.dupe(u8, dir);
            try paths.append(self.allocator, copy);
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
        if (self.fonts.get(name)) |_| return true;

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
            .glyphs = std.AutoHashMap(u64, Glyph).init(self.allocator),
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

        // After loading font, find its metadata in system_fonts
        for (system_fonts.fonts) |sf| {
            if (std.mem.eql(u8, sf.name, name)) {
                // Add to styled_fonts map
                const key = FontKey{
                    .category = sf.category,
                    .weight = sf.weight,
                    .slant = sf.slant,
                };
                try self.styled_fonts.put(key, font);

                // If this is a "normal" font (Normal weight, Roman slant),
                // add/update it as the category font
                if (sf.weight == .Normal and sf.slant == .Roman) {
                    try self.category_fonts.put(sf.category, font);
                }
                break;
            }
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
            search_paths.deinit(self.allocator);
        }

        // Iterate through font categories in order of priority
        const categories = [_]FontCategory{ .latin, .cjk, .emoji, .monospace };
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
        size: i32,
        use_monospace: bool,
    ) !Glyph {
        try self.ensureFontSize(size);

        var iter = code_point.Iterator{ .bytes = gme };
        const codepoint = iter.next() orelse return error.InvalidGrapheme;

        if (codepoint.code == hyphen_codepoint) {
            return Glyph{
                .grapheme = gme,
                .texture = null,
                .w = 0,
                .h = 0,
                .ascent = 0,
                .descent = 0,
                .is_soft_hyphen = true,
            };
        }

        var styled_font = self.pickFontForCharacterStyle(
            codepoint.code,
            weight,
            slant,
            use_monospace,
        );
        var style_set = false;
        var synthetic_bold = false;

        if (styled_font == null) {
            // Try again with normal weight for monospace
            if (use_monospace and weight == .Bold) {
                styled_font = self.pickFontForCharacterStyle(
                    codepoint.code,
                    .Normal,
                    slant,
                    use_monospace,
                );
                if (styled_font != null) {
                    synthetic_bold = true; // Mark for synthetic bold rendering
                }
            }

            if (styled_font == null) {
                styled_font = self.pickFontForCharacter(codepoint.code);
                if (styled_font == null) return error.NoFontForGlyph;
                var new_style: c_int = 0;
                if (weight == .Bold) new_style |= c.TTF_STYLE_BOLD;
                if (slant == .Italic) new_style |= c.TTF_STYLE_ITALIC;
                c.TTF_SetFontStyle(styled_font.?.font_handle, new_style);
                style_set = true;
            }
        }
        const font = styled_font.?;

        // Use a single cache key that combines grapheme, weight, slant, and size.
        const key = newGlyphCacheKey(gme, weight, slant, size);
        if (font.glyphs.get(key)) |cached_glyph| {
            if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
            return cached_glyph;
        }

        // Set the font size before rendering.
        if (c.TTF_SetFontSize(font.font_handle, size) != 0) {
            std.log.warn("Failed to set font size: {s}", .{c.TTF_GetError()});
        }

        // Convert the grapheme to a null-terminated string.
        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        var glyph_surface = c.TTF_RenderUTF8_Blended(
            font.font_handle,
            sentinel_gme,
            c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
        );
        if (glyph_surface == null) {
            const err_msg = c.TTF_GetError();
            // For zero-width characters, substitute with a space.
            if (std.mem.indexOf(u8, std.mem.span(err_msg), "zero width") != null) {
                const space_sentinel = try self.allocator.allocSentinel(u8, 1, 0);
                defer self.allocator.free(space_sentinel);
                space_sentinel[0] = ' ';
                const space_surface = c.TTF_RenderUTF8_Blended(
                    font.font_handle,
                    space_sentinel,
                    c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                );
                if (space_surface == null) {
                    if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
                    return error.RenderFailed;
                }
                glyph_surface = space_surface;
            } else {
                if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
                std.debug.print("failed to render glyph: {s}\n", .{sentinel_gme});
                std.debug.print("error: {s}\n", .{err_msg});
                return error.RenderFailed;
            }
        }
        defer c.SDL_FreeSurface(glyph_surface);

        // Apply synthetic bold effect before creating texture
        if (synthetic_bold) {
            const bold_offset = @max(1, @divTrunc(size, 24));

            // Create a new surface for the bold effect
            const bold_surface = c.SDL_CreateRGBSurface(
                0,
                glyph_surface.*.w + bold_offset,
                glyph_surface.*.h,
                32,
                0xFF000000,
                0x00FF0000,
                0x0000FF00,
                0x000000FF,
            );

            // Copy original glyph multiple times with offset
            _ = c.SDL_BlitSurface(glyph_surface, null, bold_surface, null);
            var rect = c.SDL_Rect{
                .x = bold_offset,
                .y = 0,
                .w = glyph_surface.*.w,
                .h = glyph_surface.*.h,
            };
            _ = c.SDL_BlitSurface(glyph_surface, null, bold_surface, &rect);

            // Replace original surface with bold version
            c.SDL_FreeSurface(glyph_surface);
            glyph_surface = bold_surface;
        }

        const glyph_tex = c.SDL_CreateTextureFromSurface(self.renderer, glyph_surface) orelse {
            if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);
            return error.RenderFailed;
        };
        if (c.SDL_SetTextureScaleMode(glyph_tex, c.SDL_ScaleModeLinear) != 0) {
            std.log.err("Scale mode error: {s}", .{c.SDL_GetError()});
        }

        const surf = glyph_surface.*;
        const is_emoji = isCodepointEmoji(codepoint.code);
        const ascent = c.TTF_FontAscent(font.font_handle);
        const descent = -c.TTF_FontDescent(font.font_handle); // Make positive

        const new_glyph = if (!is_emoji) Glyph{
            .grapheme = gme,
            .texture = glyph_tex,
            .w = surf.w,
            .h = surf.h,
            .ascent = ascent,
            .descent = descent,
        } else blk: {
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
            const text_height: i32 = self.min_line_height;
            var tmp1: f32 = @floatFromInt(text_height);
            const tmp2: f32 = @floatFromInt(surf.h);
            // Multiply by 1.2 to make the emoji 20% larger than before.
            const emoji_scale_factor = (tmp1 / tmp2) * 1.2;
            tmp1 = @floatFromInt(surf.w);
            const emoji_width: i32 = @intFromFloat(tmp1 * emoji_scale_factor);
            const emoji_height: i32 = @intFromFloat(tmp2 * emoji_scale_factor);
            break :blk Glyph{
                .grapheme = gme,
                .texture = glyph_tex,
                .w = emoji_width,
                .h = emoji_height,
                .ascent = @divTrunc(3 * self.min_line_height, 4),
                .descent = @divTrunc(self.min_line_height, 4),
            };
        };

        try font.glyphs.put(key, new_glyph);
        if (style_set) c.TTF_SetFontStyle(font.font_handle, c.TTF_STYLE_NORMAL);

        return new_glyph;
    }

    fn ensureFontSize(self: *FontManager, size: i32) !void {
        if (self.loaded_sizes.contains(size)) return;

        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            const font = entry.value_ptr.*;
            if (c.TTF_SetFontSize(font.font_handle, size) != 0) {
                std.log.warn("Failed to set font size: {s}", .{c.TTF_GetError()});
            }
        }
        try self.loaded_sizes.put(size, {});
    }

    pub fn pickFontForCharacter(self: *FontManager, codepoint: u21) ?*Font {
        const categories = [_]FontCategory{ .latin, .cjk, .emoji, .monospace };

        for (categories) |category| {
            const ranges = switch (category) {
                .latin => unicode_ranges.latin,
                .cjk => unicode_ranges.cjk,
                .emoji => unicode_ranges.emoji,
                .monospace => unicode_ranges.latin, // Monospace uses Latin ranges
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
        use_monospace: bool,
    ) ?*Font {
        // 1) Get category
        const category = if (use_monospace) .monospace else getCategory(codepoint) orelse return null;

        // 2) Try exact style match
        const key = FontKey{
            .category = category,
            .weight = weight,
            .slant = slant,
        };
        if (self.styled_fonts.get(key)) |font| {
            return font;
        }

        // 3) Fallback to normal style for this category
        return null;
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

pub fn getCategory(codepoint: u21) ?FontCategory {
    const categories = [_]FontCategory{ .latin, .cjk, .emoji, .monospace };
    for (categories) |category| {
        const ranges = switch (category) {
            .latin => unicode_ranges.latin,
            .cjk => unicode_ranges.cjk,
            .emoji => unicode_ranges.emoji,
            .monospace => unicode_ranges.latin, // Monospace uses Latin ranges
        };
        for (ranges) |range| {
            if (codepoint >= range.start and codepoint <= range.end) {
                return category;
            }
        }
    }
    return null;
}

fn hash_combine(seed: u64, value: u64) u64 {
    // A common hash combine (borrowed from boost::hash_combine)
    return seed ^ (value +% 0x9e3779b97f4a7c15 +% (seed << 6) +% (seed >> 2));
}

pub fn newGlyphCacheKey(gme: []const u8, weight: FontWeight, slant: FontSlant, size: i32) u64 {
    // Prepare style bits: bit 0 for Bold, bit 1 for Italic.
    var bits: u8 = 0;
    if (weight == .Bold) bits |= 1;
    if (slant == .Italic) bits |= 2;

    const grapheme_hash = std.hash.Fnv1a_64.hash(gme);

    // Combine the hashed grapheme, the size, and the style bits.
    var key = hash_combine(grapheme_hash, @as(u64, @intCast(size)));
    key = hash_combine(key, @as(u64, bits));
    return key;
}
