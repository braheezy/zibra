const std = @import("std");
const builtin = @import("builtin");

const grapheme = @import("grapheme");
const code_point = @import("code_point");
const sdl2 = @import("sdl");
const z2d = @import("z2d");
const compositor = z2d.compositor;

const token = @import("token.zig");
const font = @import("font.zig");
const Token = token.Token;
const FontManager = font.FontManager;
const Glyph = font.Glyph;
const FontWeight = font.FontWeight;
const FontSlant = font.FontSlant;
const url_module = @import("url.zig");
const Url = url_module.Url;
const Cache = @import("cache.zig").Cache;
const ArrayList = std.ArrayList;
const Layout = @import("Layout.zig");
const parser = @import("parser.zig");
const HTMLParser = parser.HTMLParser;
const Node = parser.Node;
const CSSParser = @import("cssParser.zig").CSSParser;
const js_module = @import("js.zig");
const Tab = @import("tab.zig");
const Chrome = @import("chrome.zig");
const task_module = @import("task.zig");
const Task = task_module.Task;
const MeasureTime = @import("measure_time.zig").MeasureTime;

// Default browser stylesheet - defines default styling for HTML elements
const DEFAULT_STYLE_SHEET = @embedFile("browser.css");

// *********************************************************
// * App Settings
// *********************************************************
const initial_window_width = 800;
const initial_window_height = 600;
pub const h_offset = 13;
pub const v_offset = 18;
pub const scrollbar_width = 10;
const scroll_step: i32 = 100;
const refresh_rate_ns: u64 = 33_000_000; // ~30 FPS
// *********************************************************

// Display items are the drawing commands emitted by layout.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn toZ2dRgba(self: Color) z2d.pixel.RGBA {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

// Rectangle helper for layout bounds
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    /// Expand bounds by the given amount in all directions
    pub fn outset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left - amount,
            .top = self.top - amount,
            .right = self.right + amount,
            .bottom = self.bottom + amount,
        };
    }

    /// Contract bounds by the given amount in all directions
    pub fn inset(self: Rect, amount: i32) Rect {
        return .{
            .left = self.left + amount,
            .top = self.top + amount,
            .right = self.right - amount,
            .bottom = self.bottom - amount,
        };
    }
};

/// A composited layer stores display items that can be rasterized once and reused.
/// Layers are created for elements with visual effects like opacity or blend modes.
pub const CompositedLayer = struct {
    /// The display items to rasterize into this layer
    display_items: []DisplayItem,
    /// Cached raster surface (null until first rasterized)
    surface: ?z2d.Surface = null,
    /// Bounds of the layer in document coordinates (with 1px outset for edge artifacts)
    bounds: Rect,
    /// Whether this layer needs to be re-rasterized
    needs_raster: bool = true,
    /// Opacity to apply when compositing this layer
    opacity: f64 = 1.0,
    /// Blend mode to apply when compositing
    blend_mode: ?[]const u8 = null,
    /// DOM node pointer for identifying this layer across frames
    node: ?*anyopaque = null,

    pub fn init(display_items: []DisplayItem, bounds: Rect, opacity: f64, blend_mode: ?[]const u8, node: ?*anyopaque) CompositedLayer {
        // Add 1px outset to avoid raster edge artifacts
        return .{
            .display_items = display_items,
            .bounds = bounds.outset(1),
            .opacity = opacity,
            .blend_mode = blend_mode,
            .node = node,
        };
    }

    pub fn deinit(self: *CompositedLayer, allocator: std.mem.Allocator) void {
        if (self.surface) |*surface| {
            surface.deinit(allocator);
            self.surface = null;
        }
        if (self.display_items.len > 0) {
            freeLayerItems(allocator, self.display_items);
            self.display_items = &.{};
        }
    }

    /// Check if another layer can be merged into this one.
    /// Layers can merge if they have identical visual-effect ancestry (same opacity and blend_mode).
    pub fn can_merge(self: *const CompositedLayer, other_opacity: f64, other_blend_mode: ?[]const u8) bool {
        // Must have same opacity
        if (self.opacity != other_opacity) return false;

        // Must have same blend mode
        if (self.blend_mode == null and other_blend_mode == null) return true;
        if (self.blend_mode == null or other_blend_mode == null) return false;
        return std.mem.eql(u8, self.blend_mode.?, other_blend_mode.?);
    }

    /// Add display items to this layer, expanding bounds as needed.
    /// Returns true if items were added, false if incompatible.
    pub fn add(self: *CompositedLayer, allocator: std.mem.Allocator, items: []DisplayItem, item_bounds: Rect) !void {
        // Expand bounds to include new items (remove 1px outset, expand, re-add)
        const inner_bounds = self.bounds.inset(1);
        const new_bounds = Rect{
            .left = @min(inner_bounds.left, item_bounds.left),
            .top = @min(inner_bounds.top, item_bounds.top),
            .right = @max(inner_bounds.right, item_bounds.right),
            .bottom = @max(inner_bounds.bottom, item_bounds.bottom),
        };
        self.bounds = new_bounds.outset(1);

        // Combine display items
        const old_items = self.display_items;
        const new_items = try allocator.alloc(DisplayItem, old_items.len + items.len);
        @memcpy(new_items[0..old_items.len], old_items);
        @memcpy(new_items[old_items.len..], items);
        self.display_items = new_items;
        if (old_items.len > 0) {
            allocator.free(old_items);
        }
        if (items.len > 0) {
            allocator.free(items);
        }

        // Mark for re-rasterization since content changed
        self.needs_raster = true;
    }

    fn freeLayerItems(allocator: std.mem.Allocator, items: []DisplayItem) void {
        if (items.len == 0) return;
        for (items) |item| {
            switch (item) {
                .transform => |t| {
                    freeLayerItems(allocator, t.children);
                },
                else => {},
            }
        }
        allocator.free(items);
    }

    /// Rasterize the layer's display items to its cached surface
    pub fn raster(self: *CompositedLayer, allocator: std.mem.Allocator, browser: *Browser) anyerror!void {
        if (!self.needs_raster and self.surface != null) return;

        const layer_width: i32 = @max(1, self.bounds.width());
        const layer_height: i32 = @max(1, self.bounds.height());

        // Create or recreate surface if needed
        if (self.surface) |*existing| {
            if (existing.getWidth() != layer_width or existing.getHeight() != layer_height) {
                existing.deinit(allocator);
                self.surface = null;
            }
        }

        if (self.surface == null) {
            self.surface = try z2d.Surface.init(.image_surface_rgba, allocator, layer_width, layer_height);
        }

        var ctx = z2d.Context.init(allocator, &self.surface.?);
        defer ctx.deinit();

        // Clear to transparent
        ctx.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } } });
        try ctx.moveTo(0, 0);
        try ctx.lineTo(@floatFromInt(layer_width), 0);
        try ctx.lineTo(@floatFromInt(layer_width), @floatFromInt(layer_height));
        try ctx.lineTo(0, @floatFromInt(layer_height));
        try ctx.closePath();
        try ctx.fill();

        // Draw display items offset by layer bounds (absolute to local mapping)
        // Items are stored in absolute coordinates, so we offset by bounds origin to draw in layer space
        for (self.display_items) |item| {
            try browser.drawDisplayItemZ2dContextForLayer(&ctx, item, self.bounds.left, self.bounds.top);
        }

        self.needs_raster = false;
    }
};

pub const DisplayItem = union(enum) {
    glyph: struct {
        x: i32,
        y: i32,
        glyph: Glyph,
        color: Color,
    },
    rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
    },
    rounded_rect: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        radius: f64,
        color: Color,
    },
    line: struct {
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        color: Color,
        thickness: i32,
    },
    outline: struct {
        rect: Rect,
        color: Color,
        thickness: i32,
    },
    blend: struct {
        opacity: f64,
        blend_mode: ?[]const u8,
        children: []DisplayItem,
        node: ?*anyopaque = null, // Reference back to the DOM node that created this effect
        parent: ?*const DisplayItem = null, // Parent blend for walking up the tree
        needs_compositing: bool = false, // True if this blend or descendants require composited layers
    },
    /// Draw a pre-rasterized composited layer
    draw_composited_layer: struct {
        layer: *CompositedLayer,
    },
    /// Apply a 2D translation transform to children
    transform: struct {
        translate_x: i32,
        translate_y: i32,
        children: []DisplayItem,
        node: ?*anyopaque = null,
    },

    // Debug print a display item with indentation
    pub fn debugPrint(self: DisplayItem, indent: usize) void {
        const indent_str = "  ";
        var i: usize = 0;
        while (i < indent) : (i += 1) {
            std.debug.print("{s}", .{indent_str});
        }

        switch (self) {
            .glyph => |g| {
                std.debug.print("Glyph({d},{d}) color=({d},{d},{d},{d})\n", .{
                    g.x, g.y, g.color.r, g.color.g, g.color.b, g.color.a,
                });
            },
            .rect => |r| {
                std.debug.print("Rect({d},{d})-({d},{d}) color=({d},{d},{d},{d})\n", .{
                    r.x1, r.y1, r.x2, r.y2, r.color.r, r.color.g, r.color.b, r.color.a,
                });
            },
            .rounded_rect => |r| {
                std.debug.print("RoundedRect({d},{d})-({d},{d}) r={d:.1} color=({d},{d},{d},{d})\n", .{
                    r.x1, r.y1, r.x2, r.y2, r.radius, r.color.r, r.color.g, r.color.b, r.color.a,
                });
            },
            .line => |l| {
                std.debug.print("Line({d},{d})-({d},{d}) t={d}\n", .{
                    l.x1, l.y1, l.x2, l.y2, l.thickness,
                });
            },
            .outline => |o| {
                std.debug.print("Outline({d},{d})-({d},{d}) t={d}\n", .{
                    o.rect.left, o.rect.top, o.rect.right, o.rect.bottom, o.thickness,
                });
            },
            .blend => |b| {
                std.debug.print("Blend(opacity={d:.2}, mode={s}, children={d})\n", .{
                    b.opacity,
                    if (b.blend_mode) |mode| mode else "normal",
                    b.children.len,
                });
                for (b.children) |child| {
                    child.debugPrint(indent + 1);
                }
            },
            .draw_composited_layer => |dcl| {
                std.debug.print("DrawCompositedLayer(bounds=({d},{d})-({d},{d}), opacity={d:.2})\n", .{
                    dcl.layer.bounds.left,
                    dcl.layer.bounds.top,
                    dcl.layer.bounds.right,
                    dcl.layer.bounds.bottom,
                    dcl.layer.opacity,
                });
            },
            .transform => |t| {
                std.debug.print("Transform(translate=({d},{d}), {d} children)\n", .{
                    t.translate_x,
                    t.translate_y,
                    t.children.len,
                });
                for (t.children) |child| {
                    child.debugPrint(indent + 1);
                }
            },
        }
    }

    // Debug print an entire display list as a tree
    pub fn debugPrintList(items: []const DisplayItem) void {
        std.debug.print("=== Display List ({d} items) ===\n", .{items.len});
        for (items) |item| {
            item.debugPrint(0);
        }
        std.debug.print("=== End Display List ===\n", .{});
    }

    // Set parent pointers recursively on a display list
    // This should be called after the display list is constructed
    pub fn setParentPointers(items: []DisplayItem, parent: ?*const DisplayItem) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*b| {
                    b.parent = parent;
                    // Recursively set parent pointers on children
                    setParentPointers(b.children, item);
                },
                else => {}, // Leaf nodes don't have parent pointers
            }
        }
    }

    // Walk up the parent chain from this item (only works for blend items)
    pub fn getAncestorChain(self: *const DisplayItem, allocator: std.mem.Allocator) ![]const *const DisplayItem {
        var ancestors = std.ArrayList(*const DisplayItem).init(allocator);
        var current: ?*const DisplayItem = self;
        while (current) |item| {
            switch (item.*) {
                .blend => |b| {
                    try ancestors.append(item);
                    current = b.parent;
                },
                else => break,
            }
        }
        return ancestors.toOwnedSlice();
    }

    // Check if display list contains any opacity effects (opacity < 1.0)
    pub fn hasOpacityEffects(items: []const DisplayItem) bool {
        for (items) |item| {
            switch (item) {
                .blend => |b| {
                    if (b.opacity < 1.0) return true;
                    if (hasOpacityEffects(b.children)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    // Debug print the display list if it contains opacity effects
    pub fn debugPrintIfHasOpacity(items: []const DisplayItem) void {
        if (hasOpacityEffects(items)) {
            std.debug.print("\n=== Opacity Frame Detected ===\n", .{});
            debugPrintList(items);
        }
    }

    pub fn freeList(allocator: std.mem.Allocator, items: []DisplayItem) void {
        for (items) |item| {
            freeItem(allocator, item);
        }
        allocator.free(items);
    }

    fn freeItem(allocator: std.mem.Allocator, item: DisplayItem) void {
        switch (item) {
            .blend => |b| {
                if (b.blend_mode) |mode| {
                    allocator.free(mode);
                }
                freeList(allocator, b.children);
            },
            .transform => |t| {
                freeList(allocator, t.children);
            },
            else => {},
        }
    }
};

pub const JsRenderContext = struct {
    browser_ptr: ?*anyopaque = null,
    tab_ptr: ?*anyopaque = null,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn setPointers(self: *JsRenderContext, browser_ptr: ?*anyopaque, tab_ptr: ?*anyopaque) void {
        self.browser_ptr = browser_ptr;
        self.tab_ptr = tab_ptr;
    }

    pub fn setGeneration(self: *JsRenderContext, generation: u64) void {
        self.generation.store(generation, .seq_cst);
    }

    pub fn currentGeneration(self: *const JsRenderContext) u64 {
        return self.generation.load(.seq_cst);
    }

    pub fn matchesGeneration(self: *const JsRenderContext, expected: u64) bool {
        return self.currentGeneration() == expected;
    }
};

// Browser manages the window and tabs
pub const Browser = struct {
    // Memory allocator for the browser
    allocator: std.mem.Allocator,
    // SDL window handle
    window: sdl2.Window,
    // SDL renderer handle
    canvas: sdl2.Renderer,
    // z2d surface for drawing (RGBA format like the tutorial)
    root_surface: z2d.Surface,
    // z2d context for drawing operations
    context: z2d.Context,
    // Separate surface for browser chrome (UI)
    chrome_surface: z2d.Surface,
    // Separate surface for current tab content (can be taller than window)
    tab_surface: ?z2d.Surface,
    // HTTP client for making requests (handles both HTTP and HTTPS)
    http_client: std.http.Client,
    http_client_mutex: std.Thread.Mutex = .{},
    // Cache for storing fetched resources
    cache: Cache,
    // Shared cookie storage across tabs
    cookie_jar: std.StringHashMap(url_module.CookieEntry),
    // Window dimensions
    window_width: i32 = initial_window_width,
    window_height: i32 = initial_window_height,
    layout_engine: *Layout,
    // Default browser stylesheet rules
    default_style_sheet_rules: []CSSParser.CSSRule,
    // List of tabs
    tabs: std.ArrayList(*Tab),
    // Index of the active tab
    active_tab_index: ?usize = null,
    // Browser chrome (UI)
    chrome: Chrome = undefined,
    // Focus tracking: null means nothing focused, "content" means page content
    focus: ?[]const u8 = null,
    // JavaScript engine
    js_engine: *js_module,
    animation_timer_active: bool = false,
    needs_composite: bool = true,
    needs_raster: bool = true,
    needs_draw: bool = true,
    needs_animation_frame: bool = false,
    shutting_down: bool = false,
    measure: MeasureTime,
    lock: std.Thread.Mutex = .{},
    active_tab_url: ?[]u8 = null,
    active_tab_scroll: i32 = 0,
    active_tab_height: i32 = 0,
    active_tab_display_list: ?[]DisplayItem = null,
    // Composited layers for caching rasterized content
    composited_layers: std.ArrayList(CompositedLayer),
    // Draw list created from composite phase
    tab_draw_list: std.ArrayList(DisplayItem),
    // Cached SDL texture for GPU-accelerated rendering
    cached_texture: ?sdl2.Texture = null,
    // Debug flag to visualize composited layer boundaries
    debug_layer_borders: bool = false,

    // Create a new Browser instance
    pub fn init(al: std.mem.Allocator, rtl_flag: bool) !Browser {
        // Initialize SDL
        try sdl2.init(.{
            .video = true,
        });

        // Create a window with correct OS graphics
        const screen = try sdl2.createWindow(
            "zibra",
            .default,
            .default,
            initial_window_width,
            initial_window_height,
            .{}, // Not resizable
        );

        // Create a renderer, which will be used to draw to the window
        const renderer = try sdl2.createRenderer(
            screen,
            null,
            .{ .accelerated = true },
        );

        // Log the SDL renderer backend to confirm hardware acceleration
        const renderer_info = try renderer.getInfo();
        const renderer_name = std.mem.span(renderer_info.name);
        std.log.info("SDL renderer backend: {s}", .{renderer_name});

        // Create persistent streaming texture for GPU-accelerated rendering
        // Use ABGR8888 to match z2d's RGBA memory layout (r at lowest address)
        const cached_texture = try sdl2.createTexture(
            renderer,
            .abgr8888,
            .streaming,
            initial_window_width,
            initial_window_height,
        );
        try cached_texture.setBlendMode(.blend);

        // Parse the default browser stylesheet
        var css_parser = try CSSParser.init(al, DEFAULT_STYLE_SHEET);
        defer css_parser.deinit(al);
        const default_rules = try css_parser.parse(al);

        const layout_engine = try Layout.init(
            al,
            renderer,
            initial_window_width,
            initial_window_height,
            rtl_flag,
        );

        // Create z2d surface for drawing (RGBA format like the tutorial)
        var root_surface = try z2d.Surface.init(.image_surface_rgba, al, initial_window_width, initial_window_height);
        errdefer root_surface.deinit(al);

        // Create z2d context for drawing operations
        var context = z2d.Context.init(al, &root_surface);
        errdefer context.deinit();

        // Initialize JavaScript engine
        const js_engine = try js_module.init(al);
        errdefer js_engine.deinit(al);

        const measure = try MeasureTime.init(al);

        var browser = Browser{
            .allocator = al,
            .window = screen,
            .canvas = renderer,
            .root_surface = root_surface,
            .context = context,
            .chrome_surface = undefined, // Will be set below
            .tab_surface = null,
            .http_client = .{ .allocator = al },
            .cache = try Cache.init(al),
            .cookie_jar = std.StringHashMap(url_module.CookieEntry).init(al),
            .layout_engine = layout_engine,
            .default_style_sheet_rules = default_rules,
            .tabs = std.ArrayList(*Tab).empty,
            .chrome = try Chrome.init(&layout_engine.font_manager, initial_window_width, al),
            .js_engine = js_engine,
            .measure = measure,
            .cached_texture = cached_texture,
            .composited_layers = std.ArrayList(CompositedLayer).empty,
            .tab_draw_list = std.ArrayList(DisplayItem).empty,
        };

        // Create chrome surface (fixed height based on chrome.bottom)
        browser.chrome_surface = try z2d.Surface.init(.image_surface_rgba, al, initial_window_width, @intCast(browser.chrome.bottom));
        errdefer browser.chrome_surface.deinit(al);

        _ = browser.measure.registerThread("Browser thread") catch |err| {
            std.log.warn("Failed to register browser thread: {}", .{err});
        };

        return browser;
    }

    // Get the active tab (if any)
    pub fn activeTab(self: *const Browser) ?*Tab {
        if (self.active_tab_index) |idx| {
            if (idx < self.tabs.items.len) {
                return self.tabs.items[idx];
            }
        }
        return null;
    }

    fn clampScroll(self: *Browser, scroll: i32) i32 {
        const visible = self.window_height - self.chrome.bottom;
        const max_height = @max(self.active_tab_height, visible);
        const maxscroll = @max(max_height - visible, 0);
        if (scroll < 0) return 0;
        if (scroll > maxscroll) return maxscroll;
        return scroll;
    }

    pub fn handleScroll(self: *Browser, delta: i32) void {
        var should_schedule = false;
        self.lock.lock();
        const tab = self.activeTab();
        if (tab) |_| {
            if (self.active_tab_height > 0) {
                const new_scroll = self.clampScroll(self.active_tab_scroll + delta);
                if (new_scroll != self.active_tab_scroll) {
                    self.active_tab_scroll = new_scroll;
                    self.needs_composite = true;
                    self.needs_raster = true;
                    self.needs_draw = true;
                    self.needs_animation_frame = true;
                    self.animation_timer_active = false;
                    should_schedule = true;
                }
            }
        }
        self.lock.unlock();
        if (should_schedule) {
            self.scheduleAnimationFrame();
        }
    }

    pub fn setActiveTab(self: *Browser, tab: *Tab) void {
        var should_schedule = false;
        self.lock.lock();
        var found_idx: ?usize = null;
        var scan_idx: usize = 0;
        while (scan_idx < self.tabs.items.len) {
            if (self.tabs.items[scan_idx] == tab) {
                found_idx = scan_idx;
                break;
            }
            scan_idx += 1;
        }
        if (found_idx) |idx| {
            self.active_tab_index = idx;
            self.active_tab_scroll = 0;
            if (self.active_tab_url) |url| {
                self.allocator.free(url);
            }
            self.active_tab_url = null;

            // Clear compositing state when switching tabs
            for (self.composited_layers.items) |*layer| {
                layer.deinit(self.allocator);
            }
            self.composited_layers.items.len = 0;
            self.tab_draw_list.items.len = 0;
            if (self.active_tab_display_list) |old_list| {
                DisplayItem.freeList(self.allocator, old_list);
            }
            self.active_tab_display_list = null;

            // Reset all dirty flags to force full rebuild
            self.needs_composite = true;
            self.needs_raster = true;
            self.needs_draw = true;
            self.needs_animation_frame = true;
            self.animation_timer_active = false;
            should_schedule = true;
        }
        self.lock.unlock();
        if (should_schedule) {
            self.scheduleAnimationFrame();
        }
    }

    // Free the resources used by the browser
    // Deprecated: use deinit() instead
    pub fn free(self: *Browser) void {
        self.deinit();
    }

    // Create a new tab and load a URL into it
    pub fn newTab(self: *Browser, url: Url) !void {
        const tab_height = self.window_height - self.chrome.bottom;
        const tab = try self.allocator.create(Tab);
        var tab_inited = false;
        defer if (!tab_inited) {
            self.allocator.destroy(tab);
        };
        tab.* = Tab.init(self.allocator, tab_height, &self.measure);
        tab.browser = self;
        // Start the task runner thread now that the Tab is in its final memory location
        try tab.start();
        tab_inited = true;

        try self.tabs.append(self.allocator, tab);
        self.setActiveTab(tab);

        const url_ptr = try self.allocator.create(Url);
        url_ptr.* = url;
        var url_owned = true;
        defer if (url_owned) {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        };

        try self.scheduleLoad(tab, url_ptr, null);
        url_owned = false;
    }

    // Run the browser event loop
    pub fn run(self: *Browser) !void {
        var quit = false;
        self.scheduleAnimationFrame();

        while (!quit) {
            // Use waitEventTimeout to be responsive to system events while still
            // limiting frame rate. This prevents the macOS beach ball by waking
            // immediately when events arrive instead of blocking in delay().
            if (sdl2.waitEventTimeout(17)) |event| {
                if (try self.handleEvent(event)) {
                    quit = true;
                }

                // Process any additional pending events without blocking
                while (sdl2.pollEvent()) |extra_event| {
                    if (try self.handleEvent(extra_event)) {
                        quit = true;
                        break;
                    }
                }
            }

            if (!quit) {
                try self.compositeRasterAndDraw();
                self.scheduleAnimationFrame();
            }
        }

        // Signal shutdown to background threads before cleanup
        self.lock.lock();
        self.shutting_down = true;
        self.lock.unlock();

        // Give background threads a moment to notice shutdown
        std.Thread.sleep(50_000_000); // 50ms
    }

    // Handle a single SDL event. Returns true if quit was requested.
    fn handleEvent(self: *Browser, event: sdl2.Event) !bool {
        switch (event) {
            .quit => return true,
            .key_down => |kb_event| {
                try self.handleKeyEvent(kb_event.keycode);
            },
            .text_input => |text_event| {
                const text = std.mem.sliceTo(&text_event.text, 0);
                var chrome_changed = false;
                for (text) |char| {
                    if (char >= 0x20 and char < 0x7f) {
                        if (try self.chrome.keypress(char)) {
                            chrome_changed = true;
                        }
                        if (self.focus) |focus_str| {
                            if (std.mem.eql(u8, focus_str, "content")) {
                                if (self.activeTab()) |tab| {
                                    self.scheduleTabKeypressTask(tab, char);
                                }
                            }
                        }
                    }
                }
                if (chrome_changed) {
                    self.setNeedsCompositeRasterDraw();
                }
            },
            .mouse_wheel => |wheel_event| {
                if (wheel_event.delta_y > 0) {
                    self.handleScroll(-scroll_step);
                } else if (wheel_event.delta_y < 0) {
                    self.handleScroll(scroll_step);
                }
            },
            .mouse_button_down => |button_event| {
                if (button_event.button == .left) {
                    try self.handleClick(button_event.x, button_event.y);
                }
            },
            .window => |window_event| {
                try self.handleWindowEvent(window_event);
            },
            else => {},
        }
        return false;
    }

    pub fn handleWindowEvent(self: *Browser, window_event: sdl2.WindowEvent) !void {
        switch (window_event.type) {
            .resized, .size_changed => |size| {
                // Adjust renderer viewport to match new window size
                try self.canvas.setViewport(null);

                self.window_width = size.width;
                self.window_height = size.height;

                // Update layout engine's window dimensions
                self.layout_engine.window_width = size.width;
                self.layout_engine.window_height = size.height;

                // Recreate z2d surfaces with new dimensions
                self.context.deinit();
                self.root_surface.deinit(self.allocator);
                self.root_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, size.width, size.height);
                self.context = z2d.Context.init(self.allocator, &self.root_surface);

                // Recreate chrome surface with new width
                self.chrome_surface.deinit(self.allocator);
                self.chrome_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, size.width, @intCast(self.chrome.bottom));

                // Recreate tab surface if it exists
                if (self.tab_surface) |*tab_surface| {
                    const tab_height = tab_surface.getHeight();
                    tab_surface.deinit(self.allocator);
                    self.tab_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, size.width, tab_height);
                }

                // Recreate cached SDL texture with new dimensions
                if (self.cached_texture) |tex| {
                    tex.destroy();
                }
                // Use ABGR8888 to match z2d's RGBA memory layout
                self.cached_texture = try sdl2.createTexture(
                    self.canvas,
                    .abgr8888,
                    .streaming,
                    @intCast(size.width),
                    @intCast(size.height),
                );
                try self.cached_texture.?.setBlendMode(.blend);

                // Force re-raster and redraw
                try self.canvas.setColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
                try self.canvas.clear();
                self.setNeedsCompositeRasterDraw();
                try self.compositeRasterAndDraw();
            },
            else => {},
        }
    }

    fn handleKeyEvent(self: *Browser, key: sdl2.Keycode) !void {
        switch (key) {
            .tab => {
                self.lock.lock();
                const should_cycle = if (self.focus) |focus_str| std.mem.eql(u8, focus_str, "content") else false;
                const tab = self.activeTab();
                self.lock.unlock();
                if (should_cycle) {
                    if (tab) |active_tab| {
                        self.scheduleTabCycleFocusTask(active_tab);
                    }
                }
                return;
            },
            .escape => {
                var should_clear_focus = false;
                var tab_to_clear: ?*Tab = null;
                self.lock.lock();
                if (self.focus) |focus_str| {
                    if (std.mem.eql(u8, focus_str, "content")) {
                        tab_to_clear = self.activeTab();
                        should_clear_focus = true;
                    }
                }
                if (should_clear_focus) {
                    self.focus = null;
                }
                self.lock.unlock();
                if (should_clear_focus) {
                    if (tab_to_clear) |active_tab| {
                        self.scheduleTabClearFocusTask(active_tab);
                    }
                }
                self.setNeedsCompositeRasterDraw();
                try self.compositeRasterAndDraw();
                return;
            },
            .backspace => {
                const chrome_changed = self.chrome.backspace();
                self.lock.lock();
                const should_backspace = if (self.focus) |focus_str| std.mem.eql(u8, focus_str, "content") else false;
                const tab = self.activeTab();
                self.lock.unlock();
                if (should_backspace) {
                    if (tab) |active_tab| {
                        self.scheduleTabBackspaceTask(active_tab);
                    }
                }
                if (chrome_changed) {
                    self.setNeedsCompositeRasterDraw();
                    try self.compositeRasterAndDraw();
                }
                return;
            },
            .down => {
                self.handleScroll(scroll_step);
                try self.compositeRasterAndDraw();
                return;
            },
            .up => {
                self.handleScroll(-scroll_step);
                try self.compositeRasterAndDraw();
                return;
            },
            else => {},
        }
    }

    // Handle mouse clicks to navigate links
    fn handleClick(self: *Browser, screen_x: i32, screen_y: i32) !void {
        std.debug.print("Click detected at screen ({d}, {d})\n", .{ screen_x, screen_y });

        self.lock.lock();
        const chrome_bottom = self.chrome.bottom;
        if (screen_y < chrome_bottom) {
            self.focus = null;
            self.lock.unlock();
            if (try self.chrome.click(self, screen_x, screen_y)) {
                self.setNeedsCompositeRasterDraw();
                try self.compositeRasterAndDraw();
            }
            return;
        }

        const tab = self.activeTab() orelse {
            self.lock.unlock();
            return;
        };

        self.focus = "content";
        self.chrome.blur();
        self.lock.unlock();

        self.setNeedsCompositeRasterDraw();
        try self.compositeRasterAndDraw();

        const tab_y = screen_y - chrome_bottom;
        const page_x = screen_x;
        const page_y = tab_y + tab.scroll;

        std.debug.print("Page coordinates: ({d}, {d})\n", .{ page_x, page_y });

        if (tab.current_node == null) {
            std.debug.print("No current_node\n", .{});
            return;
        }

        std.debug.print("Current URL: {s}\n", .{if (tab.current_url) |url_ptr| url_ptr.*.path else "none"});

        var handled_link = false;
        for (self.layout_engine.link_bounds.items) |entry| {
            const bounds = entry.bounds;
            if (page_x >= bounds.x and page_x < bounds.x + bounds.width and
                page_y >= bounds.y and page_y < bounds.y + bounds.height)
            {
                const link_node = entry.node;
                const prevent_default = self.js_engine.dispatchEvent("click", link_node) catch |err| blk: {
                    std.log.warn("Failed to dispatch click event: {}", .{err});
                    break :blk false;
                };
                if (prevent_default) {
                    std.debug.print("Click default prevented for link\n", .{});
                    return;
                }

                switch (link_node.*) {
                    .element => |*link_element| {
                        if (link_element.attributes) |attrs| {
                            if (attrs.get("href")) |href| {
                                if (tab.current_url) |current_url_ptr| {
                                    var resolved_url = try current_url_ptr.*.resolve(self.allocator, href);
                                    std.debug.print("Loading link: {s}\n", .{href});

                                    const new_url_ptr = self.allocator.create(Url) catch |alloc_err| {
                                        std.log.err("Failed to allocate URL: {any}", .{alloc_err});
                                        resolved_url.free(self.allocator);
                                        return;
                                    };
                                    new_url_ptr.* = resolved_url;
                                    var url_owned = true;
                                    defer if (url_owned) {
                                        new_url_ptr.*.free(self.allocator);
                                        self.allocator.destroy(new_url_ptr);
                                    };

                                    self.scheduleLoad(tab, new_url_ptr, null) catch |err| {
                                        std.log.err("Failed to schedule load for {s}: {any}", .{ href, err });
                                        return;
                                    };
                                    url_owned = false;

                                    self.setNeedsCompositeRasterDraw();
                                    try self.compositeRasterAndDraw();
                                    handled_link = true;
                                } else {
                                    std.debug.print("No current_url to resolve against\n", .{});
                                }
                            }
                        }
                    },
                    else => {},
                }

                if (handled_link) {
                    return;
                }
            }
        }

        self.scheduleTabClickTask(tab, page_x, page_y);
    }

    fn scheduleTabClickTask(self: *Browser, tab: *Tab, x: i32, y: i32) void {
        const ctx = TabClickTaskContext.create(self.allocator, self, tab, x, y) catch |err| {
            std.log.err("Failed to allocate tab click task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabClickTaskContext.runOpaque,
            TabClickTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule tab click: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabKeypressTask(self: *Browser, tab: *Tab, char: u8) void {
        const ctx = TabKeypressTaskContext.create(self.allocator, self, tab, char) catch |err| {
            std.log.err("Failed to allocate keypress task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabKeypressTaskContext.runOpaque,
            TabKeypressTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule keypress: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabBackspaceTask(self: *Browser, tab: *Tab) void {
        const ctx = TabBackspaceTaskContext.create(self.allocator, self, tab) catch |err| {
            std.log.err("Failed to allocate backspace task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabBackspaceTaskContext.runOpaque,
            TabBackspaceTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule backspace: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabCycleFocusTask(self: *Browser, tab: *Tab) void {
        const ctx = TabCycleFocusTaskContext.create(self.allocator, self, tab) catch |err| {
            std.log.err("Failed to allocate cycle focus task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabCycleFocusTaskContext.runOpaque,
            TabCycleFocusTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule cycle focus: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    fn scheduleTabClearFocusTask(self: *Browser, tab: *Tab) void {
        const ctx = TabClearFocusTaskContext.create(self.allocator, self, tab) catch |err| {
            std.log.err("Failed to allocate clear focus task: {}", .{err});
            return;
        };
        const task_instance = Task.init(
            ctx.toOpaque(),
            TabClearFocusTaskContext.runOpaque,
            TabClearFocusTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            std.log.err("Failed to schedule clear focus: {}", .{err});
            ctx.destroy();
            return;
        };
    }

    // Update the scroll offset
    pub fn fetchBody(self: *Browser, url: Url, referrer: ?Url, payload: ?[]const u8) !url_module.HttpResponse {
        if (std.mem.eql(u8, url.scheme, "file")) {
            const content = try url.fileRequest(self.allocator);
            return .{ .body = content, .csp_header = null };
        } else if (std.mem.eql(u8, url.scheme, "data")) {
            return .{ .body = url.path, .csp_header = null };
        } else if (std.mem.eql(u8, url.scheme, "about")) {
            return .{ .body = url.aboutRequest(), .csp_header = null };
        }

        self.http_client_mutex.lock();
        defer self.http_client_mutex.unlock();

        const response = url.httpRequest(
            self.allocator,
            &self.http_client,
            &self.cache,
            &self.cookie_jar,
            referrer,
            payload,
        ) catch |err| {
            if (err == error.UnexpectedCharacter) {
                std.log.warn("httpRequest parser error for {s}", .{url.path});
            }
            return err;
        };
        return response;
    }

    // Send request to a URL, load response into a tab
    pub fn loadInTab(
        self: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        std.log.info("Loading: {s}", .{url.*.path});

        tab.task_runner.clear();
        tab.invalidateJsContext();
        self.js_engine.setNodes(null);
        self.js_engine.setRenderCallback(null, null);
        self.js_engine.setXhrCallback(null, null);
        self.js_engine.setSetTimeoutCallback(null, null);
        self.js_engine.setAnimationFrameCallback(null, null);

        tab.scroll = 0;
        tab.scroll_changed_in_tab = true;

        var referrer_value: ?Url = null;
        if (tab.current_url) |ref_ptr| {
            referrer_value = ref_ptr.*;
        }

        // Do the request, getting back the body of the response.
        const response = try self.fetchBody(url.*, referrer_value, payload);
        defer if (response.csp_header) |hdr| self.allocator.free(hdr);

        tab.clearAllowedOrigins();
        if (response.csp_header) |hdr| {
            tab.applyContentSecurityPolicy(hdr, url.*) catch |err| {
                std.log.warn("Failed to apply Content-Security-Policy: {}", .{err});
            };
        }

        const body = response.body;

        // Free previous HTML source if it exists
        if (tab.current_html_source) |old_source| {
            self.allocator.free(old_source);
            tab.current_html_source = null;
        }

        if (url.*.view_source) {
            // Use the new layoutSourceCode function for view-source mode
            defer if (!std.mem.eql(u8, url.*.scheme, "about")) self.allocator.free(body);

            if (tab.display_list) |items| {
                DisplayItem.freeList(self.allocator, items);
            }

            if (tab.document_layout) |doc| {
                doc.deinit();
                self.allocator.destroy(doc);
                tab.document_layout = null;
            }

            if (tab.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                tab.current_node = null;
            }

            tab.display_list = try self.layout_engine.layoutSourceCode(body);
            tab.content_height = self.layout_engine.content_height;
        } else {
            // Parse HTML into a node tree
            var html_parser = try HTMLParser.init(self.allocator, body);
            defer html_parser.deinit(self.allocator);

            // Clear any previous node tree
            if (tab.current_node) |node| {
                var n = node;
                n.deinit(self.allocator);
                tab.current_node = null;
            }

            // Parse the HTML and store the root node
            tab.current_node = try html_parser.parse();

            // IMPORTANT: Fix parent pointers after copying the tree
            // The parse() method returns the tree by value, which copies it,
            // but the parent pointers still point to the old locations
            parser.fixParentPointers(&tab.current_node.?, null);

            // Store the HTML source (it contains slices used by the tree)
            // Only store if it's not an about: URL (those return static strings)
            if (!std.mem.eql(u8, url.*.scheme, "about")) {
                tab.current_html_source = body;
            }

            // Update the JS engine with the current nodes for DOM API
            self.js_engine.setNodes(&tab.current_node.?);
            tab.js_render_context.setPointers(
                @as(?*anyopaque, @ptrCast(self)),
                @as(?*anyopaque, @ptrCast(tab)),
            );
            tab.js_render_context.setGeneration(tab.js_generation);
            tab.js_render_context_initialized = true;
            self.js_engine.setRenderCallback(
                jsRenderCallback,
                @ptrCast(&tab.js_render_context),
            );
            self.js_engine.setXhrCallback(
                jsXhrCallback,
                @ptrCast(&tab.js_render_context),
            );
            self.js_engine.setAnimationFrameCallback(
                jsRequestAnimationFrameCallback,
                @ptrCast(&tab.js_render_context),
            );
            self.js_engine.setSetTimeoutCallback(
                jsSetTimeoutCallback,
                @ptrCast(&tab.js_render_context),
            );

            // Find all scripts and stylesheets
            var node_list = std.ArrayList(*parser.Node).empty;
            defer node_list.deinit(self.allocator);
            try parser.treeToList(self.allocator, &tab.current_node.?, &node_list);

            // Queue external scripts to run later
            for (node_list.items) |node| {
                switch (node.*) {
                    .element => |e| {
                        if (std.mem.eql(u8, e.tag, "script")) {
                            if (e.attributes) |attrs| {
                                if (attrs.get("src")) |src| {
                                    self.scheduleScriptTask(tab, url, src) catch |err| {
                                        std.log.warn("Failed to schedule script {s}: {}", .{ src, err });
                                    };
                                }
                            }
                        }
                    },
                    .text => {},
                }
            }

            // Collect stylesheet URLs from <link rel="stylesheet" href="..."> elements
            var stylesheet_urls = std.ArrayList([]const u8).empty;
            defer {
                for (stylesheet_urls.items) |href| {
                    self.allocator.free(href);
                }
                stylesheet_urls.deinit(self.allocator);
            }

            for (node_list.items) |node| {
                switch (node.*) {
                    .element => |e| {
                        if (std.mem.eql(u8, e.tag, "link")) {
                            if (e.attributes) |attrs| {
                                const rel = attrs.get("rel");
                                const href = attrs.get("href");

                                if (rel != null and href != null and
                                    std.mem.eql(u8, rel.?, "stylesheet"))
                                {
                                    // Copy the href string for later use
                                    const href_copy = try self.allocator.alloc(u8, href.?.len);
                                    @memcpy(href_copy, href.?);
                                    try stylesheet_urls.append(self.allocator, href_copy);
                                }
                            }
                        }
                    },
                    .text => {},
                }
            }

            // Note: We use self.allocator directly for CSS parsing instead of an arena
            // because the CSS rules need to live as long as the Tab (for re-rendering)

            // Load and parse external stylesheets
            var all_rules = std.ArrayList(CSSParser.CSSRule).empty;

            // Track how many default rules we have so we don't double-free them
            const default_rules_count = self.default_style_sheet_rules.len;

            defer {
                // Only deinit rules that were allocated in this function (external stylesheets)
                // Skip the first default_rules_count rules as they're owned by the browser
                if (all_rules.items.len > default_rules_count) {
                    for (all_rules.items[default_rules_count..]) |*rule| {
                        var mutable_rule = rule;
                        mutable_rule.deinit(self.allocator);
                    }
                }
                all_rules.deinit(self.allocator);
            }

            // Start with default browser stylesheet rules (shallow copy, browser still owns them)
            for (self.default_style_sheet_rules) |rule| {
                try all_rules.append(self.allocator, rule);
            }

            // Download and parse each linked stylesheet
            for (stylesheet_urls.items) |href| {
                std.log.info("Loading stylesheet: {s}", .{href});

                // Resolve relative URL against the current page URL
                const stylesheet_url = url.*.resolve(self.allocator, href) catch |err| {
                    std.log.warn("Failed to resolve stylesheet URL {s}: {}", .{ href, err });
                    continue;
                };
                defer stylesheet_url.free(self.allocator);

                if (!tab.allowedRequest(stylesheet_url, url)) {
                    std.log.warn("Blocked stylesheet {s} due to CSP", .{href});
                    continue;
                }

                // Fetch the stylesheet
                const css_response = self.fetchBody(stylesheet_url, url.*, null) catch |err| {
                    std.log.warn("Failed to load stylesheet {s}: {}", .{ href, err });
                    continue;
                };
                defer if (css_response.csp_header) |hdr| self.allocator.free(hdr);

                var css_text = css_response.body;
                if (std.mem.eql(u8, stylesheet_url.scheme, "data") or std.mem.eql(u8, stylesheet_url.scheme, "about")) {
                    const copy = try self.allocator.alloc(u8, css_text.len);
                    @memcpy(copy, css_text);
                    css_text = copy;
                }

                // Parse the stylesheet using self.allocator
                // (CSS rules need to live as long as the Tab)
                var css_parser = try CSSParser.init(self.allocator, css_text);
                defer css_parser.deinit(self.allocator);

                const parsed_rules = css_parser.parse(self.allocator) catch |err| {
                    std.log.warn("Failed to parse stylesheet {s}: {}", .{ href, err });
                    // Free css_text before continuing
                    self.allocator.free(css_text);
                    continue;
                };

                // Store css_text so it can be freed when the Tab is destroyed
                // (CSS rules reference strings within this text)
                try tab.css_texts.append(self.allocator, css_text);

                // Add the parsed rules to our collection
                for (parsed_rules) |rule| {
                    try all_rules.append(self.allocator, rule);
                }

                // Free the parsed_rules slice (the rules themselves are now in all_rules)
                self.allocator.free(parsed_rules);
            }

            // Sort rules by cascade priority (more specific selectors override less specific)
            // Stable sort preserves file order for rules with equal priority
            std.mem.sort(CSSParser.CSSRule, all_rules.items, {}, struct {
                fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
                    return a.cascadePriority() < b.cascadePriority();
                }
            }.lessThan);

            // Clean up old CSS rules and texts before replacing them
            // First, free the property hashmaps for external stylesheet rules (not default rules)
            if (tab.rules.items.len > tab.default_rules_count) {
                for (tab.rules.items[tab.default_rules_count..]) |*rule| {
                    rule.properties.deinit();
                }
            }

            // Free old CSS text buffers
            for (tab.css_texts.items) |old_css_text| {
                self.allocator.free(old_css_text);
            }
            tab.css_texts.clearRetainingCapacity();

            // Now clear the rules list
            tab.rules.clearRetainingCapacity();

            // Track how many default rules we have (these are borrowed, not owned)
            tab.default_rules_count = default_rules_count;

            // Copy all rules to tab (first N are borrowed, rest are owned)
            for (all_rules.items) |rule| {
                try tab.rules.append(self.allocator, rule);
            }

            // Apply all stylesheet rules and inline styles (sorted by cascade order)
            try parser.style(self.allocator, &tab.current_node.?, tab.rules.items);

            // Layout using the HTML node tree
            try self.layoutTabNodes(tab);
        }

        // Record navigation history and update current URL ownership
        try tab.history.append(self.allocator, url);
        tab.current_url = url;
        tab.setNeedsRender();
    }

    pub fn scheduleLoad(
        self: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !void {
        const ctx = try LoadTaskContext.create(
            self.allocator,
            self,
            tab,
            url,
            payload,
        );
        tab.task_runner.clear();
        const task_instance = Task.init(
            ctx.toOpaque(),
            LoadTaskContext.runOpaque,
            LoadTaskContext.cleanupOpaque,
        );
        tab.task_runner.schedule(task_instance) catch |err| {
            ctx.destroy();
            return err;
        };
    }

    fn scheduleScriptTask(
        self: *Browser,
        tab: *Tab,
        page_url: *Url,
        src: []const u8,
    ) !void {
        if (!tab.js_render_context_initialized) return;
        std.log.info("Loading script: {s}", .{src});

        const src_copy = try self.allocator.alloc(u8, src.len);
        @memcpy(src_copy, src);
        var src_copy_owned = false;
        defer if (!src_copy_owned) self.allocator.free(src_copy);

        var script_url = try page_url.*.resolve(self.allocator, src);
        var url_owned = true;
        defer if (url_owned) script_url.free(self.allocator);

        if (!tab.allowedRequest(script_url, page_url)) {
            std.log.warn("Blocked script {s} due to CSP", .{src});
            return;
        }

        const script_response = self.fetchBody(script_url, page_url.*, null) catch |err| {
            std.log.warn("Failed to load script {s}: {}", .{ src, err });
            return;
        };
        defer if (script_response.csp_header) |hdr| self.allocator.free(hdr);

        var script_body = script_response.body;
        if (std.mem.eql(u8, script_url.scheme, "data") or std.mem.eql(u8, script_url.scheme, "about")) {
            const copy = try self.allocator.alloc(u8, script_body.len);
            @memcpy(copy, script_body);
            script_body = copy;
        }
        defer self.allocator.free(script_body);

        const body_copy = try self.allocator.alloc(u8, script_body.len);
        @memcpy(body_copy, script_body);
        var body_copy_owned = false;
        defer if (!body_copy_owned) self.allocator.free(body_copy);

        const js_context = &tab.js_render_context;
        const generation = js_context.currentGeneration();

        const ctx = try ScriptTaskContext.create(
            self.allocator,
            self,
            tab,
            js_context,
            generation,
            src_copy,
            script_url,
            body_copy,
        );
        src_copy_owned = true;
        body_copy_owned = true;
        url_owned = false;
        errdefer ctx.destroy();

        const task_instance = Task.init(
            ctx.toOpaque(),
            ScriptTaskContext.runOpaque,
            ScriptTaskContext.cleanupOpaque,
        );
        try tab.task_runner.schedule(task_instance);
    }

    fn scheduleSetTimeoutTask(
        self: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        handle: u32,
        delay_ms: u32,
    ) !void {
        if (!tab.js_render_context_initialized) return;
        const generation = js_context.currentGeneration();

        const thread_ctx = try SetTimeoutThreadContext.create(
            self.allocator,
            self,
            tab,
            js_context,
            generation,
            handle,
            delay_ms,
        );

        tab.retainAsyncThread();
        const thread = std.Thread.spawn(.{}, runSetTimeoutThread, .{thread_ctx}) catch |err| {
            tab.releaseAsyncThread();
            thread_ctx.destroy();
            return err;
        };
        _ = thread.setName("SetTimeout thread") catch |err| {
            std.log.warn("Failed to name setTimeout thread: {}", .{err});
        };
        thread.detach();
    }

    pub fn scheduleAnimationFrame(self: *Browser) void {
        self.lock.lock();
        if (self.shutting_down or self.animation_timer_active or !self.needs_animation_frame or self.activeTab() == null) {
            self.lock.unlock();
            return;
        }
        self.animation_timer_active = true;
        self.needs_animation_frame = false;
        self.lock.unlock();

        const ctx = AnimationTimerContext.create(self) catch |err| {
            std.log.warn("Failed to allocate animation timer context: {}", .{err});
            self.lock.lock();
            self.animation_timer_active = false;
            self.needs_animation_frame = true;
            self.lock.unlock();
            return;
        };

        const thread = std.Thread.spawn(.{}, runAnimationTimerThread, .{ctx}) catch |err| {
            std.log.warn("Failed to spawn animation timer thread: {}", .{err});
            ctx.destroy();
            self.lock.lock();
            self.animation_timer_active = false;
            self.needs_animation_frame = true;
            self.lock.unlock();
            return;
        };
        _ = thread.setName("Animation timer thread") catch |err| {
            std.log.warn("Failed to name animation timer thread: {}", .{err});
        };
        thread.detach();
    }

    fn scheduleAsyncXhr(
        self: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        generation: u64,
        resolved_url: Url,
        payload: ?[]const u8,
        handle: u32,
    ) !void {
        const ctx = try XhrThreadContext.create(
            self.allocator,
            self,
            tab,
            js_context,
            generation,
            resolved_url,
            payload,
            handle,
        );

        tab.retainAsyncThread();
        const thread = std.Thread.spawn(.{}, runXhrThread, .{ctx}) catch |err| {
            tab.releaseAsyncThread();
            ctx.destroy();
            return err;
        };
        _ = thread.setName("XHR thread") catch |err| {
            std.log.warn("Failed to name XHR thread: {}", .{err});
        };
        thread.detach();
    }

    // Layout a tab's HTML nodes with the tree-based layout
    pub fn layoutTabNodes(self: *Browser, tab: *Tab) !void {
        if (tab.current_node == null) {
            return error.NoNodeToLayout;
        }

        // Clear previous document layout if it exists
        if (tab.document_layout != null) {
            tab.document_layout.?.deinit();
            self.allocator.destroy(tab.document_layout.?);
            tab.document_layout = null;
        }

        // Create and layout the document tree
        tab.document_layout = try self.layout_engine.buildDocument(tab.current_node.?);

        // Paint the document to produce draw commands
        if (tab.display_list) |items| {
            DisplayItem.freeList(self.allocator, items);
        }
        tab.display_list = try self.layout_engine.paintDocument(tab.document_layout.?);

        // Debug: print display list tree once when opacity effects are present
        if (tab.display_list) |list| {
            const S = struct {
                var printed: bool = false;
            };
            if (!S.printed and DisplayItem.hasOpacityEffects(list)) {
                DisplayItem.debugPrintIfHasOpacity(list);
                S.printed = true;
            }
        }

        // Update content height from the layout engine
        tab.content_height = self.layout_engine.content_height;
    }

    /// Build composited layers from the display list
    /// Returns true if layers were rebuilt, false if using cached layers
    pub fn composite(self: *Browser) !bool {
        if (self.active_tab_display_list == null) return false;

        // Clear existing layers (they'll be rebuilt)
        for (self.composited_layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.composited_layers.items.len = 0;

        // Walk the display list and create layers for blend items
        for (self.active_tab_display_list.?) |item| {
            try self.compositeItem(item);
        }

        // Log layer count for optimization verification
        std.log.debug("Compositing complete: {} layers created", .{self.composited_layers.items.len});

        return true;
    }

    /// Recursively process a display item for compositing
    fn compositeItem(self: *Browser, item: DisplayItem) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                const needs_layer = blend_item.needs_compositing;

                if (needs_layer) {
                    // Flatten the subtree to collect all non-composited items
                    var flattened = std.ArrayList(DisplayItem).empty;
                    defer flattened.deinit(self.allocator);
                    try self.flattenSubtree(blend_item.children, &flattened);

                    // Convert to owned slice for the layer
                    const flattened_items = try self.allocator.alloc(DisplayItem, flattened.items.len);
                    @memcpy(flattened_items, flattened.items);

                    // Calculate bounds from flattened children
                    var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                    for (flattened_items) |child| {
                        const child_bounds = self.getDisplayItemBounds(child);
                        bounds.left = @min(bounds.left, child_bounds.left);
                        bounds.top = @min(bounds.top, child_bounds.top);
                        bounds.right = @max(bounds.right, child_bounds.right);
                        bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                    }

                    // Try to merge with the last layer if compatible
                    const can_merge = if (self.composited_layers.items.len > 0) blk: {
                        const last_layer = &self.composited_layers.items[self.composited_layers.items.len - 1];
                        break :blk last_layer.can_merge(blend_item.opacity, blend_item.blend_mode);
                    } else false;

                    if (can_merge) {
                        // Merge into existing layer
                        const last_layer = &self.composited_layers.items[self.composited_layers.items.len - 1];
                        try last_layer.add(self.allocator, flattened_items, bounds);
                    } else {
                        // Create a new composited layer for this blend
                        const layer = CompositedLayer.init(
                            flattened_items,
                            bounds,
                            blend_item.opacity,
                            blend_item.blend_mode,
                            blend_item.node,
                        );
                        try self.composited_layers.append(self.allocator, layer);
                    }
                } else {
                    // No layer needed, recurse into children
                    for (blend_item.children) |child| {
                        try self.compositeItem(child);
                    }
                }
            },
            .transform => |transform_item| {
                // Recurse into transform children - they may contain composited blends
                for (transform_item.children) |child| {
                    try self.compositeItem(child);
                }
            },
            else => {
                // Primitive items don't need compositing decisions
            },
        }
    }

    /// Flatten a subtree of display items by recursively expanding non-composited blends.
    /// This collects all primitive items from a subtree into a flat list for efficient rasterization.
    fn flattenSubtree(self: *Browser, items: []DisplayItem, result: *std.ArrayList(DisplayItem)) !void {
        for (items) |item| {
            switch (item) {
                .blend => |blend_item| {
                    if (blend_item.needs_compositing) {
                        // Composited blends stay as-is (they'll create their own layer)
                        try result.append(self.allocator, item);
                    } else {
                        // Non-composited blends are flattened - recurse into children
                        try self.flattenSubtree(blend_item.children, result);
                    }
                },
                .transform => |transform_item| {
                    // Transforms need to be preserved to apply translation during rendering
                    // Recursively flatten children but wrap them in the transform
                    var flattened_children = std.ArrayList(DisplayItem).empty;
                    defer flattened_children.deinit(self.allocator);
                    try self.flattenSubtree(transform_item.children, &flattened_children);

                    if (flattened_children.items.len > 0) {
                        // Create a new transform with the flattened children
                        const children_copy = try self.allocator.alloc(DisplayItem, flattened_children.items.len);
                        @memcpy(children_copy, flattened_children.items);
                        try result.append(self.allocator, .{
                            .transform = .{
                                .translate_x = transform_item.translate_x,
                                .translate_y = transform_item.translate_y,
                                .children = children_copy,
                                .node = transform_item.node,
                            },
                        });
                    }
                },
                else => {
                    // Primitive items are added directly
                    try result.append(self.allocator, item);
                },
            }
        }
    }

    /// Get the bounding rect of a display item
    fn getDisplayItemBounds(self: *Browser, item: DisplayItem) Rect {
        return switch (item) {
            .glyph => |g| Rect{
                .left = g.x,
                .top = g.y,
                .right = g.x + g.glyph.w,
                .bottom = g.y + g.glyph.h,
            },
            .rect => |r| Rect{
                .left = r.x1,
                .top = r.y1,
                .right = r.x2,
                .bottom = r.y2,
            },
            .rounded_rect => |r| Rect{
                .left = r.x1,
                .top = r.y1,
                .right = r.x2,
                .bottom = r.y2,
            },
            .line => |l| Rect{
                .left = @min(l.x1, l.x2),
                .top = @min(l.y1, l.y2),
                .right = @max(l.x1, l.x2) + l.thickness,
                .bottom = @max(l.y1, l.y2) + l.thickness,
            },
            .outline => |o| Rect{
                .left = o.rect.left,
                .top = o.rect.top,
                .right = o.rect.right,
                .bottom = o.rect.bottom,
            },
            .blend => |b| blk: {
                var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                for (b.children) |child| {
                    const child_bounds = self.getDisplayItemBounds(child);
                    bounds.left = @min(bounds.left, child_bounds.left);
                    bounds.top = @min(bounds.top, child_bounds.top);
                    bounds.right = @max(bounds.right, child_bounds.right);
                    bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                }
                break :blk bounds;
            },
            .draw_composited_layer => |dcl| dcl.layer.bounds,
            .transform => |t| blk: {
                // Get children bounds and apply translation offset
                var bounds = Rect{ .left = std.math.maxInt(i32), .top = std.math.maxInt(i32), .right = std.math.minInt(i32), .bottom = std.math.minInt(i32) };
                for (t.children) |child| {
                    const child_bounds = self.getDisplayItemBounds(child);
                    bounds.left = @min(bounds.left, child_bounds.left);
                    bounds.top = @min(bounds.top, child_bounds.top);
                    bounds.right = @max(bounds.right, child_bounds.right);
                    bounds.bottom = @max(bounds.bottom, child_bounds.bottom);
                }
                // Apply translation to get absolute bounds
                break :blk Rect{
                    .left = bounds.left + t.translate_x,
                    .top = bounds.top + t.translate_y,
                    .right = bounds.right + t.translate_x,
                    .bottom = bounds.bottom + t.translate_y,
                };
            },
        };
    }

    /// Build a draw list from composited layers
    pub fn paint_draw_list(self: *Browser) !void {
        self.tab_draw_list.items.len = 0;

        if (self.active_tab_display_list == null) return;

        // Walk the display list and emit draw commands
        var layer_index: usize = 0;
        for (self.active_tab_display_list.?) |item| {
            try self.paintItem(item, &layer_index);
        }
    }

    /// Recursively emit draw commands for an item
    fn paintItem(self: *Browser, item: DisplayItem, layer_index: *usize) !void {
        switch (item) {
            .blend => |blend_item| {
                // Use the pre-computed needs_compositing flag
                if (blend_item.needs_compositing) {
                    // Emit a DrawCompositedLayer pointing to the corresponding layer
                    if (layer_index.* < self.composited_layers.items.len) {
                        try self.tab_draw_list.append(self.allocator, .{
                            .draw_composited_layer = .{
                                .layer = &self.composited_layers.items[layer_index.*],
                            },
                        });
                        layer_index.* += 1;
                    }
                } else {
                    // No layer, emit children directly
                    for (blend_item.children) |child| {
                        try self.paintItem(child, layer_index);
                    }
                }
            },
            .transform => |transform_item| {
                // Transforms preserve their structure but recurse for composited content
                // We need to collect children and emit a transform wrapping them
                var transformed_children = std.ArrayList(DisplayItem).empty;
                defer transformed_children.deinit(self.allocator);

                // Save original draw list length
                const original_len = self.tab_draw_list.items.len;

                // Recurse into children
                for (transform_item.children) |child| {
                    try self.paintItem(child, layer_index);
                }

                // Collect newly added items
                if (self.tab_draw_list.items.len > original_len) {
                    const new_items = self.tab_draw_list.items[original_len..];
                    const children_copy = try self.allocator.alloc(DisplayItem, new_items.len);
                    @memcpy(children_copy, new_items);

                    // Remove the newly added items
                    self.tab_draw_list.items.len = original_len;

                    // Emit transform wrapping those items
                    try self.tab_draw_list.append(self.allocator, .{
                        .transform = .{
                            .translate_x = transform_item.translate_x,
                            .translate_y = transform_item.translate_y,
                            .children = children_copy,
                            .node = transform_item.node,
                        },
                    });
                }
            },
            else => {
                // Primitive items go directly to the draw list
                try self.tab_draw_list.append(self.allocator, item);
            },
        }
    }

    // Raster the browser chrome to the chrome surface
    pub fn rasterChrome(self: *Browser) !void {
        // Create a temporary context for the chrome surface
        var chrome_context = z2d.Context.init(self.allocator, &self.chrome_surface);
        defer chrome_context.deinit();

        // Clear chrome surface (white background)
        chrome_context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } } });
        try chrome_context.moveTo(0, 0);
        try chrome_context.lineTo(@floatFromInt(self.window_width), 0);
        try chrome_context.lineTo(@floatFromInt(self.window_width), @floatFromInt(self.chrome.bottom));
        try chrome_context.lineTo(0, @floatFromInt(self.chrome.bottom));
        try chrome_context.closePath();
        try chrome_context.fill();

        // Draw chrome content
        var chrome_cmds = try self.chrome.paint(self.allocator, self);
        defer chrome_cmds.deinit(self.allocator);
        for (chrome_cmds.items) |item| {
            try self.drawDisplayItemZ2dContext(&chrome_context, item, 0);
        }
    }

    // Raster the current tab to the tab surface using composited layers
    pub fn rasterTab(self: *Browser) !void {
        if (self.active_tab_display_list == null) return;

        // Build composited layers and draw list
        _ = try self.composite();
        try self.paint_draw_list();

        // Raster to surfaces
        try self.rasterTabSurfaces();
    }

    // Raster tab content to surfaces (without rebuilding composite/draw lists)
    fn rasterTabSurfaces(self: *Browser) !void {
        if (self.active_tab_display_list == null) return;

        const tab_height = @max(self.active_tab_height, self.window_height - self.chrome.bottom);

        if (self.tab_surface) |*existing_surface| {
            const current_height = existing_surface.getHeight();
            if (current_height != tab_height) {
                existing_surface.deinit(self.allocator);
                self.tab_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, self.window_width, tab_height);
            }
        } else {
            self.tab_surface = try z2d.Surface.init(.image_surface_rgba, self.allocator, self.window_width, tab_height);
        }

        var tab_context = z2d.Context.init(self.allocator, &self.tab_surface.?);
        defer tab_context.deinit();

        tab_context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } } });
        try tab_context.moveTo(0, 0);
        try tab_context.lineTo(@floatFromInt(self.window_width), 0);
        try tab_context.lineTo(@floatFromInt(self.window_width), @floatFromInt(tab_height));
        try tab_context.lineTo(0, @floatFromInt(tab_height));
        try tab_context.closePath();
        try tab_context.fill();

        // Draw from the composited draw list
        for (self.tab_draw_list.items) |item| {
            try self.drawDisplayItemZ2dContext(&tab_context, item, 0);
        }
    }

    fn compositeRasterAndDraw(self: *Browser) !void {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if any phase is needed
        if (!self.needs_composite and !self.needs_raster and !self.needs_draw) return;

        const trace_raster = self.measure.begin("composite_raster_draw");
        defer if (trace_raster) self.measure.end("composite_raster_draw");

        // Log which phases will run for animation debugging
        std.log.debug("compositeRasterAndDraw: composite={} raster={} draw={}", .{
            self.needs_composite,
            self.needs_raster,
            self.needs_draw,
        });

        // Composite phase: rebuild composited layers from display list
        if (self.needs_composite) {
            _ = try self.composite();
            try self.paint_draw_list();
            self.needs_composite = false;
            // Compositing implies we need to raster the new layers
            self.needs_raster = true;
        }

        // Raster phase: render layers to surfaces
        if (self.needs_raster) {
            try self.rasterChrome();
            try self.rasterTabSurfaces();
            self.needs_raster = false;
            // Rastering implies we need to draw
            self.needs_draw = true;
        }

        // Draw phase: composite surfaces to screen
        if (self.needs_draw) {
            try self.draw();
            self.canvas.present();
            self.needs_draw = false;
        }
    }

    pub fn setNeedsCompositeRasterDraw(self: *Browser) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.needs_composite = true;
        self.needs_raster = true;
        self.needs_draw = true;
    }

    pub fn setNeedsAnimationFrame(self: *Browser, tab: *Tab) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.activeTab()) |active| {
            if (active == tab) {
                self.needs_animation_frame = true;
            }
        }
    }

    pub fn commit(self: *Browser, tab: *Tab, data: CommitData) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.activeTab() != tab) {
            if (data.display_list) |list| {
                DisplayItem.freeList(self.allocator, list);
            }
            return;
        }

        var has_display_list_change = false;
        if (data.display_list) |list| {
            if (self.active_tab_display_list) |old_list| {
                DisplayItem.freeList(self.allocator, old_list);
            }
            self.active_tab_display_list = list;
            // Set parent pointers for tree traversal
            DisplayItem.setParentPointers(list, null);

            // Debug: print display list tree once when opacity effects are present
            const S = struct {
                var printed_opacity_debug: bool = false;
            };
            if (!S.printed_opacity_debug and DisplayItem.hasOpacityEffects(list)) {
                DisplayItem.debugPrintIfHasOpacity(list);
                S.printed_opacity_debug = true;
            }
            has_display_list_change = true;
        }
        if (data.scroll) |scroll| {
            self.active_tab_scroll = scroll;
        }
        self.active_tab_height = data.height;

        if (data.url) |url| {
            self.updateActiveTabUrl(url);
        } else {
            self.clearActiveTabUrl();
        }

        self.animation_timer_active = false;

        // Determine which phases need to run based on what changed
        if (has_display_list_change) {
            // Full display list change requires recomposite/raster/draw
            self.needs_composite = true;
            self.needs_raster = true;
            self.needs_draw = true;
        } else if (data.composited_updates.len > 0) {
            // Composited updates (e.g., opacity animation) only need draw
            // Apply the composited updates to existing layers
            for (data.composited_updates) |update| {
                self.applyCompositedUpdate(update);
            }
            self.needs_draw = true;
        }
    }

    /// Apply a composited update to the matching layer
    fn applyCompositedUpdate(self: *Browser, update: Tab.CompositedUpdate) void {
        // Find the blend item in the display list with matching node pointer
        if (self.active_tab_display_list) |display_list| {
            self.applyCompositedUpdateToList(display_list, update);
        }
    }

    /// Recursively search display list and update matching blend items
    fn applyCompositedUpdateToList(self: *Browser, items: []DisplayItem, update: Tab.CompositedUpdate) void {
        for (items) |*item| {
            switch (item.*) {
                .blend => |*blend| {
                    if (blend.node == update.node) {
                        blend.opacity = update.opacity;
                        // Also update the corresponding composited layer
                        self.updateLayerOpacity(update.node, update.opacity);
                    }
                    // Recurse into children
                    self.applyCompositedUpdateToList(blend.children, update);
                },
                else => {},
            }
        }
    }

    /// Update opacity on composited layer matching the node
    fn updateLayerOpacity(self: *Browser, node: *anyopaque, opacity: f64) void {
        for (self.composited_layers.items) |*layer| {
            if (layer.node == node) {
                layer.opacity = opacity;
                return;
            }
        }
    }

    fn updateActiveTabUrl(self: *Browser, url: *Url) void {
        var buffer: [1024]u8 = undefined;
        const url_str = url.toString(&buffer) catch |err| {
            std.log.warn("Failed to format URL for chrome: {}", .{err});
            return;
        };

        if (self.active_tab_url) |cached| {
            if (std.mem.eql(u8, cached, url_str)) {
                return;
            }
            self.allocator.free(cached);
        }

        const copy = self.allocator.alloc(u8, url_str.len) catch |err| {
            std.log.warn("Failed to allocate URL copy: {}", .{err});
            self.active_tab_url = null;
            return;
        };
        std.mem.copyForwards(u8, copy, url_str);
        self.active_tab_url = copy;
    }

    fn clearActiveTabUrl(self: *Browser) void {
        if (self.active_tab_url) |old| {
            self.allocator.free(old);
        }
        self.active_tab_url = null;
    }

    // Draw the browser content (composite from pre-rastered surfaces)
    pub fn draw(self: *Browser) !void {
        // Skip drawing if window dimensions are invalid
        if (self.window_width <= 0 or self.window_height <= 0) {
            return;
        }

        // Recreate the context to avoid corruption issues
        self.context.deinit();
        self.context = z2d.Context.init(self.allocator, &self.root_surface);

        // Clear the SDL canvas to black
        try self.canvas.setColorRGB(0, 0, 0);
        try self.canvas.clear();

        // Clear the root surface to white (to test if texture is being drawn)
        const white_pixel = z2d.pixel.Pixel{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
        self.root_surface.paintPixel(white_pixel);

        // Draw chrome content (from pre-rastered chrome surface if available, otherwise draw directly)
        var chrome_cmds = try self.chrome.paint(self.allocator, self);
        defer chrome_cmds.deinit(self.allocator);
        for (chrome_cmds.items) |item| {
            try self.drawDisplayItemZ2d(item, 0);
        }

        // Draw tab content from the composited draw list (not the original display list)
        // This ensures blend items with dst_in are properly composited within layers
        // instead of being applied directly to the root surface (which would clear the background)
        for (self.tab_draw_list.items) |item| {
            try self.drawDisplayItemZ2d(item, self.active_tab_scroll - self.chrome.bottom);
        }

        try self.drawScrollbarZ2d();

        // Copy composited root surface to SDL for display
        try self.copyZ2dToSDL();
    }

    // Copy z2d surface to SDL for display (surface handoff)
    // Uses persistent cached texture to avoid per-frame texture churn
    fn copyZ2dToSDL(self: *Browser) !void {
        const texture = self.cached_texture orelse return error.NoCachedTexture;

        // Get the pixel data from the z2d surface
        const surface_width = self.root_surface.getWidth();
        const surface_height = self.root_surface.getHeight();

        // Get the underlying pixel buffer from z2d surface
        const pixel_data = switch (self.root_surface) {
            .image_surface_rgba => |*img_surface| img_surface.buf,
            else => return error.UnsupportedSurfaceType,
        };

        // Lock the cached texture to get writable pixel buffer
        var pixel_data_result = try texture.lock(null);

        // Get the pixel pointer and stride
        const pixels: [*]u8 = pixel_data_result.pixels;
        const stride = pixel_data_result.stride;

        // Copy pixels from z2d to SDL texture
        // Both use ABGR8888 format (z2d RGBA has r at lowest address)
        const bytes_per_pixel = 4;
        for (0..@intCast(surface_height)) |y| {
            const src_row_start = y * @as(usize, @intCast(surface_width));
            const dst_row_start = y * stride;

            for (0..@intCast(surface_width)) |x| {
                const src_idx = src_row_start + x;
                const dst_idx = dst_row_start + x * bytes_per_pixel;

                const src_pixel = pixel_data[src_idx];

                // Direct copy - z2d RGBA matches SDL ABGR8888 layout
                pixels[dst_idx + 0] = src_pixel.r;
                pixels[dst_idx + 1] = src_pixel.g;
                pixels[dst_idx + 2] = src_pixel.b;
                pixels[dst_idx + 3] = src_pixel.a;
            }
        }

        // MUST unlock before copying to canvas
        pixel_data_result.release();

        // Copy texture to renderer (texture persists for next frame)
        try self.canvas.copy(texture, null, null);
    }

    // Draw a display item using the browser's context
    fn drawDisplayItemZ2d(self: *Browser, item: DisplayItem, scroll_offset: i32) !void {
        try self.drawDisplayItemZ2dContext(&self.context, item, scroll_offset);
    }

    // Draw a display item using a specific z2d context
    fn drawDisplayItemZ2dContext(self: *Browser, context: *z2d.Context, item: DisplayItem, scroll_offset: i32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                // Render glyph using pixel data stored in the Glyph struct
                if (glyph_item.glyph.pixels) |pixels| {
                    const glyph_y = glyph_item.y - scroll_offset;
                    const glyph_x = glyph_item.x;
                    const w: usize = @intCast(glyph_item.glyph.w);
                    const h: usize = @intCast(glyph_item.glyph.h);

                    // Draw each pixel of the glyph
                    for (0..h) |py| {
                        const dest_y = glyph_y + @as(i32, @intCast(py));
                        if (dest_y < 0 or dest_y >= self.window_height) continue;

                        for (0..w) |px| {
                            const dest_x = glyph_x + @as(i32, @intCast(px));
                            if (dest_x < 0 or dest_x >= self.window_width) continue;

                            const idx = (py * w + px) * 4;
                            // Glyph pixels are white with alpha - blend with the glyph color
                            const alpha = pixels[idx + 3];
                            if (alpha > 0) {
                                // Blend glyph alpha with the requested color
                                const final_alpha = @as(u8, @intFromFloat(@as(f64, @floatFromInt(alpha)) * @as(f64, @floatFromInt(glyph_item.color.a)) / 255.0));
                                if (final_alpha > 0) {
                                    context.resetPath();
                                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                                        .r = glyph_item.color.r,
                                        .g = glyph_item.color.g,
                                        .b = glyph_item.color.b,
                                        .a = final_alpha,
                                    } } } });
                                    context.moveTo(@floatFromInt(dest_x), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y + 1)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x), @floatFromInt(dest_y + 1)) catch continue;
                                    context.closePath() catch continue;
                                    context.fill() catch continue;
                                }
                            }
                        }
                    }
                }
            },
            .rect => |rect_item| {
                const top = rect_item.y1 - scroll_offset;
                const bottom = rect_item.y2 - scroll_offset;
                const width = rect_item.x2 - rect_item.x1;
                const height = bottom - top;

                // Only draw if rect has valid dimensions and is visible
                if (width > 1 and height > 1 and bottom > 0 and top < self.window_height) {
                    // Reset path first to ensure clean state
                    context.resetPath();

                    // Set source color for filling
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });

                    // Create rectangle path
                    try context.moveTo(@floatFromInt(rect_item.x1), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(rect_item.x2), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(rect_item.x2), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(rect_item.x1), @floatFromInt(bottom));
                    try context.closePath();

                    // Fill and reset path after
                    try context.fill();
                    context.resetPath();
                }
            },
            .rounded_rect => |rounded_item| {
                const top = rounded_item.y1 - scroll_offset;
                const bottom = rounded_item.y2 - scroll_offset;
                if (bottom > 0 and top < self.window_height) {
                    const width = rounded_item.x2 - rounded_item.x1;
                    const height = bottom - top;
                    if (width > 1 and height > 1) {
                        context.resetPath();
                        // Set source color for filling
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rounded_item.color.toZ2dRgba() } } });

                        // Clamp radius to not exceed half the width or height
                        const max_radius = @min(@as(f64, @floatFromInt(width)) / 2.0, @as(f64, @floatFromInt(height)) / 2.0);
                        const radius = @min(rounded_item.radius, max_radius);

                        const x1 = @as(f64, @floatFromInt(rounded_item.x1));
                        const y1 = @as(f64, @floatFromInt(top));
                        const x2 = x1 + @as(f64, @floatFromInt(width));
                        const y2 = y1 + @as(f64, @floatFromInt(height));

                        // Only draw rounded corners if radius is meaningful
                        if (radius > 0.5) {
                            // Create rounded rectangle path using arcs
                            // Top-left corner
                            try context.moveTo(x1 + radius, y1);
                            try context.arc(x1 + radius, y1 + radius, radius, -std.math.pi, -std.math.pi / 2.0);

                            // Top-right corner
                            try context.arc(x2 - radius, y1 + radius, radius, -std.math.pi / 2.0, 0);

                            // Bottom-right corner
                            try context.arc(x2 - radius, y2 - radius, radius, 0, std.math.pi / 2.0);

                            // Bottom-left corner
                            try context.arc(x1 + radius, y2 - radius, radius, std.math.pi / 2.0, std.math.pi);

                            try context.closePath();
                            try context.fill();
                        } else {
                            // Draw regular rectangle if radius is too small
                            try context.moveTo(x1, y1);
                            try context.lineTo(x2, y1);
                            try context.lineTo(x2, y2);
                            try context.lineTo(x1, y2);
                            try context.closePath();
                            try context.fill();
                        }
                    }
                }
            },
            .line => |line_item| {
                const y1 = line_item.y1 - scroll_offset;
                const y2 = line_item.y2 - scroll_offset;

                // Only draw if line has non-zero length
                const dx = line_item.x2 - line_item.x1;
                const dy = y2 - y1;
                if (dx != 0 or dy != 0) {
                    // Set source color and line width
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                    context.setLineWidth(@floatFromInt(line_item.thickness));

                    // Draw the line
                    try context.moveTo(@floatFromInt(line_item.x1), @floatFromInt(y1));
                    try context.lineTo(@floatFromInt(line_item.x2), @floatFromInt(y2));
                    try context.stroke();
                    context.resetPath();
                }
            },
            .outline => |outline_item| {
                const r = outline_item.rect;
                const top = r.top - scroll_offset;
                const bottom = r.bottom - scroll_offset;

                const width = r.right - r.left;
                const height = bottom - top;

                // Only draw if outline has valid dimensions
                if (width > 1 and height > 1) {
                    // Set source color and line width (assuming 1 pixel outline)
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                    context.setLineWidth(1.0);

                    // Draw rectangle outline
                    try context.moveTo(@floatFromInt(r.left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(r.right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(r.right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(r.left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.stroke();
                }
            },
            .blend => |blend_item| {
                // For blend operations, only create a layer if we have opacity < 1 or a blend mode
                const should_save_layer = blend_item.opacity < 1.0 or blend_item.blend_mode != null;

                if (should_save_layer) {
                    // Save current operator for restoration
                    const original_operator = context.getOperator();

                    // Set blend mode if specified
                    if (blend_item.blend_mode) |mode| {
                        const blend_operator = self.parseBlendMode(mode);
                        context.setOperator(blend_operator);
                    }

                    // Draw children with opacity applied to their colors (since z2d doesn't have layered alpha)
                    for (blend_item.children) |child_item| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child_item;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContext(context, modified_item, scroll_offset);
                        } else {
                            try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset);
                        }
                    }

                    // Restore original operator
                    context.setOperator(original_operator);
                } else {
                    // No layer needed, just draw children directly
                    for (blend_item.children) |child_item| {
                        try self.drawDisplayItemZ2dContext(context, child_item, scroll_offset);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                // Ensure the layer is rasterized
                try dcl.layer.raster(self.allocator, self);

                if (dcl.layer.surface) |*layer_surface| {
                    // Draw the layer surface at its position with opacity
                    const layer_y = dcl.layer.bounds.top - scroll_offset;

                    // Get the pixel data from both surfaces
                    const layer_pixels = switch (layer_surface.*) {
                        .image_surface_rgba => |*img_surface| img_surface.buf,
                        else => return error.UnsupportedSurfaceType,
                    };

                    // Get the root surface pixel buffer for direct writing
                    const root_pixels = switch (self.root_surface) {
                        .image_surface_rgba => |*img_surface| img_surface.buf,
                        else => return error.UnsupportedSurfaceType,
                    };
                    const root_width: usize = @intCast(self.root_surface.getWidth());

                    // Composite the layer onto the root surface using direct pixel writes
                    const layer_width: usize = @intCast(layer_surface.getWidth());
                    const layer_height: usize = @intCast(layer_surface.getHeight());

                    // DEBUG: Count non-zero alpha pixels and find lightblue pixels
                    var nonzero_count: usize = 0;
                    var lightblue_count: usize = 0;
                    var lightgreen_count: usize = 0;
                    for (layer_pixels) |pixel| {
                        if (pixel.a > 0) {
                            nonzero_count += 1;
                            // lightblue = (173,216,230), lightgreen = (144,238,144)
                            if (pixel.r >= 170 and pixel.r <= 176 and pixel.g >= 213 and pixel.g <= 219 and pixel.b >= 227 and pixel.b <= 233) {
                                lightblue_count += 1;
                            }
                            if (pixel.r >= 141 and pixel.r <= 147 and pixel.g >= 235 and pixel.g <= 241 and pixel.b >= 141 and pixel.b <= 147) {
                                lightgreen_count += 1;
                            }
                        }
                    }
                    std.debug.print("DEBUG compositing layer: bounds({},{}-{},{}) size {}x{} scroll={} layer_y={} opacity={d:.2} nonzero={} lightblue={} lightgreen={}\n", .{
                        dcl.layer.bounds.left, dcl.layer.bounds.top, dcl.layer.bounds.right, dcl.layer.bounds.bottom,
                        layer_width, layer_height, scroll_offset, layer_y, dcl.layer.opacity,
                        nonzero_count, lightblue_count, lightgreen_count,
                    });

                    var composited_lightblue: usize = 0;
                    var composited_lightgreen: usize = 0;
                    var first_lightblue_printed = false;

                    for (0..layer_height) |row| {
                        const y: i32 = @intCast(row);
                        const dest_y = layer_y + y;
                        if (dest_y < 0 or dest_y >= self.window_height) continue;

                        for (0..layer_width) |col| {
                            const x: i32 = @intCast(col);
                            const dest_x = dcl.layer.bounds.left + x;
                            if (dest_x < 0 or dest_x >= self.window_width) continue;

                            const pixel_idx = row * layer_width + col;
                            const pixel = layer_pixels[pixel_idx];

                            // Apply layer opacity
                            const alpha: f64 = @as(f64, @floatFromInt(pixel.a)) / 255.0 * dcl.layer.opacity;
                            if (alpha > 0.01) {
                                // Track lightblue and lightgreen pixels being composited
                                const is_lightblue = pixel.r >= 170 and pixel.r <= 176 and pixel.g >= 213 and pixel.g <= 219 and pixel.b >= 227 and pixel.b <= 233;
                                if (is_lightblue) {
                                    composited_lightblue += 1;
                                    if (!first_lightblue_printed) {
                                        std.debug.print("DEBUG first lightblue pixel: local({},{}) dest({},{}) color=({},{},{},{}) alpha={d:.2}\n", .{
                                            col, row, dest_x, dest_y, pixel.r, pixel.g, pixel.b, pixel.a, alpha,
                                        });
                                        first_lightblue_printed = true;
                                    }
                                }
                                if (pixel.r >= 141 and pixel.r <= 147 and pixel.g >= 235 and pixel.g <= 241 and pixel.b >= 141 and pixel.b <= 147) {
                                    composited_lightgreen += 1;
                                }

                                // Direct pixel write to root surface with alpha blending
                                const dest_x_usize: usize = @intCast(dest_x);
                                const dest_y_usize: usize = @intCast(dest_y);
                                const dest_idx = dest_y_usize * root_width + dest_x_usize;

                                // Get the existing pixel from root surface
                                const dst = root_pixels[dest_idx];

                                // Source pixel with layer opacity applied
                                const src_alpha: f64 = alpha;
                                const src_r: f64 = @floatFromInt(pixel.r);
                                const src_g: f64 = @floatFromInt(pixel.g);
                                const src_b: f64 = @floatFromInt(pixel.b);

                                // Destination pixel
                                const dst_alpha: f64 = @as(f64, @floatFromInt(dst.a)) / 255.0;
                                const dst_r: f64 = @floatFromInt(dst.r);
                                const dst_g: f64 = @floatFromInt(dst.g);
                                const dst_b: f64 = @floatFromInt(dst.b);

                                // Standard "over" compositing: src over dst
                                // out_alpha = src_alpha + dst_alpha * (1 - src_alpha)
                                // out_color = (src_color * src_alpha + dst_color * dst_alpha * (1 - src_alpha)) / out_alpha
                                const out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);
                                if (out_alpha > 0.001) {
                                    const out_r = (src_r * src_alpha + dst_r * dst_alpha * (1.0 - src_alpha)) / out_alpha;
                                    const out_g = (src_g * src_alpha + dst_g * dst_alpha * (1.0 - src_alpha)) / out_alpha;
                                    const out_b = (src_b * src_alpha + dst_b * dst_alpha * (1.0 - src_alpha)) / out_alpha;

                                    root_pixels[dest_idx] = .{
                                        .r = @intFromFloat(@min(255.0, @max(0.0, out_r))),
                                        .g = @intFromFloat(@min(255.0, @max(0.0, out_g))),
                                        .b = @intFromFloat(@min(255.0, @max(0.0, out_b))),
                                        .a = @intFromFloat(@min(255.0, out_alpha * 255.0)),
                                    };
                                }
                            }
                        }
                    }
                    std.debug.print("DEBUG composited pixels: lightblue={} lightgreen={}\n", .{ composited_lightblue, composited_lightgreen });

                    // Draw debug border if enabled
                    if (self.debug_layer_borders) {
                        const border_y = layer_y;
                        const border_x = dcl.layer.bounds.left;
                        const border_w = dcl.layer.bounds.width();
                        const border_h = dcl.layer.bounds.height();

                        // Use a bright color (magenta) for visibility
                        context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 0, .b = 255, .a = 255 } } } });
                        context.resetPath();

                        // Draw top border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + 2));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + 2));
                        try context.closePath();
                        try context.fill();

                        // Draw bottom border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h - 2));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw left border
                        try context.moveTo(@floatFromInt(border_x), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + 2), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();

                        // Draw right border
                        try context.moveTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y));
                        try context.lineTo(@floatFromInt(border_x + border_w), @floatFromInt(border_y + border_h));
                        try context.lineTo(@floatFromInt(border_x + border_w - 2), @floatFromInt(border_y + border_h));
                        try context.closePath();
                        try context.fill();
                    }
                }
            },
            .transform => |t| {
                // Apply translation by adjusting scroll offset for children
                const new_scroll_offset = scroll_offset - t.translate_y;
                for (t.children) |child| {
                    // Recursively draw children with adjusted offset
                    // For x translation, we need to handle it differently since scroll is y-only
                    try self.drawDisplayItemZ2dContextWithTransform(context, child, new_scroll_offset, t.translate_x);
                }
            },
        }
    }

    // Draw a display item with both scroll offset and x translation
    fn drawDisplayItemZ2dContextWithTransform(self: *Browser, context: *z2d.Context, item: DisplayItem, scroll_offset: i32, x_offset: i32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                // Render glyph with x offset applied
                if (glyph_item.glyph.pixels) |pixels| {
                    const glyph_y = glyph_item.y - scroll_offset;
                    const glyph_x = glyph_item.x + x_offset;
                    const w: usize = @intCast(glyph_item.glyph.w);
                    const h: usize = @intCast(glyph_item.glyph.h);

                    for (0..h) |py| {
                        const dest_y = glyph_y + @as(i32, @intCast(py));
                        if (dest_y < 0 or dest_y >= self.window_height) continue;

                        for (0..w) |px| {
                            const dest_x = glyph_x + @as(i32, @intCast(px));
                            if (dest_x < 0 or dest_x >= self.window_width) continue;

                            const idx = (py * w + px) * 4;
                            const alpha = pixels[idx + 3];
                            if (alpha > 0) {
                                const final_alpha = @as(u8, @intFromFloat(@as(f64, @floatFromInt(alpha)) * @as(f64, @floatFromInt(glyph_item.color.a)) / 255.0));
                                if (final_alpha > 0) {
                                    context.resetPath();
                                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                                        .r = glyph_item.color.r,
                                        .g = glyph_item.color.g,
                                        .b = glyph_item.color.b,
                                        .a = final_alpha,
                                    } } } });
                                    context.moveTo(@floatFromInt(dest_x), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y + 1)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x), @floatFromInt(dest_y + 1)) catch continue;
                                    context.closePath() catch continue;
                                    context.fill() catch continue;
                                }
                            }
                        }
                    }
                }
            },
            .rect => |rect_item| {
                const top = rect_item.y1 - scroll_offset;
                const bottom = rect_item.y2 - scroll_offset;
                const left = rect_item.x1 + x_offset;
                const right = rect_item.x2 + x_offset;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1 and bottom > 0 and top < self.window_height) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                        .r = rect_item.color.r,
                        .g = rect_item.color.g,
                        .b = rect_item.color.b,
                        .a = rect_item.color.a,
                    } } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                }
            },
            .rounded_rect => |rr| {
                const top = rr.y1 - scroll_offset;
                const bottom = rr.y2 - scroll_offset;
                const left = rr.x1 + x_offset;
                const right = rr.x2 + x_offset;
                if (bottom > 0 and top < self.window_height) {
                    // Draw as a regular rect for simplicity in transformed context
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                        .r = rr.color.r,
                        .g = rr.color.g,
                        .b = rr.color.b,
                        .a = rr.color.a,
                    } } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                }
            },
            .line => |l| {
                const y1 = l.y1 - scroll_offset;
                const y2 = l.y2 - scroll_offset;
                const x1 = l.x1 + x_offset;
                const x2 = l.x2 + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = l.color.r,
                    .g = l.color.g,
                    .b = l.color.b,
                    .a = l.color.a,
                } } } });
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
            },
            .outline => |o| {
                const top = o.rect.top - scroll_offset;
                const bottom = o.rect.bottom - scroll_offset;
                const left = o.rect.left + x_offset;
                const right = o.rect.right + x_offset;
                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                    .r = o.color.r,
                    .g = o.color.g,
                    .b = o.color.b,
                    .a = o.color.a,
                } } } });
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
            },
            .blend => |blend_item| {
                // For blends, apply opacity and recurse into children with the transform applied
                const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;

                if (should_apply_opacity) {
                    const original_operator = context.getOperator();
                    if (blend_item.blend_mode) |mode| {
                        context.setOperator(self.parseBlendMode(mode));
                    }

                    for (blend_item.children) |child| {
                        if (blend_item.opacity < 1.0) {
                            var modified_item = child;
                            modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                            try self.drawDisplayItemZ2dContextWithTransform(context, modified_item, scroll_offset, x_offset);
                        } else {
                            try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset);
                        }
                    }

                    context.setOperator(original_operator);
                } else {
                    for (blend_item.children) |child| {
                        try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset, x_offset);
                    }
                }
            },
            .draw_composited_layer => |dcl| {
                // For composited layers, draw at transformed position
                try dcl.layer.raster(self.allocator, self);
                if (dcl.layer.surface) |*layer_surface| {
                    const layer_y = dcl.layer.bounds.top - scroll_offset;
                    const layer_x = dcl.layer.bounds.left + x_offset;
                    const layer_pixels = switch (layer_surface.*) {
                        .image_surface_rgba => |*img| img.buf,
                        else => return error.UnsupportedSurfaceType,
                    };
                    const layer_width: usize = @intCast(layer_surface.getWidth());
                    const layer_height: usize = @intCast(layer_surface.getHeight());
                    for (0..layer_height) |row| {
                        const y: i32 = @intCast(row);
                        const dest_y = layer_y + y;
                        if (dest_y < 0 or dest_y >= self.window_height) continue;
                        for (0..layer_width) |col| {
                            const x: i32 = @intCast(col);
                            const dest_x = layer_x + x;
                            if (dest_x < 0 or dest_x >= self.window_width) continue;
                            const pixel = layer_pixels[row * layer_width + col];
                            const alpha: f64 = @as(f64, @floatFromInt(pixel.a)) / 255.0 * dcl.layer.opacity;
                            if (alpha > 0.01) {
                                context.resetPath();
                                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                                    .r = pixel.r,
                                    .g = pixel.g,
                                    .b = pixel.b,
                                    .a = @intFromFloat(alpha * 255.0),
                                } } } });
                                try context.moveTo(@floatFromInt(dest_x), @floatFromInt(dest_y));
                                try context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y));
                                try context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y + 1));
                                try context.lineTo(@floatFromInt(dest_x), @floatFromInt(dest_y + 1));
                                try context.closePath();
                                try context.fill();
                            }
                        }
                    }
                }
            },
            .transform => |t| {
                // Nested transform: combine offsets
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextWithTransform(context, child, scroll_offset - t.translate_y, x_offset + t.translate_x);
                }
            },
        }
    }

    /// Draw a display item for a composited layer, mapping from absolute to local coordinates
    /// This function offsets all coordinates by the layer's origin to draw in layer-local space
    fn drawDisplayItemZ2dContextForLayer(self: *Browser, context: *z2d.Context, item: DisplayItem, layer_x: i32, layer_y: i32) !void {
        switch (item) {
            .glyph => |glyph_item| {
                // Render glyph in layer-local coordinates
                if (glyph_item.glyph.pixels) |pixels| {
                    const glyph_x = glyph_item.x - layer_x;
                    const glyph_y = glyph_item.y - layer_y;
                    const w: usize = @intCast(glyph_item.glyph.w);
                    const h: usize = @intCast(glyph_item.glyph.h);

                    for (0..h) |py| {
                        const dest_y = glyph_y + @as(i32, @intCast(py));

                        for (0..w) |px| {
                            const dest_x = glyph_x + @as(i32, @intCast(px));

                            const idx = (py * w + px) * 4;
                            const alpha = pixels[idx + 3];
                            if (alpha > 0) {
                                const final_alpha = @as(u8, @intFromFloat(@as(f64, @floatFromInt(alpha)) * @as(f64, @floatFromInt(glyph_item.color.a)) / 255.0));
                                if (final_alpha > 0) {
                                    context.resetPath();
                                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{
                                        .r = glyph_item.color.r,
                                        .g = glyph_item.color.g,
                                        .b = glyph_item.color.b,
                                        .a = final_alpha,
                                    } } } });
                                    context.moveTo(@floatFromInt(dest_x), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x + 1), @floatFromInt(dest_y + 1)) catch continue;
                                    context.lineTo(@floatFromInt(dest_x), @floatFromInt(dest_y + 1)) catch continue;
                                    context.closePath() catch continue;
                                    context.fill() catch continue;
                                }
                            }
                        }
                    }
                }
            },
            .rect => |rect_item| {
                // Map absolute coordinates to layer-local space
                const left = rect_item.x1 - layer_x;
                const right = rect_item.x2 - layer_x;
                const top = rect_item.y1 - layer_y;
                const bottom = rect_item.y2 - layer_y;
                const width = right - left;
                const height = bottom - top;

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rect_item.color.toZ2dRgba() } } });
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .rounded_rect => |rr| {
                const left = rr.x1 - layer_x;
                const right = rr.x2 - layer_x;
                const top = rr.y1 - layer_y;
                const bottom = rr.y2 - layer_y;
                const width = right - left;
                const height = bottom - top;

                std.debug.print("DEBUG rounded_rect: abs({},{}-{},{}) layer_offset({},{}) local({},{}-{},{}) size {}x{} color=({},{},{},{})\n", .{
                    rr.x1, rr.y1, rr.x2, rr.y2,
                    layer_x, layer_y,
                    left, top, right, bottom,
                    width, height,
                    rr.color.r, rr.color.g, rr.color.b, rr.color.a,
                });

                if (width > 1 and height > 1) {
                    context.resetPath();
                    context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = rr.color.toZ2dRgba() } } });
                    // Draw as regular rect (rounded rect requires more complex path)
                    try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                    try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                    try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                    try context.closePath();
                    try context.fill();
                    context.resetPath();
                }
            },
            .line => |line_item| {
                const x1 = line_item.x1 - layer_x;
                const x2 = line_item.x2 - layer_x;
                const y1 = line_item.y1 - layer_y;
                const y2 = line_item.y2 - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = line_item.color.toZ2dRgba() } } });
                try context.moveTo(@floatFromInt(x1), @floatFromInt(y1));
                try context.lineTo(@floatFromInt(x2), @floatFromInt(y2));
                try context.stroke();
                context.resetPath();
            },
            .outline => |outline_item| {
                const left = outline_item.rect.left - layer_x;
                const right = outline_item.rect.right - layer_x;
                const top = outline_item.rect.top - layer_y;
                const bottom = outline_item.rect.bottom - layer_y;

                context.resetPath();
                context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = outline_item.color.toZ2dRgba() } } });
                try context.moveTo(@floatFromInt(left), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(top));
                try context.lineTo(@floatFromInt(right), @floatFromInt(bottom));
                try context.lineTo(@floatFromInt(left), @floatFromInt(bottom));
                try context.closePath();
                try context.stroke();
                context.resetPath();
            },
            .blend => |blend_item| {
                // Check if this is a dst_in clipping blend
                const is_dst_in_clip = if (blend_item.blend_mode) |mode|
                    std.mem.eql(u8, mode, "dst_in")
                else
                    false;

                if (is_dst_in_clip) {
                    // TEMPORARILY DISABLED: dst_in clipping to debug lightblue rect issue
                    // For dst_in clipping, don't use the unbounded operator.
                    // Instead, apply clip mask manually after content is drawn.
                    // The mask shape is in blend_item.children[0]
                    std.debug.print("DEBUG dst_in clip: SKIPPED layer_offset({},{}) children={}\n", .{ layer_x, layer_y, blend_item.children.len });
                    // if (blend_item.children.len > 0) {
                    //     try self.applyClipMaskForLayer(context, blend_item.children[0], layer_x, layer_y);
                    // }
                } else {
                    // Apply opacity and recursively draw children in layer space
                    const should_apply_opacity = blend_item.opacity < 1.0 or blend_item.blend_mode != null;

                    std.debug.print("DEBUG blend: opacity={d:.2} blend_mode={s} should_apply={} children={}\n", .{
                        blend_item.opacity,
                        if (blend_item.blend_mode) |m| m else "null",
                        should_apply_opacity,
                        blend_item.children.len,
                    });

                    if (should_apply_opacity) {
                        const original_operator = context.getOperator();
                        if (blend_item.blend_mode) |mode| {
                            context.setOperator(self.parseBlendMode(mode));
                        }

                        for (blend_item.children, 0..) |child, i| {
                            std.debug.print("DEBUG blend child[{}]: type={s}\n", .{ i, @tagName(child) });
                            if (blend_item.opacity < 1.0) {
                                var modified_item = child;
                                modified_item = self.applyOpacityToDisplayItem(modified_item, blend_item.opacity);
                                try self.drawDisplayItemZ2dContextForLayer(context, modified_item, layer_x, layer_y);
                            } else {
                                try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y);
                            }
                        }

                        context.setOperator(original_operator);
                    } else {
                        for (blend_item.children) |child| {
                            try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x, layer_y);
                        }
                    }
                }
            },
            .draw_composited_layer => {
                // Nested composited layers shouldn't appear in flattened content
                // They would have been handled by the compositing pass
            },
            .transform => |t| {
                // Apply transform offsets to the layer coordinates
                std.debug.print("DEBUG transform: translate({},{}) layer_offset({},{}) -> ({},{})\n", .{
                    t.translate_x, t.translate_y, layer_x, layer_y,
                    layer_x - t.translate_x, layer_y - t.translate_y,
                });
                for (t.children) |child| {
                    try self.drawDisplayItemZ2dContextForLayer(context, child, layer_x - t.translate_x, layer_y - t.translate_y);
                }
            },
        }
    }

    /// Apply a clip mask by clearing pixels outside the mask shape
    /// This implements dst_in clipping by manually setting outside pixels to transparent
    /// IMPORTANT: Only clears pixels WITHIN the mask's bounding box that are outside the shape
    /// (e.g., corner pixels for rounded rects). Does NOT clear pixels outside the bounding box
    /// to avoid affecting other content in the same layer.
    fn applyClipMaskForLayer(self: *Browser, context: *z2d.Context, mask_item: DisplayItem, layer_x: i32, layer_y: i32) !void {
        _ = self;

        switch (mask_item) {
            .rounded_rect => |rr| {
                // Get surface from context - we need direct pixel access
                const surface = context.surface;
                const surface_width = surface.getWidth();
                const surface_height = surface.getHeight();

                // Map mask coordinates to layer-local space
                const mask_left = rr.x1 - layer_x;
                const mask_right = rr.x2 - layer_x;
                const mask_top = rr.y1 - layer_y;
                const mask_bottom = rr.y2 - layer_y;
                const radius = rr.radius;

                // Get pixel buffer
                const pixel_buf = switch (surface.*) {
                    .image_surface_rgba => |*img| img.buf,
                    else => return,
                };

                // Only iterate over pixels WITHIN the mask's bounding box
                // Clear corner pixels that are outside the rounded shape
                const start_y: usize = @intCast(@max(0, mask_top));
                const end_y: usize = @intCast(@min(surface_height, @max(0, mask_bottom)));
                const start_x: usize = @intCast(@max(0, mask_left));
                const end_x: usize = @intCast(@min(surface_width, @max(0, mask_right)));

                for (start_y..end_y) |y_idx| {
                    const y: i32 = @intCast(y_idx);
                    for (start_x..end_x) |x_idx| {
                        const x: i32 = @intCast(x_idx);

                        // Check if point is outside the rounded rect (in the corners)
                        if (!isPointInRoundedRect(x, y, mask_left, mask_top, mask_right, mask_bottom, radius)) {
                            // Clear this corner pixel to transparent
                            const idx = y_idx * @as(usize, @intCast(surface_width)) + x_idx;
                            pixel_buf[idx] = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                        }
                    }
                }
            },
            .rect => |_| {
                // For regular rects, nothing to clip - the content already fills the rect
                // No corner pixels to clear
            },
            else => {
                // Other shapes not supported for clipping yet
            },
        }
    }

    /// Check if a point is inside a rounded rectangle
    fn isPointInRoundedRect(x: i32, y: i32, left: i32, top: i32, right: i32, bottom: i32, radius: f64) bool {
        // First check if outside the bounding rect
        if (x < left or x >= right or y < top or y >= bottom) {
            return false;
        }

        // Check corners
        const r: i32 = @intFromFloat(radius);
        const width = right - left;
        const height = bottom - top;

        // If radius is larger than half the width/height, clamp it
        const effective_r = @min(r, @min(@divTrunc(width, 2), @divTrunc(height, 2)));

        // Check if in corner regions
        const in_left_region = x < left + effective_r;
        const in_right_region = x >= right - effective_r;
        const in_top_region = y < top + effective_r;
        const in_bottom_region = y >= bottom - effective_r;

        // Check each corner
        if (in_left_region and in_top_region) {
            // Top-left corner
            const cx = left + effective_r;
            const cy = top + effective_r;
            const dx = x - cx;
            const dy = y - cy;
            return dx * dx + dy * dy <= effective_r * effective_r;
        }
        if (in_right_region and in_top_region) {
            // Top-right corner
            const cx = right - effective_r;
            const cy = top + effective_r;
            const dx = x - cx;
            const dy = y - cy;
            return dx * dx + dy * dy <= effective_r * effective_r;
        }
        if (in_left_region and in_bottom_region) {
            // Bottom-left corner
            const cx = left + effective_r;
            const cy = bottom - effective_r;
            const dx = x - cx;
            const dy = y - cy;
            return dx * dx + dy * dy <= effective_r * effective_r;
        }
        if (in_right_region and in_bottom_region) {
            // Bottom-right corner
            const cx = right - effective_r;
            const cy = bottom - effective_r;
            const dx = x - cx;
            const dy = y - cy;
            return dx * dx + dy * dy <= effective_r * effective_r;
        }

        // Not in a corner region, so inside the rounded rect
        return true;
    }

    // Parse CSS blend mode string to z2d compositing operator
    fn parseBlendMode(self: *Browser, blend_mode_str: []const u8) compositor.Operator {
        _ = self;
        if (std.mem.eql(u8, blend_mode_str, "multiply")) {
            return .multiply;
        } else if (std.mem.eql(u8, blend_mode_str, "screen")) {
            return .screen;
        } else if (std.mem.eql(u8, blend_mode_str, "overlay")) {
            return .overlay;
        } else if (std.mem.eql(u8, blend_mode_str, "darken")) {
            return .darken;
        } else if (std.mem.eql(u8, blend_mode_str, "lighten")) {
            return .lighten;
        } else if (std.mem.eql(u8, blend_mode_str, "color-dodge")) {
            return .color_dodge;
        } else if (std.mem.eql(u8, blend_mode_str, "color-burn")) {
            return .color_burn;
        } else if (std.mem.eql(u8, blend_mode_str, "hard-light")) {
            return .hard_light;
        } else if (std.mem.eql(u8, blend_mode_str, "soft-light")) {
            return .soft_light;
        } else if (std.mem.eql(u8, blend_mode_str, "difference")) {
            return .difference;
        } else if (std.mem.eql(u8, blend_mode_str, "exclusion")) {
            return .exclusion;
        } else if (std.mem.eql(u8, blend_mode_str, "dst_in")) {
            return .dst_in;
        } else {
            // Default to src_over for unknown blend modes
            return .src_over;
        }
    }

    // Apply opacity to a display item's colors
    fn applyOpacityToDisplayItem(self: *Browser, item: DisplayItem, opacity: f64) DisplayItem {
        _ = self; // Used for context
        var result = item;

        switch (result) {
            .glyph => |*glyph_item| {
                glyph_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(glyph_item.color.a)) * opacity)));
            },
            .rect => |*rect_item| {
                rect_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(rect_item.color.a)) * opacity)));
            },
            .rounded_rect => |*rounded_item| {
                rounded_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(rounded_item.color.a)) * opacity)));
            },
            .line => |*line_item| {
                line_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(line_item.color.a)) * opacity)));
            },
            .outline => |*outline_item| {
                outline_item.color.a = @as(u8, @intFromFloat(@round(@as(f64, @floatFromInt(outline_item.color.a)) * opacity)));
            },
            .blend => |*blend_item| {
                // For nested blend operations with blend modes (like dst_in for clipping),
                // do NOT multiply opacity - the mask needs full opacity to work correctly
                if (blend_item.blend_mode == null) {
                    blend_item.opacity *= opacity;
                }
                // Blends with modes (clipping masks) keep their original opacity
            },
            .draw_composited_layer => {
                // Composited layers handle their own opacity
            },
            .transform => {
                // Transform items don't have direct color, opacity applied to children
            },
        }

        return result;
    }

    fn drawScrollbarZ2d(self: *Browser) !void {
        const tab_height = self.window_height - self.chrome.bottom;
        if (self.active_tab_height <= tab_height) {
            return;
        }

        const track_height = tab_height;
        const thumb_height: i32 = @intFromFloat(@as(f32, @floatFromInt(tab_height)) * (@as(f32, @floatFromInt(tab_height)) / @as(f32, @floatFromInt(self.active_tab_height))));
        const max_scroll = self.active_tab_height - tab_height;
        const thumb_y_offset: i32 = @intFromFloat(
            @as(f32, @floatFromInt(self.active_tab_scroll)) /
                @as(f32, @floatFromInt(max_scroll)) *
                (@as(f32, @floatFromInt(tab_height)) - @as(f32, @floatFromInt(thumb_height))),
        );

        // Draw scrollbar track (background) - start below chrome
        self.context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 200, .g = 200, .b = 200, .a = 255 } } } }); // Light gray
        const track_x = self.window_width - scrollbar_width;
        const track_y = self.chrome.bottom;
        try self.context.moveTo(@floatFromInt(track_x), @floatFromInt(track_y));
        try self.context.lineTo(@floatFromInt(track_x + scrollbar_width), @floatFromInt(track_y));
        try self.context.lineTo(@floatFromInt(track_x + scrollbar_width), @floatFromInt(track_y + track_height));
        try self.context.lineTo(@floatFromInt(track_x), @floatFromInt(track_y + track_height));
        try self.context.closePath();
        try self.context.fill();

        // Draw scrollbar thumb (movable part) - offset by chrome height
        self.context.setSource(.{ .opaque_pattern = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 102, .b = 204, .a = 255 } } } }); // Blue
        const thumb_x = self.window_width - scrollbar_width;
        const thumb_y = self.chrome.bottom + thumb_y_offset;
        try self.context.moveTo(@floatFromInt(thumb_x), @floatFromInt(thumb_y));
        try self.context.lineTo(@floatFromInt(thumb_x + scrollbar_width), @floatFromInt(thumb_y));
        try self.context.lineTo(@floatFromInt(thumb_x + scrollbar_width), @floatFromInt(thumb_y + thumb_height));
        try self.context.lineTo(@floatFromInt(thumb_x), @floatFromInt(thumb_y + thumb_height));
        try self.context.closePath();
        try self.context.fill();
    }

    // Ensure we clean up the document_layout in deinit
    pub fn deinit(self: *Browser) void {
        // Clean up z2d surfaces and context
        self.context.deinit();
        self.root_surface.deinit(self.allocator);
        self.chrome_surface.deinit(self.allocator);
        if (self.tab_surface) |*tab_surface| {
            tab_surface.deinit(self.allocator);
        }

        // Clean up cached SDL texture
        if (self.cached_texture) |tex| {
            tex.destroy();
        }

        // Close all connections
        self.http_client.deinit();

        // Free cache
        var cache = self.cache;
        cache.free();

        // Clean up chrome
        self.chrome.deinit();

        // Free cookie jar values and map storage
        var cookie_it = self.cookie_jar.iterator();
        while (cookie_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cookie_jar.deinit();

        // Clean up all tabs
        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);

        if (self.active_tab_display_list) |list| {
            DisplayItem.freeList(self.allocator, list);
        }
        if (self.active_tab_url) |url| {
            self.allocator.free(url);
        }

        // Clean up composited layers
        for (self.composited_layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.composited_layers.deinit(self.allocator);
        self.tab_draw_list.deinit(self.allocator);

        // Clean up default stylesheet rules
        for (self.default_style_sheet_rules) |*rule| {
            rule.deinit(self.allocator);
        }
        self.allocator.free(self.default_style_sheet_rules);

        // clean up layout
        self.layout_engine.deinit();

        // Clean up JavaScript engine
        self.js_engine.deinit(self.allocator);

        self.measure.finish();

        sdl2.quit();
    }
};

pub const CommitData = struct {
    url: ?*Url,
    display_list: ?[]DisplayItem,
    scroll: ?i32,
    height: i32,
    composited_updates: []const Tab.CompositedUpdate = &.{},
};

const LoadTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    url: ?*Url,
    payload: ?[]const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        url: *Url,
        payload: ?[]const u8,
    ) !*LoadTaskContext {
        const ctx = try allocator.create(LoadTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .url = url,
            .payload = payload,
        };
        return ctx;
    }

    fn destroy(self: *LoadTaskContext) void {
        self.consumePayload();
        if (self.url) |url_ptr| {
            url_ptr.*.free(self.allocator);
            self.allocator.destroy(url_ptr);
        }
        self.allocator.destroy(self);
    }

    fn consumePayload(self: *LoadTaskContext) void {
        if (self.payload) |payload| {
            self.allocator.free(payload);
            self.payload = null;
        }
    }

    fn run(self: *LoadTaskContext) !void {
        defer self.consumePayload();
        try self.browser.loadInTab(self.tab, self.url.?, self.payload);
        self.url = null;
    }

    fn toOpaque(self: *LoadTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *LoadTaskContext {
        const raw: *align(1) LoadTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try LoadTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        LoadTaskContext.fromOpaque(context).destroy();
    }
};

const TabClickTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    x: i32,
    y: i32,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        x: i32,
        y: i32,
    ) !*TabClickTaskContext {
        const ctx = try allocator.create(TabClickTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .x = x,
            .y = y,
        };
        return ctx;
    }

    fn destroy(self: *TabClickTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabClickTaskContext) !void {
        try self.tab.click(self.browser, self.x, self.y);
    }

    fn toOpaque(self: *TabClickTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabClickTaskContext {
        const raw: *align(1) TabClickTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabClickTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabClickTaskContext.fromOpaque(context).destroy();
    }
};

const TabKeypressTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    char: u8,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        char: u8,
    ) !*TabKeypressTaskContext {
        const ctx = try allocator.create(TabKeypressTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .char = char,
        };
        return ctx;
    }

    fn destroy(self: *TabKeypressTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabKeypressTaskContext) !void {
        try self.tab.keypress(self.browser, self.char);
    }

    fn toOpaque(self: *TabKeypressTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabKeypressTaskContext {
        const raw: *align(1) TabKeypressTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabKeypressTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabKeypressTaskContext.fromOpaque(context).destroy();
    }
};

const TabBackspaceTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
    ) !*TabBackspaceTaskContext {
        const ctx = try allocator.create(TabBackspaceTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
        };
        return ctx;
    }

    fn destroy(self: *TabBackspaceTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabBackspaceTaskContext) !void {
        try self.tab.backspace(self.browser);
    }

    fn toOpaque(self: *TabBackspaceTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabBackspaceTaskContext {
        const raw: *align(1) TabBackspaceTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabBackspaceTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabBackspaceTaskContext.fromOpaque(context).destroy();
    }
};

const TabCycleFocusTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
    ) !*TabCycleFocusTaskContext {
        const ctx = try allocator.create(TabCycleFocusTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
        };
        return ctx;
    }

    fn destroy(self: *TabCycleFocusTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabCycleFocusTaskContext) !void {
        try self.tab.cycleFocus(self.browser);
    }

    fn toOpaque(self: *TabCycleFocusTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabCycleFocusTaskContext {
        const raw: *align(1) TabCycleFocusTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabCycleFocusTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabCycleFocusTaskContext.fromOpaque(context).destroy();
    }
};

const TabClearFocusTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,

    pub fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
    ) !*TabClearFocusTaskContext {
        const ctx = try allocator.create(TabClearFocusTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
        };
        return ctx;
    }

    fn destroy(self: *TabClearFocusTaskContext) void {
        self.allocator.destroy(self);
    }

    fn run(self: *TabClearFocusTaskContext) !void {
        try self.tab.clearFocus(self.browser);
    }

    fn toOpaque(self: *TabClearFocusTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *TabClearFocusTaskContext {
        const raw: *align(1) TabClearFocusTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try TabClearFocusTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        TabClearFocusTaskContext.fromOpaque(context).destroy();
    }
};

const ScriptTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    js_context: *JsRenderContext,
    generation: u64,
    script_label: []const u8,
    script_url: Url,
    script_body: []const u8,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        generation: u64,
        script_label: []const u8,
        script_url: Url,
        script_body: []const u8,
    ) !*ScriptTaskContext {
        const ctx = try allocator.create(ScriptTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .js_context = js_context,
            .generation = generation,
            .script_label = script_label,
            .script_url = script_url,
            .script_body = script_body,
        };
        return ctx;
    }

    fn destroy(self: *ScriptTaskContext) void {
        self.script_url.free(self.allocator);
        self.allocator.free(self.script_body);
        self.allocator.free(self.script_label);
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *ScriptTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *ScriptTaskContext {
        const raw: *align(1) ScriptTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try ScriptTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        ScriptTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *ScriptTaskContext) !void {
        if (!self.js_context.matchesGeneration(self.generation)) {
            return;
        }

        std.log.info("========== Executing script ==========", .{});
        const trace_eval = self.browser.measure.begin("evaljs");
        defer if (trace_eval) self.browser.measure.end("evaljs");
        const result = self.browser.js_engine.evaluate(self.script_body) catch |err| {
            std.log.err("Script {s} crashed: {}", .{ self.script_label, err });
            return;
        };

        var result_buf: [4096]u8 = undefined;
        const result_str = js_module.formatValue(result, &result_buf) catch |err| {
            std.log.err("Failed to format script result: {}", .{err});
            return;
        };

        std.log.info("Script result: {s}", .{result_str});
        std.log.info("======================================", .{});

        if (!std.mem.eql(u8, result_str, "undefined")) {
            self.injectResult(result_str) catch |err| {
                std.log.warn("Failed to inject script result: {}", .{err});
            };
        }
    }

    fn injectResult(self: *ScriptTaskContext, result_str: []const u8) anyerror!void {
        if (self.tab.current_node == null) return;

        const allocator = self.browser.allocator;
        const result_text = try allocator.alloc(u8, result_str.len);
        @memcpy(result_text, result_str);

        var node_list = std.ArrayList(*Node).empty;
        defer node_list.deinit(allocator);

        try parser.treeToList(allocator, &self.tab.current_node.?, &node_list);

        var body_node: ?*Node = null;
        for (node_list.items) |node_ptr| {
            switch (node_ptr.*) {
                .element => |e| {
                    if (std.mem.eql(u8, e.tag, "body")) {
                        body_node = node_ptr;
                        break;
                    }
                },
                .text => {},
            }
        }

        if (body_node) |body_elem| {
            const text_node = Node{ .text = .{
                .text = result_text,
                .parent = body_elem,
            } };
            try body_elem.appendChild(allocator, text_node);
            try self.tab.dynamic_texts.append(allocator, result_text);
            parser.fixParentPointers(&self.tab.current_node.?, null);
            try self.tab.render(self.browser);
        } else {
            allocator.free(result_text);
        }
    }
};

const SetTimeoutThreadContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    js_context: *JsRenderContext,
    generation: u64,
    handle: u32,
    delay_ms: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        generation: u64,
        handle: u32,
        delay_ms: u32,
    ) !*SetTimeoutThreadContext {
        const ctx = try allocator.create(SetTimeoutThreadContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .js_context = js_context,
            .generation = generation,
            .handle = handle,
            .delay_ms = delay_ms,
        };
        return ctx;
    }

    fn destroy(self: *SetTimeoutThreadContext) void {
        self.allocator.destroy(self);
    }
};

fn runSetTimeoutThread(ctx: *SetTimeoutThreadContext) void {
    defer ctx.destroy();
    defer ctx.tab.releaseAsyncThread();

    _ = ctx.browser.measure.registerThread("SetTimeout thread") catch |err| {
        std.log.warn("Failed to register setTimeout thread: {}", .{err});
    };

    if (ctx.delay_ms > 0) {
        const delay_ns = @as(u64, ctx.delay_ms) * std.time.ns_per_ms;
        std.Thread.sleep(delay_ns);
    }

    if (!ctx.js_context.matchesGeneration(ctx.generation)) {
        return;
    }

    const task_ctx = SetTimeoutTaskContext.create(
        ctx.browser.allocator,
        ctx.browser,
        ctx.js_context,
        ctx.generation,
        ctx.handle,
    ) catch |err| {
        std.log.warn("Failed to allocate setTimeout task: {}", .{err});
        return;
    };
    errdefer task_ctx.destroy();

    const task = Task.init(
        task_ctx.toOpaque(),
        SetTimeoutTaskContext.runOpaque,
        SetTimeoutTaskContext.cleanupOpaque,
    );

    ctx.tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to enqueue setTimeout task: {}", .{err});
        task_ctx.destroy();
    };
}

const SetTimeoutTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    js_context: *JsRenderContext,
    generation: u64,
    handle: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        js_context: *JsRenderContext,
        generation: u64,
        handle: u32,
    ) !*SetTimeoutTaskContext {
        const ctx = try allocator.create(SetTimeoutTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .js_context = js_context,
            .generation = generation,
            .handle = handle,
        };
        return ctx;
    }

    fn destroy(self: *SetTimeoutTaskContext) void {
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *SetTimeoutTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *SetTimeoutTaskContext {
        const raw: *align(1) SetTimeoutTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try SetTimeoutTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        SetTimeoutTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *SetTimeoutTaskContext) !void {
        if (!self.js_context.matchesGeneration(self.generation)) {
            return;
        }
        const trace_eval = self.browser.measure.begin("evaljs");
        defer if (trace_eval) self.browser.measure.end("evaljs");
        self.browser.js_engine.runTimeoutCallback(self.handle) catch |err| {
            std.log.warn("setTimeout callback failed: {}", .{err});
        };
    }
};

const AnimationTimerContext = struct {
    browser: *Browser,

    fn create(browser: *Browser) !*AnimationTimerContext {
        const ctx = try browser.allocator.create(AnimationTimerContext);
        ctx.* = .{ .browser = browser };
        return ctx;
    }

    fn destroy(self: *AnimationTimerContext) void {
        self.browser.allocator.destroy(self);
    }
};

fn runAnimationTimerThread(ctx: *AnimationTimerContext) void {
    const browser = ctx.browser;
    defer ctx.destroy();

    _ = browser.measure.registerThread("Animation timer thread") catch |err| {
        std.log.warn("Failed to register animation timer thread: {}", .{err});
    };

    std.Thread.sleep(refresh_rate_ns);

    browser.lock.lock();
    // Check if browser is shutting down before accessing any resources
    if (browser.shutting_down) {
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    }
    const tab = browser.activeTab() orelse {
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };
    const generation = tab.js_generation;
    const scroll = browser.active_tab_scroll;
    browser.lock.unlock();

    tab.retainAsyncThread();
    const render_ctx = AnimationRenderTaskContext.create(
        browser.allocator,
        browser,
        tab,
        generation,
        scroll,
    ) catch |err| {
        std.log.warn("Failed to allocate animation task: {}", .{err});
        tab.releaseAsyncThread();
        browser.lock.lock();
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };

    const task = Task.init(
        render_ctx.toOpaque(),
        AnimationRenderTaskContext.runOpaque,
        AnimationRenderTaskContext.cleanupOpaque,
    );

    tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to schedule animation frame: {}", .{err});
        render_ctx.destroy();
        tab.releaseAsyncThread();
        browser.lock.lock();
        browser.animation_timer_active = false;
        browser.lock.unlock();
        return;
    };
    tab.releaseAsyncThread();
}

const AnimationRenderTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    generation: u64,
    scroll: i32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        generation: u64,
        scroll: i32,
    ) !*AnimationRenderTaskContext {
        const ctx = try allocator.create(AnimationRenderTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .generation = generation,
            .scroll = scroll,
        };
        return ctx;
    }

    fn destroy(self: *AnimationRenderTaskContext) void {
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *AnimationRenderTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *AnimationRenderTaskContext {
        const raw: *align(1) AnimationRenderTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try AnimationRenderTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        AnimationRenderTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *AnimationRenderTaskContext) !void {
        if (self.tab.js_generation != self.generation) {
            return;
        }
        self.tab.runAnimationFrame(self.scroll);
    }
};

const XhrThreadContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    tab: *Tab,
    js_context: *JsRenderContext,
    generation: u64,
    resolved_url: Url,
    payload: ?[]const u8,
    handle: u32,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        tab: *Tab,
        js_context: *JsRenderContext,
        generation: u64,
        resolved_url: Url,
        payload: ?[]const u8,
        handle: u32,
    ) !*XhrThreadContext {
        const ctx = try allocator.create(XhrThreadContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .tab = tab,
            .js_context = js_context,
            .generation = generation,
            .resolved_url = resolved_url,
            .payload = null,
            .handle = handle,
        };

        if (payload) |body| {
            const copy = try allocator.alloc(u8, body.len);
            @memcpy(copy, body);
            ctx.payload = copy;
        }

        return ctx;
    }

    fn destroy(self: *XhrThreadContext) void {
        if (self.payload) |body| {
            self.allocator.free(body);
        }
        self.resolved_url.free(self.allocator);
        self.allocator.destroy(self);
    }
};

fn runXhrThread(ctx: *XhrThreadContext) void {
    defer ctx.tab.releaseAsyncThread();
    defer ctx.destroy();

    _ = ctx.browser.measure.registerThread("XHR thread") catch |err| {
        std.log.warn("Failed to register XHR thread: {}", .{err});
    };

    var referrer_copy: ?Url = null;
    if (ctx.tab.current_url) |cur_ptr| {
        referrer_copy = cur_ptr.*;
    }

    const response_result = ctx.browser.fetchBody(
        ctx.resolved_url,
        referrer_copy,
        ctx.payload,
    ) catch |err| {
        std.log.warn("Async XHR failed: {}", .{err});
        return;
    };
    defer if (response_result.csp_header) |hdr| ctx.allocator.free(hdr);

    var response_body = response_result.body;
    var should_free_response = true;
    var response_allocator: ?std.mem.Allocator = ctx.allocator;

    if (std.mem.eql(u8, ctx.resolved_url.scheme, "about")) {
        should_free_response = false;
        response_allocator = null;
    } else if (std.mem.eql(u8, ctx.resolved_url.scheme, "data")) {
        const copy = ctx.allocator.alloc(u8, response_body.len) catch {
            std.log.warn("Failed to copy async XHR data body", .{});
            return;
        };
        @memcpy(copy, response_body);
        response_body = copy;
        response_allocator = ctx.allocator;
    }

    const task_ctx = XhrOnloadTaskContext.create(
        ctx.allocator,
        ctx.browser,
        ctx.js_context,
        ctx.generation,
        ctx.handle,
        response_body,
        response_allocator,
        should_free_response,
    ) catch |err| {
        std.log.warn("Failed to enqueue XHR onload task: {}", .{err});
        if (should_free_response) {
            if (response_allocator) |alloc| {
                alloc.free(response_body);
            } else {
                ctx.allocator.free(response_body);
            }
        }
        return;
    };

    const task = Task.init(
        task_ctx.toOpaque(),
        XhrOnloadTaskContext.runOpaque,
        XhrOnloadTaskContext.cleanupOpaque,
    );

    ctx.tab.task_runner.schedule(task) catch |err| {
        std.log.warn("Failed to schedule XHR onload task: {}", .{err});
        task_ctx.destroy();
    };
}

const XhrOnloadTaskContext = struct {
    allocator: std.mem.Allocator,
    browser: *Browser,
    js_context: *JsRenderContext,
    generation: u64,
    handle: u32,
    body: []const u8,
    body_allocator: ?std.mem.Allocator,
    should_free_body: bool,

    fn create(
        allocator: std.mem.Allocator,
        browser: *Browser,
        js_context: *JsRenderContext,
        generation: u64,
        handle: u32,
        body: []const u8,
        body_allocator: ?std.mem.Allocator,
        should_free_body: bool,
    ) !*XhrOnloadTaskContext {
        const ctx = try allocator.create(XhrOnloadTaskContext);
        ctx.* = .{
            .allocator = allocator,
            .browser = browser,
            .js_context = js_context,
            .generation = generation,
            .handle = handle,
            .body = body,
            .body_allocator = body_allocator,
            .should_free_body = should_free_body,
        };
        return ctx;
    }

    fn destroy(self: *XhrOnloadTaskContext) void {
        if (self.should_free_body) {
            if (self.body_allocator) |alloc| {
                alloc.free(self.body);
            } else {
                self.allocator.free(self.body);
            }
        }
        self.allocator.destroy(self);
    }

    fn toOpaque(self: *XhrOnloadTaskContext) *anyopaque {
        return @ptrCast(self);
    }

    fn fromOpaque(context: *anyopaque) *XhrOnloadTaskContext {
        const raw: *align(1) XhrOnloadTaskContext = @ptrCast(context);
        return @alignCast(raw);
    }

    fn runOpaque(context: *anyopaque) anyerror!void {
        try XhrOnloadTaskContext.fromOpaque(context).run();
    }

    fn cleanupOpaque(context: *anyopaque) void {
        XhrOnloadTaskContext.fromOpaque(context).destroy();
    }

    fn run(self: *XhrOnloadTaskContext) !void {
        if (!self.js_context.matchesGeneration(self.generation)) {
            return;
        }
        self.browser.js_engine.runXhrOnload(self.handle, self.body) catch |err| {
            std.log.warn("XHR onload callback failed: {}", .{err});
        };
    }
};

fn jsRenderCallback(context: ?*anyopaque) anyerror!void {
    const ctx_ptr = context orelse return;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const tab_ptr = ctx.tab_ptr orelse return;

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    tab.setNeedsRender();
}

fn jsXhrCallback(
    context: ?*anyopaque,
    _: []const u8,
    url_str: []const u8,
    body: ?[]const u8,
    is_async: bool,
    handle: u32,
) anyerror!js_module.XhrResult {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    const allocator = browser.allocator;
    const generation = ctx.currentGeneration();

    var resolved_url: Url = undefined;
    if (tab.current_url) |current_ptr| {
        resolved_url = current_ptr.*.resolve(allocator, url_str) catch |err| blk: {
            std.log.warn("Failed to resolve XHR URL {s} relative to page: {}", .{ url_str, err });
            break :blk try Url.init(allocator, url_str);
        };
    } else {
        resolved_url = try Url.init(allocator, url_str);
    }

    var resolved_owned = true;
    defer if (resolved_owned) resolved_url.free(allocator);

    if (tab.current_url) |current_ptr| {
        if (!current_ptr.*.sameOrigin(resolved_url)) {
            const current_host = current_ptr.*.host orelse "";
            const target_host = resolved_url.host orelse "";
            std.log.warn(
                "Blocked cross-origin XHR {s}://{s}:{d} -> {s}://{s}:{d}",
                .{ current_ptr.*.scheme, current_host, current_ptr.*.port, resolved_url.scheme, target_host, resolved_url.port },
            );
            return error.CrossOriginBlocked;
        }
    }

    if (!tab.allowedRequest(resolved_url, tab.current_url)) {
        const target_host = resolved_url.host orelse "";
        std.log.warn(
            "Blocked XHR to {s}://{s}:{d} due to CSP",
            .{ resolved_url.scheme, target_host, resolved_url.port },
        );
        return error.CspViolation;
    }

    var current_url_value: ?Url = null;
    if (tab.current_url) |cur_ptr| {
        current_url_value = cur_ptr.*;
    }

    if (is_async) {
        try browser.scheduleAsyncXhr(tab, ctx, generation, resolved_url, body, handle);
        resolved_owned = false;
        return .{ .data = "", .allocator = null, .should_free = false };
    }

    const response = try browser.fetchBody(resolved_url, current_url_value, body);
    defer if (response.csp_header) |hdr| allocator.free(hdr);

    var response_body = response.body;

    var should_free_response = true;
    var response_allocator: ?std.mem.Allocator = allocator;

    if (std.mem.eql(u8, resolved_url.scheme, "data")) {
        const copy = try allocator.alloc(u8, response_body.len);
        @memcpy(copy, response_body);
        response_body = copy;
    } else if (std.mem.eql(u8, resolved_url.scheme, "about")) {
        should_free_response = false;
        response_allocator = null;
    }

    return .{
        .data = response_body,
        .allocator = response_allocator,
        .should_free = should_free_response,
    };
}

fn jsSetTimeoutCallback(
    context: ?*anyopaque,
    handle: u32,
    delay_ms: u32,
) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const browser_ptr = ctx.browser_ptr orelse return error.MissingJsContext;
    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_browser: *align(1) Browser = @ptrCast(browser_ptr);
    const browser: *Browser = @alignCast(raw_browser);

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    try browser.scheduleSetTimeoutTask(tab, ctx, handle, delay_ms);
}

fn jsRequestAnimationFrameCallback(
    context: ?*anyopaque,
) anyerror!void {
    const ctx_ptr = context orelse return error.MissingJsContext;
    const raw_ctx: *align(1) JsRenderContext = @ptrCast(ctx_ptr);
    const ctx: *JsRenderContext = @alignCast(raw_ctx);

    const tab_ptr = ctx.tab_ptr orelse return error.MissingJsContext;

    const raw_tab: *align(1) Tab = @ptrCast(tab_ptr);
    const tab: *Tab = @alignCast(raw_tab);

    tab.setNeedsRender();
}
