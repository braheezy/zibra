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

/// Static longhand registry used to initialize and recognize computed styles.
pub const computed = [_]Property{
    .{ .name = "font-family", .default_value = "inherit" },
    .{ .name = "font-size", .default_value = "inherit" },
    .{ .name = "font-weight", .default_value = "inherit" },
    .{ .name = "font-style", .default_value = "inherit" },
    .{ .name = "font-variant", .default_value = "inherit" },
    .{ .name = "font-stretch", .default_value = "inherit" },
    .{ .name = "line-height", .default_value = "inherit" },
    .{ .name = "text-align", .default_value = "inherit" },
    .{ .name = "color", .default_value = "inherit" },
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
