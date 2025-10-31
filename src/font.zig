const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known-folders");
const grapheme = @import("grapheme");
const code_point = @import("code_point");
const sdl2 = @import("sdl");

const browser = @import("browser.zig");

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
    texture: ?sdl2.Texture,
    w: i32,
    h: i32,
    ascent: i32,
    descent: i32,
    is_superscript: bool = false,
    is_soft_hyphen: bool = false,
    preserve_texture_color: bool = false,
};

pub const Font = struct {
    name: []const u8,
    font_handle: sdl2.ttf.Font,
    // Glyph cache or atlas.
    glyphs: std.AutoHashMap(u64, Glyph),
    line_height: i32,
};

pub const FontKey = struct {
    category: FontCategory,
    weight: FontWeight,
    slant: FontSlant,
};

pub const FontManager = struct {
    allocator: std.mem.Allocator,
    renderer: sdl2.Renderer,
    fonts: std.StringHashMap(*Font),
    styled_fonts: std.AutoHashMap(FontKey, *Font),
    category_fonts: std.AutoHashMap(FontCategory, *Font),
    current_font: ?*Font = null,
    min_line_height: i32 = std.math.maxInt(i32),
    loaded_sizes: std.AutoHashMap(i32, void),

    pub fn init(allocator: std.mem.Allocator, renderer: sdl2.Renderer) !FontManager {
        try sdl2.ttf.init();

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
                // For each style => destroy the texture
                const cache_entry = outer_entry.value_ptr.*;
                if (cache_entry.texture) |texture| {
                    texture.destroy();
                }
            }
            f.glyphs.deinit();

            f.font_handle.close();
            self.allocator.destroy(f);
        }

        self.styled_fonts.deinit();
        self.category_fonts.deinit();
        self.fonts.deinit();
        self.loaded_sizes.deinit();

        sdl2.ttf.quit();
    }

    pub fn loadFontFromEmbed(self: *FontManager, size: i32) !void {
        const embed_file = @embedFile("ocraext.ttf");
        const name = "ocraext";

        var font: *Font = try self.allocator.create(Font);
        font.font_handle = sdl2.ttf.openFontMem(embed_file, false, size) orelse return error.LoadFailed;
        font.glyphs = std.AutoHashMap(u64, Glyph).init(self.allocator);
        font.line_height = font.font_handle.lineSkip();

        try self.fonts.put(name, font);

        if (font.line_height < self.min_line_height) {
            self.min_line_height = font.line_height;
        }

        if (self.current_font == null) {
            self.current_font = self.fonts.get(name);
        }
    }

    fn collectFontPaths(self: *FontManager) !std.ArrayList([]const u8) {
        var paths = std.ArrayList([]const u8).empty;

        // Add user font directory first to prefer them.
        const home_dir = try known_folders.getPath(self.allocator, .home) orelse return error.NoHomeDir;
        defer self.allocator.free(home_dir);

        const user_suffixes = switch (builtin.target.os.tag) {
            .macos => &[_][]const u8{ "/Library/Fonts" },
            .linux => &[_][]const u8{ "/.local/share/fonts", "/.fonts" },
            else => &[_][]const u8{},
        };
        for (user_suffixes) |suffix| {
            const user_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home_dir, suffix });
            try paths.append(self.allocator, user_path);
        }

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

        var fh = sdl2.ttf.openFontIndex(path_z, size, 0) catch return false;

        const font = try self.allocator.create(Font);
        font.* = Font{
            .name = name,
            .font_handle = fh,
            .glyphs = std.AutoHashMap(u64, Glyph).init(self.allocator),
            .line_height = fh.lineSkip(),
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
                const new_style: sdl2.ttf.Font.Style = .{
                    .bold = weight == .Bold,
                    .italic = slant == .Italic,
                };
                styled_font.?.font_handle.setStyle(new_style);
                style_set = true;
            }
        }
        const font = styled_font.?;

        // Use a single cache key that combines grapheme, weight, slant, and size.
        const key = newGlyphCacheKey(gme, weight, slant, size);
        if (font.glyphs.get(key)) |cached_glyph| {
            if (style_set) font.font_handle.setStyle(.{});
            return cached_glyph;
        }

        // Set the font size before rendering.
        font.font_handle.setSize(size);

        // Convert the grapheme to a null-terminated string.
        const sentinel_gme = try sliceToSentinelArray(self.allocator, gme);
        defer self.allocator.free(sentinel_gme);

        var glyph_surface = try font.font_handle.renderUtf8Blended(
            sentinel_gme,
            .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        );
        defer glyph_surface.destroy();

        // Apply synthetic bold effect before creating texture
        if (synthetic_bold) {
            const bold_offset = @max(1, @divTrunc(size, 24));

            // Create a new surface for the bold effect
            const bold_surface = try sdl2.createRgbSurfaceWithFormat(
                @intCast(glyph_surface.ptr.w + bold_offset),
                @intCast(glyph_surface.ptr.h),
                .abgr8888,
            );
            // Copy original glyph multiple times with offset
            try sdl2.blit(
                glyph_surface,
                null,
                bold_surface,
                null,
            );
            var rect = sdl2.Rectangle{
                .x = bold_offset,
                .y = 0,
                .width = glyph_surface.ptr.w,
                .height = glyph_surface.ptr.h,
            };
            try sdl2.blit(glyph_surface, null, bold_surface, &rect);

            // Replace original surface with bold version
            glyph_surface.destroy();
            glyph_surface = bold_surface;
        }

        const glyph_tex = try sdl2.createTextureFromSurface(self.renderer, glyph_surface);
        try glyph_tex.setScaleMode(.linear);

        const surf = glyph_surface.ptr;
        const is_emoji = isCodepointEmoji(codepoint.code);
        const ascent = font.font_handle.ascent();
        const descent = -font.font_handle.descent(); // Make positive

        const new_glyph = if (!is_emoji) Glyph{
            .grapheme = gme,
            .texture = glyph_tex,
            .w = surf.w,
            .h = surf.h,
            .ascent = ascent,
            .descent = descent,
        } else blk: {
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
                .preserve_texture_color = true,
            };
        };

        try font.glyphs.put(key, new_glyph);
        if (style_set) font.font_handle.setStyle(.{});

        return new_glyph;
    }

    fn ensureFontSize(self: *FontManager, size: i32) !void {
        if (self.loaded_sizes.contains(size)) return;

        var it = self.fonts.iterator();
        while (it.next()) |entry| {
            const font = entry.value_ptr.*;
            font.font_handle.setSize(size);
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
