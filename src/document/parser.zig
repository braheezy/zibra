//! Compatibility entry point for DOM, HTML parsing, serialization, and style.
//!
//! Ownership now lives in focused modules: dom.zig stores Nodes and
//! invalidation state, html_parser.zig builds trees, html_serialization.zig
//! emits live markup, and style.zig binds the computed-style application.
//! Existing callers keep one stable import while those owners remain acyclic.

const dom = @import("dom.zig");
const html_parser = @import("html_parser.zig");
const style_module = @import("style.zig");

pub const CssColor = dom.CssColor;
pub const Canvas = dom.Canvas;
pub const parseCssColor = dom.parseCssColor;
pub const EasingFunction = dom.EasingFunction;
pub const parseEasingFunction = dom.parseEasingFunction;
pub const Translation = dom.Translation;
pub const parseTranslate = dom.parseTranslate;
pub const CssLength = dom.CssLength;
pub const CssLengthResolutionContext = dom.CssLengthResolutionContext;
pub const parseCssLength = dom.parseCssLength;
pub const resolveCssLength = dom.resolveCssLength;
pub const parsePixelLength = dom.parsePixelLength;
pub const pixelLengthToLayoutPixels = dom.pixelLengthToLayoutPixels;
pub const NumericAnimation = dom.NumericAnimation;
pub const PixelAnimation = dom.PixelAnimation;
pub const ColorAnimation = dom.ColorAnimation;
pub const TransformAnimation = dom.TransformAnimation;
pub const Animation = dom.Animation;
pub const CssAnimationState = dom.CssAnimationState;
pub const cssAnimationPropertyBit = dom.cssAnimationPropertyBit;
pub const css_animation_properties = dom.css_animation_properties;

pub const StyleMap = dom.StyleMap;
pub const CharacterReference = dom.CharacterReference;
pub const characterReferenceAt = dom.characterReferenceAt;
pub const Text = dom.Text;
pub const Element = dom.Element;
pub const ImageData = dom.ImageData;
pub const BackgroundImageData = dom.BackgroundImageData;
pub const Node = dom.Node;
pub const fixParentPointers = dom.fixParentPointers;

pub const serializeInnerHtml = dom.serializeInnerHtml;
pub const serializeOuterHtml = dom.serializeOuterHtml;

pub const HTMLParser = html_parser.Parser(
    Node,
    Element,
    Text,
    fixParentPointers,
);

pub const styleTreeNeedsUpdate = dom.styleTreeNeedsUpdate;
pub const markPaintForNode = dom.markPaintForNode;
pub const markPaintForElement = dom.markPaintForElement;
pub const dirtyStyleForElement = dom.dirtyStyleForElement;
pub const dirtyStyleSubtree = dom.dirtyStyleSubtree;
pub const clearStyleInvalidations = dom.clearStyleInvalidations;

pub const removeCssAnimationTracks = style_module.removeCssAnimationTracks;
pub const finishCssAnimationTracks = style_module.finishCssAnimationTracks;
pub const StylePassStats = style_module.StylePassStats;
pub const style = style_module.style;
pub const styleWithStats = style_module.styleWithStats;
pub const styleWithKeyframes = style_module.styleWithKeyframes;

pub const treeToList = dom.treeToList;
pub const collectInlineStyleText = dom.collectInlineStyleText;
pub const collectDocumentTitle = dom.collectDocumentTitle;
pub const writeStyledPretty = dom.writeStyledPretty;
