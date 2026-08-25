//! Shared HTML focusability rules.
//!
//! Layout needs to collect bounds for every element that JavaScript may
//! focus, while keyboard traversal needs the narrower sequential-focus set.
//! Keeping both decisions here prevents paint and input from drifting apart.

const std = @import("std");
const parser = @import("parser.zig");

/// Input provenance retained by a Tab for subsequent synchronous focus()
/// calls. Keyboard-like focus always needs an indicator; pointer focus keeps
/// it only for controls where the caret/control state would otherwise be easy
/// to lose, such as inputs and editable regions.
pub const Modality = enum {
    keyboard,
    pointer,
};

fn explicitTabIndex(element: *const parser.Element) ?i32 {
    const attrs = element.attributes orelse return null;
    const raw = attrs.get("tabindex") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i32, trimmed, 10) catch 0;
}

fn hasExplicitTabIndex(element: *const parser.Element) bool {
    const attrs = element.attributes orelse return false;
    return attrs.get("tabindex") != null;
}

fn isDisabledControl(element: *const parser.Element) bool {
    if (!std.ascii.eqlIgnoreCase(element.tag, "input") and
        !std.ascii.eqlIgnoreCase(element.tag, "button")) return false;
    const attrs = element.attributes orelse return false;
    return attrs.get("disabled") != null;
}

fn isContentEditable(element: *const parser.Element) bool {
    const attrs = element.attributes orelse return false;
    const value = attrs.get("contenteditable") orelse return false;
    return !std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, value, " \t\r\n"),
        "false",
    );
}

/// Whether `HTMLElement.focus()` may target this element, before layout
/// visibility is considered. An explicit negative tabindex remains
/// programmatically focusable even though keyboard traversal skips it.
pub fn isProgrammaticallyFocusable(element: *const parser.Element) bool {
    if (element.isHiddenInput() or isDisabledControl(element)) return false;

    if (std.ascii.eqlIgnoreCase(element.tag, "input") or
        std.ascii.eqlIgnoreCase(element.tag, "button")) return true;
    if (isContentEditable(element)) return true;

    if (std.ascii.eqlIgnoreCase(element.tag, "a")) {
        const attrs = element.attributes orelse return false;
        if (attrs.get("href") != null) return true;
    }

    return hasExplicitTabIndex(element);
}

/// Whether the element participates in Tab/Shift-Tab traversal.
pub fn isSequentiallyFocusable(element: *const parser.Element) bool {
    if (!isProgrammaticallyFocusable(element)) return false;
    if (!hasExplicitTabIndex(element)) return true;
    return explicitTabIndex(element).? >= 0;
}

/// Decide the focus-visible state to install for a newly focused element.
/// Hidden and disabled controls are rejected even if a caller bypasses the
/// normal focusability check.
pub fn indicatorVisibleFor(
    element: *const parser.Element,
    modality: Modality,
) bool {
    if (!isProgrammaticallyFocusable(element)) return false;
    if (modality == .keyboard) return true;

    // Pointer-focused text controls still need a visible editing affordance.
    // The exercise explicitly applies this to every visible input; retaining
    // it for contenteditable matches the same caret-oriented heuristic.
    return std.ascii.eqlIgnoreCase(element.tag, "input") or
        isContentEditable(element);
}

/// The state predicate shared by selector matching and native ring paint.
pub fn hasVisibleFocus(element: *const parser.Element) bool {
    return element.is_focused and element.is_focus_visible;
}

test "programmatic focus includes negative tabindex while sequential focus does not" {
    const allocator = std.testing.allocator;
    var programmatic = try parser.Element.init(allocator, "div tabindex=-1", null);
    defer programmatic.deinit(allocator);
    var sequential = try parser.Element.init(allocator, "div tabindex=0", null);
    defer sequential.deinit(allocator);

    try std.testing.expect(isProgrammaticallyFocusable(&programmatic));
    try std.testing.expect(!isSequentiallyFocusable(&programmatic));
    try std.testing.expect(isProgrammaticallyFocusable(&sequential));
    try std.testing.expect(isSequentiallyFocusable(&sequential));
}

test "hidden and disabled controls are not focusable" {
    const allocator = std.testing.allocator;
    var hidden = try parser.Element.init(allocator, "input type=hidden", null);
    defer hidden.deinit(allocator);
    var disabled = try parser.Element.init(allocator, "button disabled", null);
    defer disabled.deinit(allocator);
    var password = try parser.Element.init(allocator, "input type=password", null);
    defer password.deinit(allocator);

    try std.testing.expect(!isProgrammaticallyFocusable(&hidden));
    try std.testing.expect(!isSequentiallyFocusable(&hidden));
    try std.testing.expect(!isProgrammaticallyFocusable(&disabled));
    try std.testing.expect(isProgrammaticallyFocusable(&password));
    try std.testing.expect(isSequentiallyFocusable(&password));
}

test "native links and editable elements follow HTML focus rules" {
    const allocator = std.testing.allocator;
    var link = try parser.Element.init(allocator, "a href=/next", null);
    defer link.deinit(allocator);
    var plain_link = try parser.Element.init(allocator, "a", null);
    defer plain_link.deinit(allocator);
    var editable = try parser.Element.init(allocator, "div contenteditable=true", null);
    defer editable.deinit(allocator);
    var false_editable = try parser.Element.init(allocator, "div contenteditable=false", null);
    defer false_editable.deinit(allocator);

    try std.testing.expect(isSequentiallyFocusable(&link));
    try std.testing.expect(!isProgrammaticallyFocusable(&plain_link));
    try std.testing.expect(isProgrammaticallyFocusable(&editable));
    try std.testing.expect(!isProgrammaticallyFocusable(&false_editable));
}

test "focus-visible heuristic distinguishes pointer controls from keyboard focus" {
    const allocator = std.testing.allocator;
    var link = try parser.Element.init(allocator, "a href=/next", null);
    defer link.deinit(allocator);
    var button = try parser.Element.init(allocator, "button", null);
    defer button.deinit(allocator);
    var input = try parser.Element.init(allocator, "input", null);
    defer input.deinit(allocator);
    var editable = try parser.Element.init(allocator, "div contenteditable", null);
    defer editable.deinit(allocator);
    var hidden = try parser.Element.init(allocator, "input type=hidden", null);
    defer hidden.deinit(allocator);

    try std.testing.expect(!indicatorVisibleFor(&link, .pointer));
    try std.testing.expect(!indicatorVisibleFor(&button, .pointer));
    try std.testing.expect(indicatorVisibleFor(&input, .pointer));
    try std.testing.expect(indicatorVisibleFor(&editable, .pointer));
    try std.testing.expect(!indicatorVisibleFor(&hidden, .pointer));

    try std.testing.expect(indicatorVisibleFor(&link, .keyboard));
    try std.testing.expect(indicatorVisibleFor(&button, .keyboard));
    try std.testing.expect(indicatorVisibleFor(&input, .keyboard));
    try std.testing.expect(!indicatorVisibleFor(&hidden, .keyboard));

    input.is_focused = true;
    try std.testing.expect(!hasVisibleFocus(&input));
    input.is_focus_visible = true;
    try std.testing.expect(hasVisibleFocus(&input));
}
