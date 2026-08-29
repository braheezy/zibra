//! Shared identity for CSS generated pseudo-elements.
//!
//! This module is deliberately DOM-free: selectors, the DOM's private
//! generated-node storage, and later style/layout phases use the same small
//! value without introducing an ownership or import cycle.

/// The generated box selected by a CSS `::before` or `::after` pseudo-element.
pub const Kind = enum {
    before,
    after,
};
