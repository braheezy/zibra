//! Computed-style initialization, cascade, inheritance, and animations.
//!
//! DOM storage and invalidation callbacks are supplied through a narrow
//! comptime boundary. This module owns property defaults and the complete
//! style-pass algorithm, but never owns a Node or layout object.

const std = @import("std");
const ProtectedField = @import("../core/protected_field.zig").ProtectedField;
const CSSParser = @import("css_parser.zig").CSSParser;
const css_length = @import("length.zig");
const css_animation = @import("css_animation.zig");
const animation = @import("animation.zig");
const css_properties = @import("css_properties.zig");

const Animation = animation.Animation;
const CssAnimationState = animation.CssAnimationState;
const NumericAnimation = animation.NumericAnimation;
const PixelAnimation = animation.PixelAnimation;
const ColorAnimation = animation.ColorAnimation;
const TransformAnimation = animation.TransformAnimation;
const Translation = animation.Translation;
const parseCssColor = animation.parseCssColor;
const parseTranslate = animation.parseTranslate;
const cssAnimationPropertyBit = animation.cssAnimationPropertyBit;
const css_animation_properties = animation.css_animation_properties;

const InheritedProperty = struct {
    name: []const u8,
    default_value: []const u8,
};

const INHERITED_PROPERTIES = [_]InheritedProperty{
    .{ .name = "font-family", .default_value = "sans-serif" },
    .{ .name = "font-size", .default_value = "16px" },
    .{ .name = "font-style", .default_value = "normal" },
    .{ .name = "font-variant", .default_value = "normal" },
    .{ .name = "font-weight", .default_value = "normal" },
    .{ .name = "font-stretch", .default_value = "normal" },
    .{ .name = "line-height", .default_value = "normal" },
    .{ .name = "text-align", .default_value = "start" },
    .{ .name = "color", .default_value = "black" },
    .{ .name = "color-scheme", .default_value = "light dark" },
};

const CSS_PROPERTIES = css_properties.computed;

/// Stable property order and defaults shared with DOM inspection output.
/// The cascade remains the owner; consumers must not duplicate this table.
pub const computed_properties = CSS_PROPERTIES;

fn isInheritedProperty(property: []const u8) bool {
    for (INHERITED_PROPERTIES) |prop| {
        if (std.mem.eql(u8, prop.name, property)) return true;
    }
    return false;
}

pub fn initStyleMap(comptime StyleMap: type, allocator: std.mem.Allocator, obj_name: []const u8, parent_style: ?*StyleMap) !StyleMap {
    var map = StyleMap.init(allocator);
    errdefer deinitStyleMap(StyleMap, &map, allocator);
    for (CSS_PROPERTIES) |prop| {
        var field = ProtectedField([]const u8).initNamed(prop.default_value, obj_name, prop.name);
        field.dirty = true;
        map.put(prop.name, field) catch |err| {
            field.deinit(allocator);
            return err;
        };
    }
    for (CSS_PROPERTIES) |prop| {
        if (map.getPtr(prop.name)) |child_field| {
            if (parent_style != null and isInheritedProperty(prop.name)) {
                if (parent_style.?.getPtr(prop.name)) |parent_field| {
                    child_field.addDependency(parent_field, allocator);
                }
            }
            child_field.freezeDependencies();
        }
    }
    return map;
}

pub fn deinitStyleMap(comptime StyleMap: type, map: *StyleMap, allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

pub fn styleNeedsUpdate(comptime StyleMap: type, map: *StyleMap) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.dirty) return true;
    }
    return false;
}

/// Instantiate style application for one concrete DOM representation.
pub fn Application(
    comptime Node: type,
    comptime Element: type,
    comptime StyleMap: type,
    comptime bindStyleOwnerFn: anytype,
    comptime markStyleMapWithoutOwnerFn: anytype,
    comptime styleTreeNeedsUpdateFn: anytype,
    comptime markPaintForNodeFn: anytype,
) type {
    return struct {
        fn cssDefaultFor(property: []const u8) []const u8 {
            for (CSS_PROPERTIES) |prop| {
                if (std.mem.eql(u8, prop.name, property)) {
                    return prop.default_value;
                }
            }
            return "";
        }

        fn cssInitialValue(property: []const u8) []const u8 {
            for (INHERITED_PROPERTIES) |prop| {
                if (std.mem.eql(u8, prop.name, property)) return prop.default_value;
            }
            return cssDefaultFor(property);
        }

        fn keyframesNamed(
            keyframes: []const CSSParser.KeyframesRule,
            name: []const u8,
        ) ?*const CSSParser.KeyframesRule {
            var index = keyframes.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, keyframes[index].name, name)) return &keyframes[index];
            }
            return null;
        }

        fn keyframeAnimationForProperty(
            property: []const u8,
            start_value: []const u8,
            end_value: []const u8,
            spec: css_animation.Spec,
        ) ?Animation {
            if (std.mem.eql(u8, property, "opacity")) {
                const start = std.fmt.parseFloat(f64, start_value) catch return null;
                const end = std.fmt.parseFloat(f64, end_value) catch return null;
                if (!std.math.isFinite(start) or !std.math.isFinite(end)) return null;
                return .{ .numeric = NumericAnimation.initWithEasing(
                    start,
                    end,
                    spec.frames,
                    spec.easing_function,
                ) };
            }
            if (std.mem.eql(u8, property, "background-color")) {
                const start = parseCssColor(start_value) orelse return null;
                const end = parseCssColor(end_value) orelse return null;
                return .{ .color = ColorAnimation.initWithEasing(
                    start,
                    end,
                    spec.frames,
                    spec.easing_function,
                ) };
            }
            if (std.mem.eql(u8, property, "transform")) {
                const start = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, start_value, " \t\r\n"), "none"))
                    Translation{ .x = 0, .y = 0 }
                else
                    parseTranslate(start_value) orelse return null;
                const end = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, end_value, " \t\r\n"), "none"))
                    Translation{ .x = 0, .y = 0 }
                else
                    parseTranslate(end_value) orelse return null;
                return .{ .transform = TransformAnimation.initWithEasing(
                    start,
                    end,
                    spec.frames,
                    spec.easing_function,
                ) };
            }
            if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "height")) {
                const start = css_length.parsePixel(start_value) orelse return null;
                const end = css_length.parsePixel(end_value) orelse return null;
                return .{ .pixel = PixelAnimation.initWithEasing(
                    start,
                    end,
                    spec.frames,
                    spec.easing_function,
                ) };
            }
            return null;
        }

        fn cssAnimationSignature(
            raw_animation: []const u8,
            start: *const CSSParser.Keyframe,
            end: *const CSSParser.Keyframe,
        ) u64 {
            var signature = std.hash.Wyhash.hash(0, std.mem.trim(u8, raw_animation, " \t\r\n"));
            for (css_animation_properties) |property| {
                const start_declaration = start.properties.get(property) orelse continue;
                const end_declaration = end.properties.get(property) orelse continue;
                signature = std.hash.Wyhash.hash(signature, property);
                signature = std.hash.Wyhash.hash(signature, start_declaration.value);
                signature = std.hash.Wyhash.hash(signature, end_declaration.value);
            }
            return signature;
        }

        fn cssAnimationTracksPresent(element: *const Element, state: CssAnimationState) bool {
            if (state.finished) return true;
            const animations = element.animations orelse return false;
            for (css_animation_properties) |property| {
                if (state.contains(property) and !animations.contains(property)) return false;
            }
            return true;
        }

        pub fn removeCssAnimationTracks(element: *Element) void {
            const state = element.css_animation orelse return;
            if (element.animations) |*animations| {
                for (css_animation_properties) |property| {
                    if (state.contains(property)) _ = animations.remove(property);
                }
            }
            element.css_animation = null;
        }

        pub fn finishCssAnimationTracks(element: *Element) void {
            const state = element.css_animation orelse return;
            if (element.animations) |*animations| {
                for (css_animation_properties) |property| {
                    if (state.contains(property)) _ = animations.remove(property);
                }
            }
            element.css_animation.?.restart_pending = false;
            element.css_animation.?.finished = true;
        }

        fn syncCssAnimation(
            allocator: std.mem.Allocator,
            element: *Element,
            raw_animation: []const u8,
            keyframes: []const CSSParser.KeyframesRule,
        ) !void {
            const spec = css_animation.parse(raw_animation) orelse {
                removeCssAnimationTracks(element);
                return;
            };
            const rule = keyframesNamed(keyframes, spec.name) orelse {
                removeCssAnimationTracks(element);
                return;
            };
            const start = rule.frameAt(0) orelse {
                removeCssAnimationTracks(element);
                return;
            };
            const end = rule.frameAt(1) orelse {
                removeCssAnimationTracks(element);
                return;
            };

            const signature = cssAnimationSignature(raw_animation, start, end);
            if (element.css_animation) |state| {
                if (state.signature == signature and cssAnimationTracksPresent(element, state)) return;
            }

            var tracks = [_]?Animation{ null, null, null, null, null };
            var property_mask: u8 = 0;
            for (css_animation_properties, 0..) |property, index| {
                const start_declaration = start.properties.get(property) orelse continue;
                const end_declaration = end.properties.get(property) orelse continue;
                tracks[index] = keyframeAnimationForProperty(
                    property,
                    start_declaration.value,
                    end_declaration.value,
                    spec,
                ) orelse continue;
                property_mask |= cssAnimationPropertyBit(property);
            }
            if (property_mask == 0) {
                removeCssAnimationTracks(element);
                return;
            }

            if (element.animations == null) {
                element.animations = std.StringHashMap(Animation).init(allocator);
            }
            try element.animations.?.ensureUnusedCapacity(css_animation_properties.len);
            removeCssAnimationTracks(element);
            for (css_animation_properties, 0..) |property, index| {
                if (tracks[index]) |track| element.animations.?.putAssumeCapacity(property, track);
            }
            element.css_animation = .{
                .signature = signature,
                .property_mask = property_mask,
                .iterations = spec.iterations,
                .direction = spec.direction,
            };
        }

        fn resolveFontFamilyKeyword(value: []const u8, inherited_value: []const u8) []const u8 {
            const keyword = std.mem.trim(u8, value, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(keyword, "inherit") or
                std.ascii.eqlIgnoreCase(keyword, "unset"))
            {
                return inherited_value;
            }
            if (std.ascii.eqlIgnoreCase(keyword, "initial")) return "sans-serif";
            return value;
        }

        fn resolveInheritedFontKeyword(
            value: []const u8,
            inherited_value: []const u8,
            initial_value: []const u8,
        ) []const u8 {
            const keyword = std.mem.trim(u8, value, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(keyword, "inherit") or
                std.ascii.eqlIgnoreCase(keyword, "unset")) return inherited_value;
            if (std.ascii.eqlIgnoreCase(keyword, "initial")) return initial_value;
            return value;
        }

        // Helper to get a default parent style map with inherited defaults
        fn getDefaultParentStyle(allocator: std.mem.Allocator) !StyleMap {
            var parent_style = try initStyleMap(StyleMap, allocator, "Node", null);
            var it = parent_style.iterator();
            while (it.next()) |entry| {
                const default_value = cssDefaultFor(entry.key_ptr.*);
                entry.value_ptr.set(default_value);
            }
            for (INHERITED_PROPERTIES) |prop| {
                if (parent_style.getPtr(prop.name)) |field| {
                    field.set(prop.default_value);
                }
            }
            return parent_style;
        }

        pub const StylePassStats = struct {
            /// Nodes whose own style or descendant summary required entering them.
            visited_nodes: usize = 0,
            /// Nodes whose computed-style fields were actually recalculated.
            recomputed_nodes: usize = 0,
            /// Clean subtree roots rejected without visiting any of their children.
            skipped_subtrees: usize = 0,
        };

        // Parse inline styles from the style attribute and apply CSS rules to the node tree.
        pub fn style(allocator: std.mem.Allocator, node: *Node, rules: []const CSSParser.CSSRule) !void {
            return styleWithKeyframesInternal(allocator, node, rules, &.{}, null);
        }

        /// Instrumented style entry point used by invalidation regressions and
        /// isolated diagnostics. Production callers use `style` or
        /// `styleWithKeyframes`; the traversal and behavior are identical.
        pub fn styleWithStats(
            allocator: std.mem.Allocator,
            node: *Node,
            rules: []const CSSParser.CSSRule,
            stats: *StylePassStats,
        ) !void {
            stats.* = .{};
            return styleWithKeyframesInternal(allocator, node, rules, &.{}, stats);
        }

        pub fn styleWithKeyframes(
            allocator: std.mem.Allocator,
            node: *Node,
            rules: []const CSSParser.CSSRule,
            keyframes: []const CSSParser.KeyframesRule,
        ) !void {
            return styleWithKeyframesInternal(allocator, node, rules, keyframes, null);
        }

        fn styleWithKeyframesInternal(
            allocator: std.mem.Allocator,
            node: *Node,
            rules: []const CSSParser.CSSRule,
            keyframes: []const CSSParser.KeyframesRule,
            stats: ?*StylePassStats,
        ) !void {
            if (!styleTreeNeedsUpdateFn(node)) {
                if (stats) |pass_stats| pass_stats.skipped_subtrees += 1;
                return;
            }

            var has_cache = CSSParser.HasMatchCache.init(allocator);
            defer has_cache.deinit();
            for (rules) |rule| try rule.selector.populateHasMatches(&has_cache, node);

            var default_parent = try getDefaultParentStyle(allocator);
            defer deinitStyleMap(StyleMap, &default_parent, allocator);
            const empty_ancestors = &[_]*Node{};
            try styleWithParent(
                allocator,
                node,
                rules,
                keyframes,
                &default_parent,
                empty_ancestors,
                .{ .has_cache = &has_cache },
                true,
                stats,
            );
        }

        fn applyCascadedDeclaration(
            values: *std.StringHashMap([]const u8),
            priorities: *std.StringHashMap(u32),
            property: []const u8,
            declaration: CSSParser.Declaration,
            base_priority: u32,
        ) !void {
            const priority = declaration.priority(base_priority);
            if (priorities.get(property)) |existing_priority| {
                // Later declarations win ties; callers preserve stylesheet source
                // order among equal-specificity rules.
                if (priority < existing_priority) return;
            }
            try values.put(property, declaration.value);
            try priorities.put(property, priority);
        }

        fn inheritedValue(
            parent_field: *ProtectedField([]const u8),
            child_field: *ProtectedField([]const u8),
            parent_is_ephemeral_default: bool,
            allocator: std.mem.Allocator,
        ) []const u8 {
            // The synthetic root parent is destroyed at the end of every style pass,
            // so root fields may read it but must never register a dependency on it.
            if (parent_is_ephemeral_default) return parent_field.get().*;

            // A retained style map can move between parents through removeChild.
            // Register the current edge before a frozen dependency read. Former edges
            // remain registered under ProtectedField's current no-unsubscribe model.
            child_field.addDependency(parent_field, allocator);
            return parent_field.read(child_field, allocator).*;
        }

        fn styleWithParent(
            allocator: std.mem.Allocator,
            node: *Node,
            rules: []const CSSParser.CSSRule,
            keyframes: []const CSSParser.KeyframesRule,
            parent_style: *StyleMap,
            ancestor_chain: []const *Node,
            match_context: CSSParser.MatchContext,
            parent_is_ephemeral_default: bool,
            stats: ?*StylePassStats,
        ) !void {
            if (!styleTreeNeedsUpdateFn(node)) {
                if (stats) |pass_stats| pass_stats.skipped_subtrees += 1;
                return;
            }
            if (stats) |pass_stats| pass_stats.visited_nodes += 1;

            switch (node.*) {
                .text => |*t| {
                    const had_style = t.style != null;
                    if (t.style == null) {
                        t.style = try initStyleMap(
                            StyleMap,
                            allocator,
                            "TextNode",
                            if (parent_is_ephemeral_default) null else parent_style,
                        );
                        bindStyleOwnerFn(node);
                    }
                    var style_map = &t.style.?;
                    std.debug.assert(styleNeedsUpdate(StyleMap, style_map));
                    // Initial style precedes layout and has no retained paint
                    // commands to invalidate. Only a restyle can stale an
                    // existing display-list owner.
                    if (had_style) markPaintForNodeFn(node);
                    if (stats) |pass_stats| pass_stats.recomputed_nodes += 1;
                    errdefer markStyleMapWithoutOwnerFn(style_map);

                    var new_style = std.StringHashMap([]const u8).init(allocator);
                    defer new_style.deinit();

                    for (CSS_PROPERTIES) |prop| {
                        try new_style.put(prop.name, prop.default_value);
                    }

                    for (INHERITED_PROPERTIES) |prop| {
                        if (style_map.getPtr(prop.name)) |child_field| {
                            if (parent_style.getPtr(prop.name)) |parent_field| {
                                const parent_value = inheritedValue(
                                    parent_field,
                                    child_field,
                                    parent_is_ephemeral_default,
                                    allocator,
                                );
                                try new_style.put(prop.name, parent_value);
                            } else {
                                try new_style.put(prop.name, prop.default_value);
                            }
                        }
                    }

                    for (CSS_PROPERTIES) |prop| {
                        if (style_map.getPtr(prop.name)) |field| {
                            const value = new_style.get(prop.name) orelse prop.default_value;
                            field.set(value);
                        }
                    }
                    return;
                },
                .element => |*e| {
                    const had_style = e.style != null;
                    if (e.style == null) {
                        e.style = try initStyleMap(
                            StyleMap,
                            allocator,
                            "Element",
                            if (parent_is_ephemeral_default) null else parent_style,
                        );
                        bindStyleOwnerFn(node);
                    }
                    var style_map = &e.style.?;
                    const needs_style = styleNeedsUpdate(StyleMap, style_map);

                    if (needs_style) {
                        if (had_style) markPaintForNodeFn(node);
                        if (stats) |pass_stats| pass_stats.recomputed_nodes += 1;
                        errdefer markStyleMapWithoutOwnerFn(style_map);
                        var new_style = std.StringHashMap([]const u8).init(allocator);
                        defer new_style.deinit();
                        var cascade_priorities = std.StringHashMap(u32).init(allocator);
                        defer cascade_priorities.deinit();

                        for (CSS_PROPERTIES) |prop| {
                            try new_style.put(prop.name, prop.default_value);
                        }

                        // First, inherit properties from parent
                        for (INHERITED_PROPERTIES) |prop| {
                            if (style_map.getPtr(prop.name)) |child_field| {
                                if (parent_style.getPtr(prop.name)) |parent_field| {
                                    const parent_value = inheritedValue(
                                        parent_field,
                                        child_field,
                                        parent_is_ephemeral_default,
                                        allocator,
                                    );
                                    try new_style.put(prop.name, parent_value);
                                } else {
                                    try new_style.put(prop.name, prop.default_value);
                                }
                            }
                        }

                        // Second, apply styles from CSS rules (can override inherited values)
                        for (rules) |rule| {
                            if (rule.selector.matchesWithContext(node, ancestor_chain, match_context)) {
                                var it = rule.properties.iterator();
                                while (it.next()) |entry| {
                                    try applyCascadedDeclaration(
                                        &new_style,
                                        &cascade_priorities,
                                        entry.key_ptr.*,
                                        entry.value_ptr.*,
                                        rule.cascadePriority(),
                                    );
                                }
                            }
                        }

                        // Third, apply style-attribute declarations with inline
                        // specificity. Author !important still beats normal inline.
                        if (e.attributes) |attrs| {
                            if (attrs.get("style")) |style_attr| {
                                var css_parser = try CSSParser.init(allocator, style_attr, false);
                                defer css_parser.deinit(allocator);

                                var parsed_styles = try css_parser.body(allocator);
                                defer parsed_styles.deinit();

                                var it = parsed_styles.iterator();
                                while (it.next()) |entry| {
                                    try applyCascadedDeclaration(
                                        &new_style,
                                        &cascade_priorities,
                                        entry.key_ptr.*,
                                        entry.value_ptr.*,
                                        CSSParser.INLINE_STYLE_PRIORITY,
                                    );
                                }
                            }
                        }

                        // Resolve CSS-wide keywords for every supported
                        // property before focused computed-value transforms.
                        // Explicit inherit on a normally non-inherited property
                        // still registers the parent dependency it requests.
                        for (CSS_PROPERTIES) |prop| {
                            const authored = new_style.get(prop.name) orelse continue;
                            const keyword = std.mem.trim(u8, authored, " \t\r\n");
                            const wants_inherited = std.ascii.eqlIgnoreCase(keyword, "inherit") or
                                (std.ascii.eqlIgnoreCase(keyword, "unset") and
                                    isInheritedProperty(prop.name));
                            if (wants_inherited) {
                                const child_field = style_map.getPtr(prop.name).?;
                                const inherited = if (parent_style.getPtr(prop.name)) |parent_field|
                                    inheritedValue(
                                        parent_field,
                                        child_field,
                                        parent_is_ephemeral_default,
                                        allocator,
                                    )
                                else
                                    cssInitialValue(prop.name);
                                try new_style.put(prop.name, inherited);
                            } else if (std.ascii.eqlIgnoreCase(keyword, "initial") or
                                std.ascii.eqlIgnoreCase(keyword, "unset"))
                            {
                                try new_style.put(prop.name, cssInitialValue(prop.name));
                            }
                        }

                        // Resolve CSS-wide keywords before storing the computed
                        // font-family value. Since font-family is inherited, `unset`
                        // has the same effect as `inherit`.
                        if (new_style.get("font-family")) |font_family| {
                            const child_field = style_map.getPtr("font-family").?;
                            const inherited_family = if (parent_style.getPtr("font-family")) |parent_field|
                                inheritedValue(parent_field, child_field, parent_is_ephemeral_default, allocator)
                            else
                                "sans-serif";
                            try new_style.put(
                                "font-family",
                                resolveFontFamilyKeyword(font_family, inherited_family),
                            );
                        }

                        // Resolve CSS-wide keywords for the other inherited font
                        // longhands before layout reads the computed style. Shorthand
                        // expansion writes concrete values, while an explicit
                        // `inherit`, `unset`, or `initial` still needs its computed
                        // value rather than leaking the keyword into rendering.
                        for ([_]struct { name: []const u8, initial: []const u8 }{
                            .{ .name = "font-style", .initial = "normal" },
                            .{ .name = "font-variant", .initial = "normal" },
                            .{ .name = "font-weight", .initial = "normal" },
                            .{ .name = "font-stretch", .initial = "normal" },
                            .{ .name = "line-height", .initial = "normal" },
                        }) |prop| {
                            if (new_style.get(prop.name)) |value| {
                                const child_field = style_map.getPtr(prop.name).?;
                                const inherited_value = if (parent_style.getPtr(prop.name)) |parent_field|
                                    inheritedValue(parent_field, child_field, parent_is_ephemeral_default, allocator)
                                else
                                    prop.initial;
                                try new_style.put(
                                    prop.name,
                                    resolveInheritedFontKeyword(value, inherited_value, prop.initial),
                                );
                            }
                        }

                        // Fourth, resolve relative font sizes to absolute pixels.
                        // Computed font-size values are kept in px so inherited
                        // descendants can use them as the base for their own `em`
                        // and percentage lengths.
                        if (new_style.get("font-size")) |font_size| {
                            const font_size_length = css_length.parse(font_size);
                            if (font_size_length) |length| {
                                const child_field = style_map.getPtr("font-size").?;
                                const parent_font_size = if (parent_style.getPtr("font-size")) |parent_field|
                                    inheritedValue(parent_field, child_field, parent_is_ephemeral_default, allocator)
                                else
                                    "16px";

                                const parent_px = css_length.resolve(parent_font_size, .{}) orelse 16.0;
                                const absolute_px = css_length.resolveLength(length, .{
                                    .font_size = parent_px,
                                    .percentage_base = parent_px,
                                }) orelse 0.0;
                                if (length.unit != .px) {
                                    const resolved_size = try std.fmt.allocPrint(
                                        allocator,
                                        "{d:.1}px",
                                        .{absolute_px},
                                    );
                                    var resolved_size_owned = true;
                                    defer if (resolved_size_owned) allocator.free(resolved_size);

                                    if (e.owned_strings == null) {
                                        e.owned_strings = std.ArrayList([]const u8).empty;
                                    }
                                    try e.owned_strings.?.append(allocator, resolved_size);
                                    resolved_size_owned = false;

                                    try new_style.put("font-size", resolved_size);
                                }
                            }
                        }

                        // Length and percentage line-heights compute to an absolute
                        // value at the element's font size. Unitless numbers remain
                        // unitless so descendants inherit the multiplier and apply it
                        // to their own font size, matching CSS's useful distinction.
                        if (new_style.get("line-height")) |line_height| {
                            if (css_length.parse(line_height)) |length| {
                                if (length.unit != .px) {
                                    const font_size = css_length.resolve(
                                        new_style.get("font-size") orelse "16px",
                                        .{},
                                    ) orelse 16.0;
                                    if (css_length.resolveLength(length, .{
                                        .font_size = font_size,
                                        .percentage_base = font_size,
                                    })) |absolute_px| {
                                        const resolved_line_height = try std.fmt.allocPrint(
                                            allocator,
                                            "{d:.1}px",
                                            .{absolute_px},
                                        );
                                        var resolved_line_height_owned = true;
                                        defer if (resolved_line_height_owned) allocator.free(resolved_line_height);

                                        if (e.owned_strings == null) {
                                            e.owned_strings = std.ArrayList([]const u8).empty;
                                        }
                                        try e.owned_strings.?.append(allocator, resolved_line_height);
                                        resolved_line_height_owned = false;
                                        try new_style.put("line-height", resolved_line_height);
                                    }
                                }
                            }
                        }

                        for (CSS_PROPERTIES) |prop| {
                            if (style_map.getPtr(prop.name)) |field| {
                                const value = new_style.get(prop.name) orelse prop.default_value;
                                field.set(value);
                            }
                        }
                        try syncCssAnimation(
                            allocator,
                            e,
                            new_style.get("animation") orelse "none",
                            keyframes,
                        );
                    }

                    // Finally, recursively process all children with this element's computed style
                    // Build new ancestor chain by appending current node
                    var new_ancestors = try allocator.alloc(*Node, ancestor_chain.len + 1);
                    defer allocator.free(new_ancestors);

                    // Copy existing ancestors
                    for (ancestor_chain, 0..) |ancestor, i| {
                        new_ancestors[i] = ancestor;
                    }
                    // Add current node as the most recent ancestor
                    new_ancestors[ancestor_chain.len] = node;

                    for (e.children.items) |*child| {
                        try styleWithParent(
                            allocator,
                            child,
                            rules,
                            keyframes,
                            style_map,
                            new_ancestors,
                            match_context,
                            false,
                            stats,
                        );
                    }
                    // Clear only after every requested descendant completed. An error
                    // leaves the summary set so a later protected style generation
                    // retries the unfinished branch.
                    e.has_dirty_style_descendants = false;
                },
            }
        }
    };
}
