//! Public computed-style pass bound to Zibra's DOM representation.
//!
//! `style_application.zig` owns the cascade algorithm. This module supplies
//! only the DOM invalidation callbacks needed to bind computed fields after
//! by-value Nodes move.

const dom = @import("dom.zig");
const application = @import("style_application.zig");

const Engine = application.Application(
    dom.Node,
    dom.Element,
    dom.StyleMap,
    dom.bindStyleOwner,
    dom.markStyleMapWithoutOwner,
    dom.styleTreeNeedsUpdate,
    dom.markPaintForNode,
);

pub const removeCssAnimationTracks = Engine.removeCssAnimationTracks;
pub const finishCssAnimationTracks = Engine.finishCssAnimationTracks;
pub const StylePassStats = Engine.StylePassStats;
pub const style = Engine.style;
pub const styleWithStats = Engine.styleWithStats;
pub const styleWithKeyframes = Engine.styleWithKeyframes;
