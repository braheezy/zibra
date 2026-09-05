//! Registry of CSS longhands implemented by Zibra's computed-style pipeline.
//!
//! The entries are static, non-owning metadata shared by style initialization
//! and parsing. A parser may recognize only a subset of shorthand grammar, but
//! it must never admit a longhand name that this registry cannot publish into
//! a computed style map.

pub const Property = struct {
    name: []const u8,
    default_value: []const u8,
};

pub const Shorthand = struct { name: []const u8, longhands: []const []const u8 };

/// Reset targets shared by CSS-wide keywords and pending var() shorthands.
pub const shorthands = [_]Shorthand{
    .{ .name = "flex", .longhands = &.{ "flex-grow", "flex-shrink", "flex-basis" } },
    .{ .name = "flex-flow", .longhands = &.{ "flex-direction", "flex-wrap" } },
    .{ .name = "gap", .longhands = &.{ "row-gap", "column-gap" } },
    .{ .name = "place-items", .longhands = &.{ "align-items", "justify-items" } },
    .{ .name = "place-content", .longhands = &.{ "align-content", "justify-content" } },
    .{ .name = "font", .longhands = &.{ "font-style", "font-variant", "font-weight", "font-stretch", "font-size", "line-height", "font-family" } },
    .{ .name = "background", .longhands = &.{ "background-color", "background-image", "background-size", "background-repeat", "background-position", "background-attachment" } },
    .{ .name = "margin", .longhands = &.{ "margin-top", "margin-right", "margin-bottom", "margin-left" } },
    .{ .name = "padding", .longhands = &.{ "padding-top", "padding-right", "padding-bottom", "padding-left" } },
    .{ .name = "border-width", .longhands = &.{ "border-top-width", "border-right-width", "border-bottom-width", "border-left-width" } },
    .{ .name = "border-style", .longhands = &.{ "border-top-style", "border-right-style", "border-bottom-style", "border-left-style" } },
    .{ .name = "border-color", .longhands = &.{ "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" } },
    .{ .name = "border-top", .longhands = &.{ "border-top-width", "border-top-style", "border-top-color" } },
    .{ .name = "border-right", .longhands = &.{ "border-right-width", "border-right-style", "border-right-color" } },
    .{ .name = "border-bottom", .longhands = &.{ "border-bottom-width", "border-bottom-style", "border-bottom-color" } },
    .{ .name = "border-left", .longhands = &.{ "border-left-width", "border-left-style", "border-left-color" } },
    .{ .name = "border", .longhands = &.{ "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "border-top-style", "border-right-style", "border-bottom-style", "border-left-style", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" } },
    .{ .name = "list-style", .longhands = &.{"list-style-type"} },
};

/// Static longhand registry used to initialize and recognize computed styles.
pub const computed = [_]Property{
    .{ .name = "font-family", .default_value = "inherit" },
    .{ .name = "font-size", .default_value = "inherit" },
    .{ .name = "font-weight", .default_value = "inherit" },
    .{ .name = "font-style", .default_value = "inherit" },
    .{ .name = "font-variant", .default_value = "inherit" },
    .{ .name = "font-stretch", .default_value = "inherit" },
    .{ .name = "line-height", .default_value = "inherit" },
    .{ .name = "white-space", .default_value = "normal" },
    .{ .name = "cursor", .default_value = "auto" },
    .{ .name = "vertical-align", .default_value = "inherit" },
    .{ .name = "text-align", .default_value = "inherit" },
    .{ .name = "list-style-type", .default_value = "inherit" },
    .{ .name = "color", .default_value = "inherit" },
    // Paint-only text decoration. The renderer currently consumes the
    // single-shadow form (color plus x/y offsets), while retaining the
    // authored value for future blur/list support.
    .{ .name = "text-shadow", .default_value = "none" },
    // Visibility affects painting but not layout, and follows the inherited
    // property path so hidden ancestors suppress their descendants.
    .{ .name = "visibility", .default_value = "visible" },
    .{ .name = "content", .default_value = "normal" },
    .{ .name = "opacity", .default_value = "1.0" },
    .{ .name = "transition", .default_value = "" },
    .{ .name = "animation", .default_value = "none" },
    .{ .name = "transform", .default_value = "none" },
    .{ .name = "filter", .default_value = "none" },
    .{ .name = "mix-blend-mode", .default_value = "" },
    .{ .name = "border-radius", .default_value = "0px" },
    .{ .name = "margin-top", .default_value = "0px" },
    .{ .name = "margin-right", .default_value = "0px" },
    .{ .name = "margin-bottom", .default_value = "0px" },
    .{ .name = "margin-left", .default_value = "0px" },
    .{ .name = "padding-top", .default_value = "0px" },
    .{ .name = "padding-right", .default_value = "0px" },
    .{ .name = "padding-bottom", .default_value = "0px" },
    .{ .name = "padding-left", .default_value = "0px" },
    .{ .name = "border-top-width", .default_value = "0px" },
    .{ .name = "border-right-width", .default_value = "0px" },
    .{ .name = "border-bottom-width", .default_value = "0px" },
    .{ .name = "border-left-width", .default_value = "0px" },
    .{ .name = "border-top-style", .default_value = "none" },
    .{ .name = "border-right-style", .default_value = "none" },
    .{ .name = "border-bottom-style", .default_value = "none" },
    .{ .name = "border-left-style", .default_value = "none" },
    .{ .name = "border-top-color", .default_value = "currentColor" },
    .{ .name = "border-right-color", .default_value = "currentColor" },
    .{ .name = "border-bottom-color", .default_value = "currentColor" },
    .{ .name = "border-left-color", .default_value = "currentColor" },
    .{ .name = "overflow", .default_value = "visible" },
    .{ .name = "outline", .default_value = "none" },
    .{ .name = "background-color", .default_value = "transparent" },
    .{ .name = "background-image", .default_value = "none" },
    .{ .name = "background-size", .default_value = "auto" },
    .{ .name = "background-repeat", .default_value = "repeat" },
    .{ .name = "background-position", .default_value = "0 0" },
    .{ .name = "background-attachment", .default_value = "scroll" },
    .{ .name = "object-fit", .default_value = "fill" },
    .{ .name = "aspect-ratio", .default_value = "auto" },
    .{ .name = "image-rendering", .default_value = "auto" },
    .{ .name = "color-scheme", .default_value = "light dark" },
    .{ .name = "display", .default_value = "inline" },
    .{ .name = "box-sizing", .default_value = "content-box" },
    .{ .name = "flex-direction", .default_value = "row" },
    .{ .name = "flex-wrap", .default_value = "nowrap" },
    .{ .name = "flex-grow", .default_value = "0" },
    .{ .name = "flex-shrink", .default_value = "1" },
    .{ .name = "flex-basis", .default_value = "auto" },
    .{ .name = "order", .default_value = "0" },
    .{ .name = "row-gap", .default_value = "normal" },
    .{ .name = "column-gap", .default_value = "normal" },
    .{ .name = "justify-content", .default_value = "normal" },
    .{ .name = "align-content", .default_value = "normal" },
    .{ .name = "align-items", .default_value = "normal" },
    .{ .name = "align-self", .default_value = "auto" },
    .{ .name = "justify-items", .default_value = "normal" },
    .{ .name = "justify-self", .default_value = "auto" },
    .{ .name = "grid-template-columns", .default_value = "none" },
    .{ .name = "grid-template-rows", .default_value = "none" },
    .{ .name = "grid-auto-rows", .default_value = "auto" },
    .{ .name = "position", .default_value = "static" },
    .{ .name = "top", .default_value = "auto" },
    .{ .name = "right", .default_value = "auto" },
    .{ .name = "bottom", .default_value = "auto" },
    .{ .name = "left", .default_value = "auto" },
    // `auto` is observably different from an explicit zero: both occupy the
    // positioned auto/zero paint phase, but only an explicit integer creates
    // the stacking-level semantics needed by nested contexts.
    .{ .name = "z-index", .default_value = "auto" },
    .{ .name = "scroll-behavior", .default_value = "auto" },
    .{ .name = "zoom", .default_value = "1" },
    .{ .name = "width", .default_value = "auto" },
    .{ .name = "min-width", .default_value = "0px" },
    .{ .name = "max-width", .default_value = "none" },
    .{ .name = "height", .default_value = "auto" },
    .{ .name = "min-height", .default_value = "0px" },
    .{ .name = "max-height", .default_value = "none" },
    .{ .name = "float", .default_value = "none" },
    .{ .name = "clear", .default_value = "none" },
};
