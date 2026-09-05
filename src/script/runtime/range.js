// Live DOM Range state and boundary/content algorithms for one document Realm.
// Only JavaScript Node wrappers cross the synchronous host boundary;
// native DOM storage and its mutation transactions remain owned by __native.

var ACTIVE_RANGES = [];
function adjustRangesForRemoval(parent, child, index) {
  for (var rangeIndex = 0; rangeIndex < ACTIVE_RANGES.length; rangeIndex++) {
    var range = ACTIVE_RANGES[rangeIndex];
    ['start', 'end'].forEach(function(side) {
      var container = range[side + 'Container'], offset = range[side + 'Offset'];
      if (container === child || isAncestorNode(child, container)) {
        range[side + 'Container'] = parent; range[side + 'Offset'] = index;
      } else if (container === parent && offset > index) {
        range[side + 'Offset'] = offset - 1;
      }
    });
  }
}

// Compare DOM positions, not rendered caret locations: (parent, childIndex)
// is strictly before every position inside that child, including offset zero.
// Callers must establish a common root before comparing points.
function compareRangePoints(aNode, aOffset, bNode, bOffset) {
  if (aNode === bNode) return aOffset < bOffset ? -1 : aOffset > bOffset ? 1 : 0;
  if (isAncestorNode(aNode, bNode)) {
    var child = bNode;
    while (nodeParentForRange(child) !== aNode) child = nodeParentForRange(child);
    var index = nodeChildrenForRange(aNode).indexOf(child);
    return aOffset <= index ? -1 : 1;
  }
  if (isAncestorNode(bNode, aNode)) {
    var child2 = aNode;
    while (nodeParentForRange(child2) !== bNode) child2 = nodeParentForRange(child2);
    var index2 = nodeChildrenForRange(bNode).indexOf(child2);
    return index2 < bOffset ? -1 : 1;
  }
  var aPath = [], bPath = [], current = aNode;
  while (current) { aPath.unshift(current); current = nodeParentForRange(current); }
  current = bNode;
  while (current) { bPath.unshift(current); current = nodeParentForRange(current); }
  var common = 0;
  while (common < aPath.length && common < bPath.length && aPath[common] === bPath[common]) common++;
  if (!common) throw domException('WrongDocumentError');
  var parent = aPath[common - 1];
  var ai = nodeChildrenForRange(parent).indexOf(aPath[common]);
  var bi = nodeChildrenForRange(parent).indexOf(bPath[common]);
  return ai < bi ? -1 : ai > bi ? 1 : 0;
}
function rangeNodeStart(node) {
  var parent = nodeParentForRange(node);
  return parent ? { node: parent, offset: nodeIndexInParent(node) } : { node: node, offset: 0 };
}
function rangeNodeEnd(node) {
  var parent = nodeParentForRange(node);
  return parent ? { node: parent, offset: nodeIndexInParent(node) + 1 } : { node: node, offset: nodeChildrenForRange(node).length };
}
function rangeIntersects(range, node) {
  if (compareRoot(range.startContainer) !== compareRoot(node)) return false;
  var start = rangeNodeStart(node), end = rangeNodeEnd(node);
  return compareRangePoints(range.endContainer, range.endOffset, start.node, start.offset) > 0 &&
    compareRangePoints(range.startContainer, range.startOffset, end.node, end.offset) < 0;
}
function rangeFullyContains(range, node) {
  if (compareRoot(range.startContainer) !== compareRoot(node)) return false;
  var start = rangeNodeStart(node), end = rangeNodeEnd(node);
  return compareRangePoints(range.startContainer, range.startOffset, start.node, start.offset) <= 0 &&
    compareRangePoints(range.endContainer, range.endOffset, end.node, end.offset) >= 0;
}
function rangeOffsetLimit(node) {
  if (!node) return 0;
  if (node.nodeType === Node.TEXT_NODE || node.nodeType === Node.COMMENT_NODE ||
      node.nodeType === Node.CDATA_SECTION_NODE || node.nodeType === Node.PROCESSING_INSTRUCTION_NODE)
    return (node.data || '').length;
  return nodeChildrenForRange(node).length;
}
function checkedRangeOffset(node, offset) {
  if (node.nodeType === Node.DOCUMENT_TYPE_NODE) throw domException('InvalidNodeTypeError');
  if (offset > rangeOffsetLimit(node)) throw domException('IndexSizeError');
  return offset;
}
function checkedRangeNode(node) {
  if (!node || !DOM_NODE_BRAND.has(node))
    throw new TypeError('Argument is not a Node');
  return node;
}
function checkedRange(range) {
  if (!range || !RANGE_BRAND.has(range)) throw new TypeError('Receiver is not a Range');
  return range;
}
function rangePointArguments(node, offset, count) {
  if (count < 2) throw new TypeError('A Node and offset are required');
  checkedRangeNode(node);
  // Web IDL unsigned long: truncation/modulo, NaN and infinities become zero.
  // Unary plus (unlike Number()) rejects BigInt as well as Symbol.
  return (+offset) >>> 0;
}
function setRangeBoundary(range, node, offset, start) {
  checkedRangeOffset(node, offset);
  // Stage all validation before publishing either endpoint. A different root
  // is valid here, but must collapse the range into the new tree.
  var otherNode = start ? range.endContainer : range.startContainer;
  var otherOffset = start ? range.endOffset : range.startOffset;
  var collapse = compareRoot(node) !== compareRoot(otherNode);
  if (!collapse) {
    var order = compareRangePoints(node, offset, otherNode, otherOffset);
    collapse = start ? order > 0 : order < 0;
  }
  if (start || collapse) { range.startContainer = node; range.startOffset = offset; }
  if (!start || collapse) { range.endContainer = node; range.endOffset = offset; }
}
function setRangeAroundNode(range, node, start, after) {
  checkedRange(range);
  checkedRangeNode(node);
  var parent = nodeParentForRange(node);
  if (!parent) throw domException('InvalidNodeTypeError');
  setRangeBoundary(range, parent, nodeIndexInParent(node) + (after ? 1 : 0), start);
}
function createRangeForDocument(doc) {
  var range = new Range();
  range.startContainer = doc; range.endContainer = doc;
  return range;
}
function hasPartiallyContainedElement(range, node, isRoot) {
  var children = nodeChildrenForRange(node);
  for (var i = 0; i < children.length; i++) {
    var child = children[i];
    if (child.nodeType === Node.ELEMENT_NODE && rangeIntersects(range, child) && !rangeFullyContains(range, child)) return true;
    if (hasPartiallyContainedElement(range, child, false)) return true;
  }
  return false;
}
function shallowCloneNode(node) {
  if (node.__synthetic) return makeSyntheticNode(node.nodeType, node.nodeName, node.data);
  if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.data || '');
  var clone = document.createElement(node.tagName || node.nodeName || 'div');
  // Copy the attributes most commonly observed by DOM compatibility tests.
  ['id', 'class', 'name', 'value', 'type', 'href', 'style'].forEach(function(name) {
    var value = node.getAttribute && node.getAttribute(name); if (value !== null) clone.setAttribute(name, value);
  });
  return clone;
}
function cloneRangeNode(range, node, extract, fragment) {
  if (!rangeIntersects(range, node)) {
    // A range ending at an element's start still contributes an empty clone
    // of that element when the boundary crosses from a previous sibling.
    return range.endContainer === node && range.endOffset === 0 ? shallowCloneNode(node) : null;
  }
  if (rangeFullyContains(range, node)) return node.cloneNode ? node.cloneNode(true) : shallowCloneNode(node);
  if (node.nodeType === Node.TEXT_NODE) {
    var start = range.startContainer === node ? range.startOffset : 0;
    var end = range.endContainer === node ? range.endOffset : (node.data || '').length;
    if (end <= start) return null;
    return document.createTextNode((node.data || '').slice(start, end));
  }
  var clone = shallowCloneNode(node);
  var children = nodeChildrenForRange(node);
  for (var i = 0; i < children.length; i++) {
    var child = children[i];
    var selected = cloneRangeNode(range, child, extract, fragment);
    if (selected) clone.appendChild(selected);
    if (extract && rangeFullyContains(range, child) && child.parentNode && child.parentNode.removeChild) {
      child.parentNode.removeChild(child);
      if (selected && selected.__original) selected = selected.__original;
    } else if (extract && child.nodeType === Node.TEXT_NODE && selected && child.parentNode) {
      var from = range.startContainer === child ? range.startOffset : 0;
      var to = range.endContainer === child ? range.endOffset : (child.data || '').length;
      __native.setNodeData(child.handle, (child.data || '').slice(0, from) + (child.data || '').slice(to));
    }
  }
  return clone.childNodes.length ? clone : (rangeIntersects(range, node) ? clone : null);
}
function extractRangeNode(range, node) {
  if (!rangeIntersects(range, node)) {
    // An element whose start is exactly the range end contributes an empty
    // clone to extractContents (the surrounding structure is preserved).
    if (range.endContainer === node && range.endOffset === 0) return shallowCloneNode(node);
    return null;
  }
  if (rangeFullyContains(range, node)) {
    if (node.parentNode && node.parentNode.removeChild) node.parentNode.removeChild(node);
    return node;
  }
  if (node.nodeType === Node.TEXT_NODE) {
    var start = range.startContainer === node ? range.startOffset : 0;
    var end = range.endContainer === node ? range.endOffset : (node.data || '').length;
    if (end <= start) return null;
    var selected = (node.data || '').slice(start, end);
    if (node.handle) __native.setNodeData(node.handle, (node.data || '').slice(0, start) + (node.data || '').slice(end));
    else { node.data = (node.data || '').slice(0, start) + (node.data || '').slice(end); node.textContent = node.data; }
    return document.createTextNode(selected);
  }
  var clone = shallowCloneNode(node);
  var children = nodeChildrenForRange(node).slice();
  for (var i = 0; i < children.length; i++) {
    var child = children[i];
    if (!rangeIntersects(range, child)) continue;
    var extracted = extractRangeNode(range, child);
    if (extracted) clone.appendChild(extracted);
  }
  return clone.childNodes.length || (range.endContainer === node && range.endOffset === 0) ? clone : null;
}

var RANGE_BRAND = new WeakSet();
function Range() {
  if (!new.target) throw new TypeError('Range requires new');
  this.startContainer = document; this.startOffset = 0;
  this.endContainer = document; this.endOffset = 0;
  RANGE_BRAND.add(this);
  ACTIVE_RANGES.push(this);
}
Object.defineProperty(Range.prototype, 'collapsed', { get: function() {
  return this.startContainer === this.endContainer && this.startOffset === this.endOffset;
}});
Object.defineProperty(Range.prototype, 'commonAncestorContainer', { get: function() {
  var a = this.startContainer, b = this.endContainer;
  if (isAncestorNode(a, b)) return a; if (isAncestorNode(b, a)) return b;
  var path = [], current = a; while (current) { path.push(current); current = nodeParentForRange(current); }
  current = b; while (current) { if (path.indexOf(current) >= 0) return current; current = nodeParentForRange(current); }
  return document;
}});
Range.prototype.setStart = function(node, offset) {
  checkedRange(this);
  offset = rangePointArguments(node, offset, arguments.length);
  setRangeBoundary(this, node, offset, true);
};
Range.prototype.setEnd = function(node, offset) {
  checkedRange(this);
  offset = rangePointArguments(node, offset, arguments.length);
  setRangeBoundary(this, node, offset, false);
};
Range.prototype.setStartBefore = function(node) { setRangeAroundNode(this, node, true, false); };
Range.prototype.setStartAfter = function(node) { setRangeAroundNode(this, node, true, true); };
Range.prototype.setEndBefore = function(node) { setRangeAroundNode(this, node, false, false); };
Range.prototype.setEndAfter = function(node) { setRangeAroundNode(this, node, false, true); };
Range.prototype.selectNode = function(node) {
  checkedRange(this);
  checkedRangeNode(node);
  var parent = nodeParentForRange(node);
  if (!parent) throw domException('InvalidNodeTypeError');
  var index = nodeIndexInParent(node);
  this.startContainer = parent; this.startOffset = index;
  this.endContainer = parent; this.endOffset = index + 1;
};
Range.prototype.selectNodeContents = function(node) {
  checkedRange(this);
  checkedRangeNode(node);
  checkedRangeOffset(node, 0);
  var length = rangeOffsetLimit(node);
  this.startContainer = node; this.startOffset = 0;
  this.endContainer = node; this.endOffset = length;
};
Range.prototype.collapse = function(toStart) { if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; } else { this.startContainer = this.endContainer; this.startOffset = this.endOffset; } };
Range.prototype.cloneRange = function() { var r = new Range(); r.startContainer = this.startContainer; r.startOffset = this.startOffset; r.endContainer = this.endContainer; r.endOffset = this.endOffset; return r; };
// Legacy no-op: detach must not stop mutation adjustment or disable queries.
Range.prototype.detach = function() { checkedRange(this); };
Range.prototype.cloneContents = function() { var f = makeDocumentFragment(); var root = this.commonAncestorContainer; if (root.nodeType === Node.TEXT_NODE) { var start = this.startContainer === root ? this.startOffset : 0; var end = this.endContainer === root ? this.endOffset : (root.data || '').length; if (end > start) f.appendChild(document.createTextNode((root.data || '').slice(start, end))); return f; } var children = nodeChildrenForRange(root); for (var i = 0; i < children.length; i++) { var c = cloneRangeNode(this, children[i], false, f); if (c) f.appendChild(c); } return f; };
Range.prototype.extractContents = function() { var f = makeDocumentFragment(); var root = this.commonAncestorContainer; if (root.nodeType === Node.TEXT_NODE) { var start = this.startContainer === root ? this.startOffset : 0; var end = this.endContainer === root ? this.endOffset : (root.data || '').length; if (end > start) { f.appendChild(document.createTextNode((root.data || '').slice(start, end))); if (root.handle) __native.setNodeData(root.handle, (root.data || '').slice(0, start) + (root.data || '').slice(end)); } this.collapse(true); return f; } var children = nodeChildrenForRange(root).slice(); for (var i = 0; i < children.length; i++) { var extracted = extractRangeNode(this, children[i]); if (extracted) f.appendChild(extracted); } this.collapse(true); return f; };
Range.prototype.deleteContents = function() { this.extractContents(); };
Range.prototype.insertNode = function(node) { var container = this.startContainer; if (container.nodeType === Node.TEXT_NODE) { var parent = nodeParentForRange(container); if (!parent) return; var splitOffset = this.startOffset, before = container.data.slice(0, splitOffset), after = container.data.slice(splitOffset); __native.setNodeData(container.handle, before); var tail = document.createTextNode(after); var reference = container.nextSibling; if (node !== reference) parent.insertBefore(node, reference); var afterNode = node.nextSibling; if (afterNode) parent.insertBefore(tail, afterNode); else parent.appendChild(tail); if (this.startContainer === container) { if (this.startOffset === splitOffset) { this.startContainer = node; this.startOffset = 0; } else if (this.startOffset > splitOffset) { this.startContainer = tail; this.startOffset -= splitOffset; } } if (this.endContainer === container) { if (this.endOffset > splitOffset) { this.endContainer = tail; this.endOffset -= splitOffset; } else if (this.endOffset === splitOffset) { this.endContainer = node; this.endOffset = 0; } } return; } var children = nodeChildrenForRange(container), reference = children[this.startOffset] || null; if (reference) container.insertBefore(node, reference); else container.appendChild(node); };
Range.prototype.surroundContents = function(node) {
  if (this.startContainer && this.startContainer.nodeType === Node.COMMENT_NODE || this.endContainer && this.endContainer.nodeType === Node.COMMENT_NODE) throw { code: 1 };
  if (this.commonAncestorContainer && this.commonAncestorContainer.nodeType === Node.DOCUMENT_NODE && !this.collapsed) throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
  if (hasPartiallyContainedElement(this, this.commonAncestorContainer, true)) throw { code: 1, BAD_BOUNDARYPOINTS_ERR: 1 };
  var f = this.extractContents(); node.appendChild(f); this.insertNode(node); this.selectNode(node);
};
Range.prototype.toString = function() { return this.cloneContents().textContent || ''; };
Range.prototype.compareBoundaryPoints = function(how, other) {
  checkedRange(this);
  if (arguments.length < 2) throw new TypeError('A comparison mode and Range are required');
  how = (+how) & 65535;
  checkedRange(other);
  if (how > 3) throw domException('NotSupportedError');
  if (compareRoot(this.startContainer) !== compareRoot(other.startContainer))
    throw domException('WrongDocumentError');
  var thisStart = how === 0 || how === 3;
  var otherStart = how === 0 || how === 1;
  return compareRangePoints(
    thisStart ? this.startContainer : this.endContainer,
    thisStart ? this.startOffset : this.endOffset,
    otherStart ? other.startContainer : other.endContainer,
    otherStart ? other.startOffset : other.endOffset);
};
Range.prototype.comparePoint = function(node, offset) {
  checkedRange(this);
  offset = rangePointArguments(node, offset, arguments.length);
  if (compareRoot(this.startContainer) !== compareRoot(node)) throw domException('WrongDocumentError');
  checkedRangeOffset(node, offset);
  if (compareRangePoints(node, offset, this.startContainer, this.startOffset) < 0) return -1;
  if (compareRangePoints(node, offset, this.endContainer, this.endOffset) > 0) return 1;
  return 0;
};
Range.prototype.isPointInRange = function(node, offset) {
  checkedRange(this);
  offset = rangePointArguments(node, offset, arguments.length);
  if (compareRoot(this.startContainer) !== compareRoot(node)) return false;
  checkedRangeOffset(node, offset);
  return compareRangePoints(node, offset, this.startContainer, this.startOffset) >= 0 &&
    compareRangePoints(node, offset, this.endContainer, this.endOffset) <= 0;
};
Range.prototype.intersectsNode = function(node) {
  checkedRange(this);
  checkedRangeNode(node);
  if (compareRoot(this.startContainer) !== compareRoot(node)) return false;
  if (!nodeParentForRange(node)) return true;
  return rangeIntersects(this, node);
};
Range.prototype.START_TO_START = 0; Range.prototype.START_TO_END = 1; Range.prototype.END_TO_END = 2; Range.prototype.END_TO_START = 3;
Range.START_TO_START = 0; Range.START_TO_END = 1; Range.END_TO_END = 2; Range.END_TO_START = 3;
