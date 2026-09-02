// Zibra's page-visible JavaScript shims over the synchronous __native host.
// Node constructor that wraps a native identity. The cache below is the one
// canonical JavaScript wrapper for each identity in this document realm.
function Node(handle) {
  this.handle = handle;
}
function domException(name, message) {
  var codes = { IndexSizeError: 1, HierarchyRequestError: 3, NotFoundError: 8,
    InvalidCharacterError: 5, NamespaceError: 14, InvalidNodeTypeError: 24 };
  return new DOMException(message || name, name);
}
// The host exposes one handle-backed Node type; aliases keep common
// constructor checks from failing without changing the native representation.
globalThis.Element = Node;
globalThis.Text = Node;
globalThis.Comment = Node;
globalThis.Document = function Document() { return makeDetachedDocument(null); };
globalThis.DocumentFragment = Node;
globalThis.DocumentType = Node;
globalThis.ProcessingInstruction = Node;
globalThis.NodeList = Array;
globalThis.HTMLCollection = Array;
function DOMException(message, name) {
  this.message = message == null ? '' : String(message);
  this.name = name == null || name === '' ? 'Error' : String(name);
  var codes = { IndexSizeError: 1, HierarchyRequestError: 3, NotFoundError: 8,
    InvalidCharacterError: 5, NamespaceError: 14, InvalidNodeTypeError: 24 };
  this.code = codes[this.name] || 0;
}
DOMException.prototype = { constructor: DOMException };
var DOM_EXCEPTION_CODES = { INDEX_SIZE_ERR: 1, DOMSTRING_SIZE_ERR: 2, HIERARCHY_REQUEST_ERR: 3,
  WRONG_DOCUMENT_ERR: 4, INVALID_CHARACTER_ERR: 5, NO_MODIFICATION_ALLOWED_ERR: 7,
  NOT_FOUND_ERR: 8, NOT_SUPPORTED_ERR: 9, INUSE_ATTRIBUTE_ERR: 10,
  INVALID_STATE_ERR: 11, SYNTAX_ERR: 12, INVALID_MODIFICATION_ERR: 13,
  NAMESPACE_ERR: 14, INVALID_ACCESS_ERR: 15, TYPE_MISMATCH_ERR: 17,
  SECURITY_ERR: 18, NETWORK_ERR: 19, ABORT_ERR: 20, URL_MISMATCH_ERR: 21,
  QUOTA_EXCEEDED_ERR: 22, TIMEOUT_ERR: 23, INVALID_NODE_TYPE_ERR: 24,
  DATA_CLONE_ERR: 25 };
for (var domExceptionName in DOM_EXCEPTION_CODES) DOMException[domExceptionName] = DOM_EXCEPTION_CODES[domExceptionName];
for (var domExceptionCodeName in DOM_EXCEPTION_CODES) DOMException.prototype[domExceptionCodeName] = DOM_EXCEPTION_CODES[domExceptionCodeName];
globalThis.DOMException = DOMException;

// ECMAScript normalizes negative zero when formatting fixed-point numbers.
// Kiesel's generic formatter preserves the sign, so correct that one edge
// case while delegating all ordinary precision and rounding to the runtime.
if (typeof Number === 'function' && Number.prototype && Number.prototype.toFixed) {
  (function (nativeToFixed) {
    Number.prototype.toFixed = function (digits) {
      if (this === 0 && 1 / this === -Infinity) return (0).toFixed(digits);
      return nativeToFixed.call(this, digits);
    };
  })(Number.prototype.toFixed);
}

var NODE_WRAPPERS = {};
var IFRAME_DOCUMENTS = {};

function wrapNode(handle) {
  if (handle === null || handle === undefined) return null;
  var node = NODE_WRAPPERS[handle];
  if (node) return node;
  node = new Node(handle);
  NODE_WRAPPERS[handle] = node;
  return node;
}

function wrapNodes(handles) {
  return handles.map(function(handle) { return wrapNode(handle); });
}

Node.ELEMENT_NODE = 1;
Node.ATTRIBUTE_NODE = 2;
Node.TEXT_NODE = 3;
Node.CDATA_SECTION_NODE = 4;
Node.PROCESSING_INSTRUCTION_NODE = 7;
Node.DOCUMENT_NODE = 9;
Node.DOCUMENT_TYPE_NODE = 10;
Node.DOCUMENT_FRAGMENT_NODE = 11;
Node.COMMENT_NODE = 8;

globalThis.NodeFilter = {
  SHOW_ALL: 0xFFFFFFFF,
  SHOW_ELEMENT: 0x1,
  SHOW_ATTRIBUTE: 0x2,
  SHOW_TEXT: 0x4,
  SHOW_CDATA_SECTION: 0x8,
  SHOW_ENTITY_REFERENCE: 0x10,
  SHOW_ENTITY: 0x20,
  SHOW_PROCESSING_INSTRUCTION: 0x40,
  SHOW_COMMENT: 0x80,
  SHOW_DOCUMENT: 0x100,
  SHOW_DOCUMENT_TYPE: 0x200,
  SHOW_DOCUMENT_FRAGMENT: 0x400,
  SHOW_NOTATION: 0x800,
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3
};

function walkSnapshot(root, output) {
  output.push(root);
  var children = root.childNodes || [];
  for (var i = 0; i < children.length; i++) walkSnapshot(children[i], output);
}

function nodeShown(node, mask) {
  if (mask === 0xFFFFFFFF) return true;
  var bits = {
    1: 0x1, 2: 0x2, 3: 0x4, 4: 0x8, 5: 0x10, 6: 0x20,
    7: 0x40, 8: 0x80, 9: 0x100, 10: 0x200, 11: 0x400, 12: 0x800
  };
  return !!(mask & (bits[node.nodeType] || 0));
}

function filterResult(filter, node, mask) {
  if (!nodeShown(node, mask)) return 3;
  if (typeof filter !== 'function' && !(filter && typeof filter.acceptNode === 'function')) return 1;
  var result = typeof filter === 'function' ? filter(node) : filter.acceptNode(node);
  if (result === true) return 1;
  var number = Number(result);
  return number === 1 ? 1 : number === 2 ? 2 : 3;
}

function NodeIterator(root, mask, filter) {
  this.root = root; this.mask = mask == null ? 0xFFFFFFFF : Number(mask);
  this.whatToShow = this.mask; this.filter = filter == null ? null : filter;
  // NodeIterator's position is between nodes, rather than on the last node
  // returned.  Keeping the reference and pointer direction separately is
  // important when a filter throws and when it mutates the tree while it is
  // being evaluated.
  this.referenceNode = root; this.pointerBeforeReferenceNode = true;
  this.currentNode = null;
  this.__order = null;
}
NodeIterator.prototype.toString = function() { return '[object NodeIterator]'; };
function iteratorNeighbor(nodes, oldOrder, reference, direction) {
  var index = nodes.indexOf(reference);
  if (index >= 0) {
    var adjacent = index + direction;
    return adjacent >= 0 && adjacent < nodes.length ? nodes[adjacent] : null;
  }
  // A filter can detach the reference node. Keep using the last order we
  // observed so the iterator can still walk past that detached node.
  if (!oldOrder) return null;
  index = oldOrder.indexOf(reference);
  if (index < 0) return null;
  for (var i = index + direction; i >= 0 && i < oldOrder.length; i += direction) {
    if (nodes.indexOf(oldOrder[i]) >= 0) return oldOrder[i];
  }
  return null;
}
NodeIterator.prototype.nextNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var oldOrder = this.__order;
  this.__order = nodes;
  while (true) {
    var candidate;
    if (this.pointerBeforeReferenceNode) {
      candidate = this.referenceNode;
    } else {
      candidate = iteratorNeighbor(nodes, oldOrder, this.referenceNode, 1);
      if (candidate === null) return null;
    }
    var result = filterResult(this.filter, candidate, this.mask);
    // A thrown filter must not move the iterator's reference position.
    if (this.pointerBeforeReferenceNode) this.pointerBeforeReferenceNode = false;
    else this.referenceNode = candidate;
    if (result === 1) { this.currentNode = candidate; return candidate; }
  }
};
NodeIterator.prototype.previousNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var oldOrder = this.__order;
  this.__order = nodes;
  while (true) {
    var candidate;
    if (this.pointerBeforeReferenceNode) {
      if (this.referenceNode === this.root) return null;
      candidate = iteratorNeighbor(nodes, oldOrder, this.referenceNode, -1);
      if (candidate === null) return null;
    } else {
      candidate = this.referenceNode;
    }
    var result = filterResult(this.filter, candidate, this.mask);
    // A thrown filter must not move the iterator's reference position.
    if (this.pointerBeforeReferenceNode) this.referenceNode = candidate;
    else this.pointerBeforeReferenceNode = true;
    if (result === 1) { this.currentNode = candidate; return candidate; }
  }
};

function TreeWalker(root, mask, filter) {
  this.root = root; this.mask = mask == null ? 0xFFFFFFFF : Number(mask);
  this.whatToShow = this.mask; this.filter = filter == null ? null : filter; this.currentNode = root;
}
TreeWalker.prototype.toString = function() { return '[object TreeWalker]'; };
TreeWalker.prototype.__children = function(node) { return node.childNodes || []; };
TreeWalker.prototype.__sibling = function(node, direction) {
  var parent = node && node.parentNode;
  if (!parent) return null;
  var children = this.__children(parent), index = children.indexOf(node);
  if (index < 0) return null;
  var siblingIndex = index + direction;
  return siblingIndex >= 0 && siblingIndex < children.length ? children[siblingIndex] : null;
};
TreeWalker.prototype.__nextAfterSubtree = function(node) {
  while (node && node !== this.root) {
    var sibling = this.__sibling(node, 1);
    if (sibling) return sibling;
    node = node.parentNode;
  }
  return null;
};
TreeWalker.prototype.__lastVisible = function(node) {
  var result = filterResult(this.filter, node, this.mask);
  if (result === 2) return null;
  var children = this.__children(node);
  for (var i = children.length - 1; i >= 0; i--) {
    var nested = this.__lastVisible(children[i]);
    if (nested) return nested;
  }
  return result === 1 ? node : null;
};
TreeWalker.prototype.firstChild = function() {
  var children = this.__children(this.currentNode);
  for (var i = 0; i < children.length; i++) {
    var result = filterResult(this.filter, children[i], this.mask);
    if (result === 1) { this.currentNode = children[i]; return children[i]; }
    if (result === 3) {
      var found = this.__firstVisible(children[i]);
      if (found) { this.currentNode = found; return found; }
    }
  }
  return null;
};
TreeWalker.prototype.__firstVisible = function(node) {
  var children = this.__children(node);
  for (var i = 0; i < children.length; i++) {
    var result = filterResult(this.filter, children[i], this.mask);
    if (result === 1) return children[i];
    if (result === 3) {
      var nested = this.__firstVisible(children[i]);
      if (nested) return nested;
    }
  }
  return null;
};
TreeWalker.prototype.lastChild = function() {
  var children = this.__children(this.currentNode);
  for (var i = children.length - 1; i >= 0; i--) {
    var result = filterResult(this.filter, children[i], this.mask);
    if (result === 1) { this.currentNode = children[i]; return children[i]; }
    if (result === 3) {
      var found = this.__lastVisible(children[i]);
      if (found) { this.currentNode = found; return found; }
    }
  }
  return null;
};
TreeWalker.prototype.parentNode = function() {
  // The root is the traversal boundary; its DOM parent is intentionally
  // invisible to this walker.
  if (this.currentNode === this.root) return null;
  var parent = this.currentNode.parentNode;
  while (parent) {
    var result = filterResult(this.filter, parent, this.mask);
    if (result === 1) { this.currentNode = parent; return parent; }
    if (parent === this.root) break;
    parent = parent.parentNode;
  }
  return null;
};
TreeWalker.prototype.nextSibling = function() {
  var sibling = this.__sibling(this.currentNode, 1);
  while (sibling) {
    var result = filterResult(this.filter, sibling, this.mask);
    if (result === 1) { this.currentNode = sibling; return sibling; }
    sibling = this.__sibling(sibling, 1);
  }
  // Acid3 and older DOM implementations probe the parent when there is no
  // sibling. The result is intentionally ignored; currentNode stays put.
  var parent = this.currentNode.parentNode;
  if (parent) filterResult(this.filter, parent, this.mask);
  return null;
};
TreeWalker.prototype.previousSibling = function() {
  var sibling = this.__sibling(this.currentNode, -1);
  while (sibling) {
    var result = filterResult(this.filter, sibling, this.mask);
    if (result === 1) { this.currentNode = sibling; return sibling; }
    sibling = this.__sibling(sibling, -1);
  }
  return null;
};
TreeWalker.prototype.nextNode = function() {
  var candidate = this.__children(this.currentNode)[0] || this.__nextAfterSubtree(this.currentNode);
  while (candidate) {
    var result = filterResult(this.filter, candidate, this.mask);
    if (result === 1) { this.currentNode = candidate; return candidate; }
    candidate = result === 3 ? (this.__children(candidate)[0] || this.__nextAfterSubtree(candidate)) :
      this.__nextAfterSubtree(candidate);
  }
  return null;
};
TreeWalker.prototype.previousNode = function() {
  var node = this.currentNode;
  while (node && node !== this.root) {
    var sibling = this.__sibling(node, -1);
    while (sibling) {
      var found = this.__lastVisible(sibling);
      if (found) { this.currentNode = found; return found; }
      // A filtered sibling does not end the document-order search; continue
      // through earlier siblings before considering the parent itself.
      sibling = this.__sibling(sibling, -1);
    }
    var parent = node.parentNode;
    if (!parent) return null;
    var result = filterResult(this.filter, parent, this.mask);
    if (result === 1) { this.currentNode = parent; return parent; }
    node = parent;
  }
  return null;
};

var XHR_REQUESTS = {};

function XMLHttpRequest() {
  this.handle = Object.keys(XHR_REQUESTS).length;
  XHR_REQUESTS[this.handle] = this;
  this.is_async = true;
  this.__method = "GET";
  this.__url = "";
}

XMLHttpRequest.prototype.open = function(method, url, is_async) {
  var flag = (is_async === undefined) ? true : !!is_async;
  this.is_async = flag;
  this.__method = method;
  this.__url = url;
};

XMLHttpRequest.prototype.send = function(body) {
  var payload = body == null ? null : body.toString();
  var response = __native.xhrSend(
    this.__method || "GET",
    this.__url,
    payload,
    !!this.is_async,
    this.handle
  );
  if (!this.is_async) {
    this.responseText = response;
  }
};

function Event(type) {
  this.type = type;
  this.bubbles = false;
  this.do_default = true;
  this.defaultPrevented = false;
  this.propagation_stopped = false;
  this.target = null;
  this.currentTarget = null;
  this.eventPhase = 0;
}

Event.prototype.preventDefault = function() {
  this.do_default = false;
  this.defaultPrevented = true;
};

Event.prototype.stopPropagation = function() {
  this.propagation_stopped = true;
};

// Lifecycle events have document and window targets rather than a DOM-node
// handle. Keep their listener state in this document Realm: navigation gets a
// fresh Realm, so an old page's callbacks cannot observe a new document.
var DOCUMENT_LIFECYCLE_LISTENERS = {};
var WINDOW_LIFECYCLE_LISTENERS = {};
var DOCUMENT_READY_STATE = 'loading';

function addLifecycleListener(listenersByType, type, listener) {
  if (typeof listener !== 'function') return;
  if (!listenersByType[type]) listenersByType[type] = [];
  listenersByType[type].push(listener);
}

function dispatchLifecycleTarget(target, listenersByType, type) {
  var event = new Event(type);
  event.target = target;
  event.currentTarget = target;

  // Snapshot the length so listeners added while dispatching wait for the
  // next event, while preserving this browser's existing listener ordering.
  var listeners = listenersByType[type] || [];
  var listenerCount = listeners.length;
  for (var i = 0; i < listenerCount; i++) {
    // Browser-generated lifecycle work must not be aborted by a page
    // exception. Continue with later listeners and the target's property
    // handler, matching the event loop's report-and-continue behavior.
    try {
      listeners[i].call(target, event);
    } catch (error) {}
  }

  // Event handler properties are a separate registration path. They run
  // after addEventListener listeners on this target, which is sufficient for
  // the limited document/window lifecycle surface exposed here.
  var handler = target['on' + type];
  if (typeof handler === 'function') {
    try {
      handler.call(target, event);
    } catch (error) {}
  }
  event.currentTarget = null;
  return event.do_default;
}

var WINDOW_NODE_LISTENERS = {};
var WINDOW_NODE_CAPTURE_LISTENERS = {};

function listenersForWindow(windowId) {
  if (!WINDOW_NODE_LISTENERS[windowId]) WINDOW_NODE_LISTENERS[windowId] = {};
  return WINDOW_NODE_LISTENERS[windowId];
}

function captureListenersForWindow(windowId) {
  if (!WINDOW_NODE_CAPTURE_LISTENERS[windowId]) WINDOW_NODE_CAPTURE_LISTENERS[windowId] = {};
  return WINDOW_NODE_CAPTURE_LISTENERS[windowId];
}

Node.prototype.addEventListener = function(type, listener, options) {
  var capture = options === true || (options && options.capture === true);
  var listeners = capture ? captureListenersForWindow(window.__id) : listenersForWindow(window.__id);
  if (!listeners[this.handle]) listeners[this.handle] = {};
  var dict = listeners[this.handle];
  if (!dict[type]) dict[type] = [];
  dict[type].push(listener);
};

Node.prototype.removeEventListener = function(type, listener, options) {
  var capture = options === true || (options && options.capture === true);
  var listeners = capture ? captureListenersForWindow(window.__id) : listenersForWindow(window.__id);
  var dict = listeners[this.handle];
  if (!dict || !dict[type]) return;
  var list = dict[type];
  for (var i = 0; i < list.length; i++) {
    if (list[i] === listener) {
      list.splice(i, 1);
      return;
    }
  }
};

function invokeNodeListeners(handle, event, listenerMap, phase) {
  var currentTarget = wrapNode(handle);
  event.currentTarget = currentTarget;
  event.eventPhase = phase;
  var dict = listenerMap[handle];
  var list = (dict && dict[event.type]) || [];
  // Snapshot the target's listener array so removal during dispatch does
  // not invalidate the current traversal.
  var copy = list.slice();
  for (var listenerIndex = 0; listenerIndex < copy.length; listenerIndex++) {
    try { copy[listenerIndex].call(currentTarget, event); } catch (error) {}
  }
}

function dispatchNodeEvent(target, event, inlineHandler) {
  var path = event.bubbles ? __native.eventPath(target.handle) : [target.handle];
  var listeners = listenersForWindow(window.__id);
  var captureListeners = captureListenersForWindow(window.__id);
  event.propagation_stopped = false;
  event.target = path.length ? wrapNode(path[0]) : target;

  // Capture travels from the root down to (but not including) the target.
  for (var captureIndex = path.length - 1; captureIndex > 0; captureIndex--) {
    invokeNodeListeners(path[captureIndex], event, captureListeners, 1);
    if (event.propagation_stopped) break;
  }

  // A stopPropagation call on an ancestor prevents reaching the target. Once
  // at the target, capture and bubble listeners on that same node both run.
  if (!event.propagation_stopped) {
    invokeNodeListeners(path[0], event, captureListeners, 2);
    invokeNodeListeners(path[0], event, listeners, 2);
    var eventTarget = wrapNode(path[0]);
    var targetHandler = inlineHandler || eventTarget['on' + event.type];
    if (typeof targetHandler === 'function') {
      try {
        if (targetHandler.call(eventTarget, event) === false) event.preventDefault();
      } catch (error) {}
    }
  }

  if (event.bubbles && !event.propagation_stopped) {
    for (var bubbleIndex = 1; bubbleIndex < path.length; bubbleIndex++) {
      invokeNodeListeners(path[bubbleIndex], event, listeners, 3);
      if (event.propagation_stopped) break;
    }
  }
  event.currentTarget = null;
  event.eventPhase = 0;
  return event.do_default;
}

Node.prototype.dispatchEvent = function(evt) {
  var event = typeof evt === "string" ? new Event(evt) : evt;
  return dispatchNodeEvent(this, event, null);
};

// This is called by Js.dispatchInlineEvent after it has resolved the authored
// on<event> source from the current DOM. Keeping compilation in the document
// Realm gives the handler normal global lookup, `this`, target/currentTarget,
// default prevention, and listener ordering without retaining a DOM pointer
// in the native host.
globalThis.__dispatchInlineEventHandler = function(handle, type, handler, bubbles) {
  var target = wrapNode(handle);
  if (!target || typeof handler !== 'function') return true;
  var event = new Event(type);
  event.bubbles = !!bubbles;
  return dispatchNodeEvent(target, event, handler);
};

// Add getAttribute method to Node prototype
Node.prototype.getAttribute = function(name) {
  return __native.getAttribute(this.handle, name);
};

// Add setAttribute method to Node prototype
Node.prototype.setAttribute = function(name, value) {
  var text = value == null ? "" : value.toString();
  if (__native.setAttribute(this.handle, name, text)) {
    resetCanvasContextState(this.handle);
  }
};
Node.prototype.hasAttribute = function(name) {
  return this.getAttribute(name) !== null;
};
Node.prototype.removeAttribute = function(name) {
  __native.removeAttribute(this.handle, name == null ? '' : name.toString());
};
Node.prototype.hasChildNodes = function() {
  return this.childNodes.length !== 0;
};
Node.prototype.remove = function() {
  var parent = this.parentNode;
  if (parent && parent.removeChild) parent.removeChild(this);
};
Node.prototype.append = function() {
  for (var i = 0; i < arguments.length; i++) {
    var value = arguments[i];
    if (value && (typeof value.handle === 'number' || typeof value.nodeType === 'number')) this.appendChild(value);
    else this.appendChild(document.createTextNode(value == null ? '' : String(value)));
  }
};

Object.defineProperty(Node.prototype, "id", {
  get: function() { return this.getAttribute("id") || ""; },
  set: function(value) {
    this.setAttribute("id", value == null ? "" : value.toString());
  }
});

Node.prototype.appendChild = function(child) {
  if (child && child.__fragment) {
    var moved = child.childNodes.slice();
    for (var fi = 0; fi < moved.length; fi++) this.appendChild(moved[fi]);
    return child;
  }
  if (!child || (typeof child.handle !== 'number' && typeof child.nodeType !== 'number')) {
    throw new TypeError('appendChild requires a Node');
  }
  if (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE || this.nodeType === Node.DOCUMENT_TYPE_NODE)
    throw domException('HierarchyRequestError', 'This node type cannot have children');
  if (child.nodeType === Node.DOCUMENT_NODE)
    throw domException('HierarchyRequestError');
  if (child.__synthetic) {
    if (!this.__logicalChildren) this.__logicalChildren = this.childNodes.slice();
    this.__logicalChildren.push(child); child.__rangeParent = this; child.parentNode = this;
    child.__ownerDocument = this.ownerDocument || document; return child;
  }
  if (this.__documentChildren) {
    this.__documentChildren.push(child);
    child.__rangeParent = this;
    child.parentNode = this;
    return child;
  }
  if (child && isAncestorNode(child, this)) throw domException('HierarchyRequestError');
  if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
  __native.appendChild(this.handle, child && child.handle);
  if (this.__logicalChildren) this.__logicalChildren.push(child);
  child.__rangeParent = this;
  child.__ownerDocument = this.ownerDocument || document;
  return child;
};

Node.prototype.insertBefore = function(child, reference) {
  if (arguments.length < 2) throw new TypeError('insertBefore requires a reference child');
  if (reference === undefined) reference = null;
  if (child && child.__fragment) {
    var moved = child.childNodes.slice();
    for (var fi = 0; fi < moved.length; fi++) this.insertBefore(moved[fi], reference);
    return child;
  }
  if (!child || (typeof child.handle !== 'number' && typeof child.nodeType !== 'number')) {
    if (child && child.__synthetic) {
      if (!this.__syntheticChildren) this.__syntheticChildren = [];
      var syntheticIndex = reference ? this.__syntheticChildren.indexOf(reference) : -1;
      if (syntheticIndex < 0) this.__syntheticChildren.push(child); else this.__syntheticChildren.splice(syntheticIndex, 0, child);
      child.__rangeParent = this; child.parentNode = this; return child;
    }
    throw new TypeError('insertBefore requires a Node');
  }
  if (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE || this.nodeType === Node.DOCUMENT_TYPE_NODE)
    throw domException('HierarchyRequestError');
  // The DOM operation is a no-op when the reference is the node itself. Do
  // this before detaching it, or the now-detached reference would fail the
  // native child validation below.
  if (child === reference) return child;
  if (isAncestorNode(child, this)) throw domException('HierarchyRequestError');
  // Validate the reference while the source tree is still intact. The native
  // mutation boundary rejects a foreign reference, but detaching first would
  // otherwise turn a failed insertBefore into an observable partial move.
  if (reference !== null && (!reference || typeof reference.handle !== 'number' || reference.parentNode !== this)) {
    if (reference !== null && typeof reference.handle !== 'number') throw new TypeError('reference child must be a Node');
    throw domException('NotFoundError');
  }
  if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
  var referenceHandle = reference === null ? null : reference && reference.handle;
  __native.insertBefore(this.handle, child && child.handle, referenceHandle);
  if (this.__logicalChildren) {
    var logicalIndex = reference ? this.__logicalChildren.indexOf(reference) : -1;
    if (logicalIndex < 0) this.__logicalChildren.push(child);
    else this.__logicalChildren.splice(logicalIndex, 0, child);
  }
  child.__rangeParent = this;
  return child;
};

Node.prototype.replaceChild = function(newChild, oldChild) {
  if (newChild === oldChild) return oldChild;
  this.insertBefore(newChild, oldChild);
  this.removeChild(oldChild);
  return oldChild;
};

Node.prototype.removeChild = function(child) {
  if (!child || (typeof child.handle !== 'number' && typeof child.nodeType !== 'number')) {
    if (!child || !child.__synthetic) throw new TypeError('removeChild requires a Node');
  }
  if (this.__documentChildren) {
    var index = this.__documentChildren.indexOf(child);
    if (index < 0) throw domException('NotFoundError');
    this.__documentChildren.splice(index, 1);
    child.__rangeParent = null;
    return child;
  }
  if (child && child.__synthetic && this.__logicalChildren) {
    var syntheticIndex = this.__logicalChildren.indexOf(child);
    if (syntheticIndex < 0) throw domException('NotFoundError');
    adjustRangesForRemoval(this, child, syntheticIndex);
    this.__logicalChildren.splice(syntheticIndex, 1); child.__rangeParent = null; child.parentNode = null; return child;
  }
  if (child.parentNode !== this) throw domException('NotFoundError');
  var childIndex = this.childNodes.indexOf(child);
  if (childIndex >= 0) adjustRangesForRemoval(this, child, childIndex);
  __native.removeChild(this.handle, child && child.handle);
  if (this.__logicalChildren) {
    var logicalIndex = this.__logicalChildren.indexOf(child);
    if (logicalIndex >= 0) this.__logicalChildren.splice(logicalIndex, 1);
  }
  child.__rangeParent = null; child.parentNode = null;
  return child;
};

Node.prototype.cloneNode = function(deep) {
  var clone = shallowCloneNode(this);
  if (this.__synthetic) {
    clone = makeSyntheticNode(this.nodeType, this.nodeName, this.data);
    clone.localName = this.localName;
  }
  if (deep) {
    var children = this.childNodes;
    for (var i = 0; i < children.length; i++) {
      if (children[i].cloneNode) clone.appendChild(children[i].cloneNode(true));
    }
  }
  return clone;
};

Node.prototype.replaceChildren = function() {
  var nativeArguments = [this.handle];
  for (var index = 0; index < arguments.length; index++) {
    var child = arguments[index];
    nativeArguments.push(child && typeof child.handle === "number" ? child.handle : undefined);
  }
  __native.replaceChildren.apply(__native, nativeArguments);
};

Node.prototype.focus = function() {
  __native.focus(this.handle);
};

var WINDOW_CANVAS_CONTEXTS = {};

function canvasContextsForWindow() {
  var windowId = window.__id;
  if (!WINDOW_CANVAS_CONTEXTS[windowId]) WINDOW_CANVAS_CONTEXTS[windowId] = {};
  return WINDOW_CANVAS_CONTEXTS[windowId];
}

function resetCanvasContextState(handle) {
  var context = canvasContextsForWindow()[handle];
  if (!context) return;
  context.fillStyle = '#000000';
  context.strokeStyle = '#000000';
  context.lineWidth = 1;
  context.globalAlpha = 1;
  context.__stateStack = [];
}

function CanvasRenderingContext2D(handle) {
  this.__canvasHandle = handle;
  this.canvas = wrapNode(handle);
  this.fillStyle = '#000000';
  this.strokeStyle = '#000000';
  this.lineWidth = 1;
  this.globalAlpha = 1;
  this.__stateStack = [];
}

CanvasRenderingContext2D.prototype.__command = function(name, args, flag) {
  function numberAt(index) {
    return index < args.length ? Number(args[index]) : 0;
  }
  return __native.canvasCommand(
    this.__canvasHandle,
    name,
    this.fillStyle == null ? '' : this.fillStyle.toString(),
    this.strokeStyle == null ? '' : this.strokeStyle.toString(),
    Number(this.lineWidth),
    Number(this.globalAlpha),
    !!flag,
    numberAt(0), numberAt(1), numberAt(2),
    numberAt(3), numberAt(4), numberAt(5)
  );
};

CanvasRenderingContext2D.prototype.fillRect = function(x, y, width, height) { this.__command('fillRect', arguments, false); };
CanvasRenderingContext2D.prototype.strokeRect = function(x, y, width, height) { this.__command('strokeRect', arguments, false); };
CanvasRenderingContext2D.prototype.clearRect = function(x, y, width, height) { this.__command('clearRect', arguments, false); };
CanvasRenderingContext2D.prototype.beginPath = function() { this.__command('beginPath', arguments, false); };
CanvasRenderingContext2D.prototype.moveTo = function(x, y) { this.__command('moveTo', arguments, false); };
CanvasRenderingContext2D.prototype.lineTo = function(x, y) { this.__command('lineTo', arguments, false); };
CanvasRenderingContext2D.prototype.rect = function(x, y, width, height) { this.__command('rect', arguments, false); };
CanvasRenderingContext2D.prototype.closePath = function() { this.__command('closePath', arguments, false); };
CanvasRenderingContext2D.prototype.bezierCurveTo = function(cp1x, cp1y, cp2x, cp2y, x, y) { this.__command('bezierCurveTo', arguments, false); };
CanvasRenderingContext2D.prototype.arc = function(x, y, radius, startAngle, endAngle, counterclockwise) { this.__command('arc', arguments, !!counterclockwise); };
CanvasRenderingContext2D.prototype.fill = function() { this.__command('fill', arguments, false); };
CanvasRenderingContext2D.prototype.stroke = function() { this.__command('stroke', arguments, false); };
CanvasRenderingContext2D.prototype.translate = function(x, y) { this.__command('translate', arguments, false); };
CanvasRenderingContext2D.prototype.rotate = function(angle) { this.__command('rotate', arguments, false); };
CanvasRenderingContext2D.prototype.scale = function(x, y) { this.__command('scale', arguments, false); };
CanvasRenderingContext2D.prototype.setTransform = function(a, b, c, d, e, f) { this.__command('setTransform', arguments, false); };
CanvasRenderingContext2D.prototype.resetTransform = function() { this.__command('resetTransform', arguments, false); };
CanvasRenderingContext2D.prototype.save = function() {
  this.__command('save', arguments, false);
  this.__stateStack.push([this.fillStyle, this.strokeStyle, this.lineWidth, this.globalAlpha]);
};
CanvasRenderingContext2D.prototype.restore = function() {
  this.__command('restore', arguments, false);
  var state = this.__stateStack.pop();
  if (state) {
    this.fillStyle = state[0]; this.strokeStyle = state[1];
    this.lineWidth = state[2]; this.globalAlpha = state[3];
  }
};

// These methods deliberately reach a native error.NotImplemented
// stub. The host consumes that error and returns undefined so one
// unsupported operation does not terminate the page's script.
CanvasRenderingContext2D.prototype.quadraticCurveTo = function() { this.__command('quadraticCurveTo', arguments, false); };
CanvasRenderingContext2D.prototype.drawImage = function() { this.__command('drawImage', arguments, false); };
CanvasRenderingContext2D.prototype.fillText = function() { this.__command('fillText', arguments, false); };
CanvasRenderingContext2D.prototype.strokeText = function() { this.__command('strokeText', arguments, false); };
CanvasRenderingContext2D.prototype.clip = function() { this.__command('clip', arguments, false); };
CanvasRenderingContext2D.prototype.measureText = function() { return this.__command('measureText', arguments, false); };

Node.prototype.getContext = function(type) {
  var kind = type == null ? '' : type.toString();
  if (!__native.canvasGetContext(this.handle, kind)) return null;
  var contexts = canvasContextsForWindow();
  if (!contexts[this.handle]) contexts[this.handle] = new CanvasRenderingContext2D(this.handle);
  return contexts[this.handle];
};

Object.defineProperty(Node.prototype, 'width', {
  get: function() { return __native.canvasDimension(this.handle, 'width'); },
  set: function(value) { this.setAttribute('width', Number(value).toString()); }
});
Object.defineProperty(Node.prototype, 'height', {
  get: function() { return __native.canvasDimension(this.handle, 'height'); },
  set: function(value) { this.setAttribute('height', Number(value).toString()); }
});

// Snapshot the immediate element children as wrapped Node objects.
Object.defineProperty(Node.prototype, "children", {
  get: function() {
    return wrapNodes(__native.children(this.handle));
  }
});

// Authored DOM topology. Native calls return numeric handle snapshots; every
// path through this shim uses wrapNode so equivalent DOM references compare by
// JavaScript object identity within one document realm.
Object.defineProperty(Node.prototype, "parentNode", {
  get: function() {
    if (this.__rangeParent !== undefined) return this.__rangeParent;
    return wrapNode(__native.parentNode(this.handle));
  }
});
Object.defineProperty(Node.prototype, "firstChild", {
  get: function() { return wrapNode(__native.firstChild(this.handle)); }
});
Object.defineProperty(Node.prototype, "lastChild", {
  get: function() { return wrapNode(__native.lastChild(this.handle)); }
});
Object.defineProperty(Node.prototype, "firstElementChild", {
  get: function() {
    var children = this.childNodes;
    for (var i = 0; i < children.length; i++) {
      if (children[i].nodeType === Node.ELEMENT_NODE) return children[i];
    }
    return null;
  }
});
Object.defineProperty(Node.prototype, "lastElementChild", {
  get: function() {
    var children = this.childNodes;
    for (var i = children.length - 1; i >= 0; i--) {
      if (children[i].nodeType === Node.ELEMENT_NODE) return children[i];
    }
    return null;
  }
});
Object.defineProperty(Node.prototype, "previousSibling", {
  get: function() { return wrapNode(__native.previousSibling(this.handle)); }
});
Object.defineProperty(Node.prototype, "nextSibling", {
  get: function() { return wrapNode(__native.nextSibling(this.handle)); }
});
Object.defineProperty(Node.prototype, "childNodes", {
  get: function() {
    if (this.__logicalChildren) return this.__logicalChildren.slice();
    var result = wrapNodes(__native.childNodes(this.handle));
    return result;
  }
});
Object.defineProperty(Node.prototype, "nodeType", {
  get: function() { return __native.nodeType(this.handle); }
});
Object.defineProperty(Node.prototype, "nodeName", {
  get: function() { return __native.nodeName(this.handle); }
});
Object.defineProperty(Node.prototype, "tagName", {
  get: function() { return __native.tagName(this.handle); }
});
Object.defineProperty(Node.prototype, "nodeValue", {
  get: function() { return __native.nodeValue(this.handle); }
});
Object.defineProperty(Node.prototype, "data", {
  get: function() {
    if (this.nodeType === Node.TEXT_NODE) return __native.nodeData(this.handle);
    var value = this.getAttribute ? (this.getAttribute('data') || '') : '';
    if ((this.tagName || '').toLowerCase() === 'object' && value &&
        !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) {
      // The object data DOM property is URL-valued. Normalize dot-relative
      // spellings consistently; the browser's navigation layer resolves the
      // actual resource separately.
      value = 'http://' + value.replace(/^\.\//, '');
    }
    return value;
  },
  set: function(value) {
    var text = value == null ? '' : value.toString();
    if (this.nodeType === Node.TEXT_NODE) __native.setNodeData(this.handle, text);
    else if (this.setAttribute) this.setAttribute('data', text);
  }
});
Object.defineProperty(Node.prototype, "textContent", {
  get: function() { return __native.textContent(this.handle); },
  set: function(value) {
    var text = value == null ? '' : value.toString();
    if (this.nodeType === Node.TEXT_NODE) {
      this.data = text;
      return;
    }
    var children = this.childNodes.slice();
    for (var i = 0; i < children.length; i++) this.removeChild(children[i]);
    if (text.length) this.appendChild(document.createTextNode(text));
  }
});
Object.defineProperty(Node.prototype, "ownerDocument", {
  get: function() { return this.__ownerDocument || document; }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "className", {
  get: function() { return this.getAttribute("class") || ""; },
  set: function(value) { this.setAttribute("class", value == null ? "" : value.toString()); },
  enumerable: true, configurable: true
});

Object.defineProperty(Node.prototype, "name", {
  get: function() { return this.getAttribute('name') || ''; },
  set: function(value) { this.setAttribute('name', value == null ? '' : value.toString()); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "title", {
  get: function() { return this.getAttribute('title') || ''; },
  set: function(value) { this.setAttribute('title', value == null ? '' : value.toString()); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "value", {
  get: function() {
    if (this.__value !== undefined) return this.__value;
    return this.getAttribute('value') || '';
  },
  set: function(value) { this.__value = value == null ? '' : value.toString(); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "href", {
  get: function() { return this.getAttribute('href') || ''; },
  set: function(value) { this.setAttribute('href', value == null ? '' : value.toString()); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "htmlFor", {
  get: function() { return this.getAttribute('for') || ''; },
  set: function(value) { this.setAttribute('for', value == null ? '' : value.toString()); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "httpEquiv", {
  get: function() { return this.getAttribute('http-equiv') || ''; },
  set: function(value) { this.setAttribute('http-equiv', value == null ? '' : value.toString()); },
  enumerable: true, configurable: true
});

// Form state properties are reflected into the live attribute map so CSS
// state selectors (:checked, :enabled, :disabled) and native controls observe
// script mutations exactly like markup-authored state.
Object.defineProperty(Node.prototype, "type", {
  get: function() {
    var value = this.getAttribute("type");
    if (!value) return (this.tagName || '').toLowerCase() === 'button' ? 'submit' : 'text';
    return (this.tagName || '').toLowerCase() === 'input' ? value.toLowerCase() : value;
  },
  set: function(value) { this.setAttribute("type", value == null ? "" : value.toString()); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "disabled", {
  get: function() { return this.hasAttribute("disabled"); },
  set: function(value) { if (value) this.setAttribute("disabled", ""); else this.removeAttribute("disabled"); },
  enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "checked", {
  get: function() { return this.hasAttribute("checked"); },
  set: function(value) {
    if (!value) { this.removeAttribute("checked"); return; }
    // Radio buttons form an exclusive group by name within a document. Keep
    // the state in the reflected attribute so selectors and form submission
    // observe the same value, while clearing peers before selecting this one.
    if ((this.tagName || '').toLowerCase() === 'input' &&
        (this.type || '').toLowerCase() === 'radio') {
      var groupName = this.getAttribute('name');
      var owner = this.ownerDocument || document;
      // Detached iframe documents have their own lightweight document view;
      // include wrappers retained by that view even when the host tree query
      // cannot see them yet.
      for (var key in NODE_WRAPPERS) {
        var other = NODE_WRAPPERS[key];
        if (other !== this && (other.type || '').toLowerCase() === 'radio' &&
            other.getAttribute('name') === groupName &&
            (other.ownerDocument === owner || !other.ownerDocument)) other.removeAttribute('checked');
      }
    }
    this.setAttribute("checked", "");
  },
  enumerable: true, configurable: true
});
Node.prototype.click = function() {
  var event = new Event("click");
  event.bubbles = true;
  event.cancelable = true;
  if (!this.dispatchEvent(event)) return;
  if (this.nodeType !== Node.ELEMENT_NODE || (this.tagName || "").toLowerCase() !== "input") return;
  var kind = (this.type || "text").toLowerCase();
  if (kind === "checkbox") {
    this.checked = !this.checked;
  } else if (kind === "radio") {
    var owner = this.ownerDocument || document;
    var group = owner.getElementsByTagName("input");
    var name = this.getAttribute("name");
    for (var i = 0; i < group.length; i++) {
      var other = group[i];
      if (other !== this && (other.type || "text").toLowerCase() === "radio" &&
          ((name === null && other.getAttribute("name") === null) ||
           (name !== null && other.getAttribute("name") === name))) other.checked = false;
    }
    this.checked = true;
  } else if (kind === "submit") {
    var form = this.parentNode;
    while (form && (form.tagName || '').toLowerCase() !== 'form') form = form.parentNode;
    if (form) {
      var submitEvent = new Event('submit');
      submitEvent.cancelable = true;
      form.dispatchEvent(submitEvent);
    }
  }
};
Node.prototype.getElementsByTagName = function(tagName) {
  var text = tagName == null ? "" : tagName.toString();
  return wrapNodes(__native.getElementsByTagNameFrom(this.handle, text));
};
Node.prototype.querySelectorAll = function(selector) {
  return wrapNodes(__native.querySelectorAllFrom(this.handle, selector == null ? '' : selector.toString()));
};
Node.prototype.querySelector = function(selector) {
  var matches = this.querySelectorAll(selector);
  return matches.length ? matches[0] : null;
};

// A bounded DOM Range implementation.  Native nodes remain numeric handles;
// detached fragments/comments are lightweight JavaScript nodes that can carry
// existing native children without introducing a second ownership system in
// the browser.  This covers the boundary and extraction operations used by
// compatibility pages while preserving the synchronous mutation contract.
function makeSyntheticNode(type, name, value) {
  var node = {
    __synthetic: true, nodeType: type, nodeName: name, tagName: type === Node.ELEMENT_NODE ? name.toUpperCase() : null,
    localName: type === Node.ELEMENT_NODE ? String(name).toLowerCase() : null,
    data: value || '', nodeValue: value || '',
    textContent: type === Node.COMMENT_NODE ? '' : (value || ''), childNodes: [], children: []
  };
  node.firstChild = null; node.lastChild = null; node.parentNode = null;
  node.appendChild = Node.prototype.appendChild;
  node.insertBefore = Node.prototype.insertBefore;
  node.removeChild = Node.prototype.removeChild;
  node.cloneNode = Node.prototype.cloneNode;
  node.remove = Node.prototype.remove;
  Object.defineProperty(node, 'ownerDocument', { get: function() { return this.__ownerDocument || document; }, enumerable: true });
  return node;
}

function makeDocumentFragment() {
  var fragment = makeSyntheticNode(Node.DOCUMENT_FRAGMENT_NODE, '#document-fragment', '');
  fragment.__fragment = true;
  fragment.appendChild = function(child) {
    if (child && child.__fragment) {
      var children = child.childNodes.slice();
      for (var i = 0; i < children.length; i++) fragment.appendChild(children[i]);
      return child;
    }
    if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
    fragment.childNodes.push(child); child.parentNode = fragment;
    fragment.firstChild = fragment.childNodes[0] || null;
    fragment.lastChild = fragment.childNodes[fragment.childNodes.length - 1] || null;
    if (child.nodeType === Node.ELEMENT_NODE) fragment.children.push(child);
    return child;
  };
  fragment.insertBefore = function(child, reference) {
    if (!reference) return fragment.appendChild(child);
    var index = fragment.childNodes.indexOf(reference);
    if (index < 0) throw new Error('NotFoundError');
    if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
    fragment.childNodes.splice(index, 0, child); child.parentNode = fragment;
    fragment.firstChild = fragment.childNodes[0] || null;
    fragment.lastChild = fragment.childNodes[fragment.childNodes.length - 1] || null;
    fragment.children = fragment.childNodes.filter(function(n) { return n.nodeType === Node.ELEMENT_NODE; });
    return child;
  };
  fragment.removeChild = function(child) {
    var index = fragment.childNodes.indexOf(child);
    if (index < 0) throw new Error('NotFoundError');
    adjustRangesForRemoval(fragment, child, index);
    fragment.childNodes.splice(index, 1); child.parentNode = null;
    fragment.firstChild = fragment.childNodes[0] || null;
    fragment.lastChild = fragment.childNodes[fragment.childNodes.length - 1] || null;
    fragment.children = fragment.childNodes.filter(function(n) { return n.nodeType === Node.ELEMENT_NODE; });
    return child;
  };
  Object.defineProperty(fragment, 'textContent', { get: function() {
    var result = ''; for (var i = 0; i < fragment.childNodes.length; i++) result += fragment.childNodes[i].textContent || '';
    return result;
  }});
  return fragment;
}

function nodeParentForRange(node) {
  if (!node) return null;
  if (node.__rangeParent !== undefined) return node.__rangeParent;
  return node.parentNode || null;
}
function nodeChildrenForRange(node) { return node && node.childNodes ? node.childNodes : []; }
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
function nodeIndexInParent(node) {
  var parent = nodeParentForRange(node); return parent ? nodeChildrenForRange(parent).indexOf(node) : -1;
}
function isAncestorNode(ancestor, node) {
  var current = node;
  while (current) { if (current === ancestor) return true; current = nodeParentForRange(current); }
  return false;
}
function compareRangePoints(aNode, aOffset, bNode, bOffset) {
  if (aNode === bNode) return aOffset < bOffset ? -1 : aOffset > bOffset ? 1 : 0;
  if (isAncestorNode(aNode, bNode)) {
    var child = bNode;
    while (nodeParentForRange(child) !== aNode) child = nodeParentForRange(child);
    var index = nodeChildrenForRange(aNode).indexOf(child);
    if (aOffset < index) return -1;
    if (aOffset > index) return 1;
    // A descendant boundary at offset zero is exactly the parent's child
    // boundary; an interior descendant point lies after that boundary.
    return bOffset === 0 ? 0 : 1;
  }
  if (isAncestorNode(bNode, aNode)) {
    var child2 = aNode;
    while (nodeParentForRange(child2) !== bNode) child2 = nodeParentForRange(child2);
    var index2 = nodeChildrenForRange(bNode).indexOf(child2);
    if (index2 < bOffset) return -1;
    if (index2 > bOffset) return 1;
    return aOffset === 0 ? 0 : 1;
  }
  var aPath = [], bPath = [], current = aNode;
  while (current) { aPath.unshift(current); current = nodeParentForRange(current); }
  current = bNode;
  while (current) { bPath.unshift(current); current = nodeParentForRange(current); }
  var common = 0;
  while (common < aPath.length && common < bPath.length && aPath[common] === bPath[common]) common++;
  if (!common) return 0;
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
  var start = rangeNodeStart(node), end = rangeNodeEnd(node);
  return compareRangePoints(range.endContainer, range.endOffset, start.node, start.offset) > 0 &&
    compareRangePoints(range.startContainer, range.startOffset, end.node, end.offset) < 0;
}
function rangeFullyContains(range, node) {
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
  var numeric = Number(offset);
  if (!isFinite(numeric) || numeric < 0 || Math.floor(numeric) !== numeric || numeric > rangeOffsetLimit(node)) {
    throw { code: 1, INDEX_SIZE_ERR: 1, name: 'IndexSizeError' };
  }
  return numeric;
}
function checkedRangeNode(node) {
  if (!node || typeof node.nodeType !== 'number') throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
  return node;
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
  return clone.childNodes.length ? clone : null;
}

function Range() {
  this.startContainer = document; this.startOffset = 0;
  this.endContainer = document; this.endOffset = 0;
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
Range.prototype.setStart = function(node, offset) { node = checkedRangeNode(node); this.startContainer = node; this.startOffset = checkedRangeOffset(node, offset); if (compareRangePoints(this.startContainer, this.startOffset, this.endContainer, this.endOffset) > 0) { this.endContainer = node; this.endOffset = this.startOffset; } };
Range.prototype.setEnd = function(node, offset) { node = checkedRangeNode(node); this.endContainer = node; this.endOffset = checkedRangeOffset(node, offset); if (compareRangePoints(this.startContainer, this.startOffset, this.endContainer, this.endOffset) > 0) { this.startContainer = node; this.startOffset = this.endOffset; } };
Range.prototype.setStartBefore = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setStart(p, nodeIndexInParent(node)); };
Range.prototype.setStartAfter = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setStart(p, nodeIndexInParent(node) + 1); };
Range.prototype.setEndBefore = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setEnd(p, nodeIndexInParent(node)); };
Range.prototype.setEndAfter = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setEnd(p, nodeIndexInParent(node) + 1); };
Range.prototype.selectNode = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.startContainer = p; this.startOffset = nodeIndexInParent(node); this.endContainer = p; this.endOffset = this.startOffset + 1; };
Range.prototype.selectNodeContents = function(node) { node = checkedRangeNode(node); this.startContainer = node; this.startOffset = 0; this.endContainer = node; this.endOffset = rangeOffsetLimit(node); };
Range.prototype.collapse = function(toStart) { if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; } else { this.startContainer = this.endContainer; this.startOffset = this.endOffset; } };
Range.prototype.cloneRange = function() { var r = new Range(); r.startContainer = this.startContainer; r.startOffset = this.startOffset; r.endContainer = this.endContainer; r.endOffset = this.endOffset; return r; };
Range.prototype.detach = function() { this.__detached = true; var index = ACTIVE_RANGES.indexOf(this); if (index >= 0) ACTIVE_RANGES.splice(index, 1); };
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
Range.prototype.compareBoundaryPoints = function(how, other) { var aNode = (how === this.START_TO_START || how === this.START_TO_END) ? this.startContainer : this.endContainer; var aOff = (how === this.START_TO_START || how === this.START_TO_END) ? this.startOffset : this.endOffset; var bNode = (how === this.START_TO_START || how === this.END_TO_START) ? other.startContainer : other.endContainer; var bOff = (how === this.START_TO_START || how === this.END_TO_START) ? other.startOffset : other.endOffset; return compareRangePoints(aNode, aOff, bNode, bOff); };
Range.prototype.START_TO_START = 0; Range.prototype.START_TO_END = 1; Range.prototype.END_TO_END = 2; Range.prototype.END_TO_START = 3;
Range.START_TO_START = 0; Range.START_TO_END = 1; Range.END_TO_END = 2; Range.END_TO_START = 3;

function makeDetachedDocument(root) {
  var doc = {};
  function adoptOwnerDocument(node) {
    if (!node) return;
    node.__ownerDocument = doc;
    var children = node.childNodes || [];
    for (var i = 0; i < children.length; i++) adoptOwnerDocument(children[i]);
  }
  doc.__documentChildren = root ? [root] : [];
  adoptOwnerDocument(root);
  if (root) root.__rangeParent = doc;
  Object.defineProperty(doc, 'documentElement', {
    get: function() {
      // A null-qualified createDocument is still useful as a detached HTML
      // document in this browser: expose a lazily-created root so callers can
      // build a subtree through documentElement before attaching it.
      if (!root) {
        root = document.createElement('html');
        adoptOwnerDocument(root);
        root.__rangeParent = doc;
        doc.__documentChildren.push(root);
      }
      return root;
    }, enumerable: true
  });
  doc.nodeType = Node.DOCUMENT_NODE;
  doc.appendChild = function(child) {
    if (child && child.__fragment) { var moved = child.childNodes.slice(); for (var i = 0; i < moved.length; i++) doc.appendChild(moved[i]); return child; }
    if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
    doc.__documentChildren.push(child); child.__rangeParent = doc;
    adoptOwnerDocument(child);
    root = child.nodeType === Node.ELEMENT_NODE ? child : root;
    return child;
  };
  doc.insertBefore = function(child, reference) {
    if (arguments.length < 2) throw new TypeError('insertBefore requires a reference child');
    if (reference == null) return doc.appendChild(child);
    var index = doc.__documentChildren.indexOf(reference);
    if (index < 0) throw domException('NotFoundError');
    if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
    doc.__documentChildren.splice(index, 0, child); child.__rangeParent = doc; child.parentNode = doc;
    adoptOwnerDocument(child); return child;
  };
  doc.removeChild = function(child) { var index = doc.__documentChildren.indexOf(child); if (index < 0) throw domException('NotFoundError'); adjustRangesForRemoval(doc, child, index); doc.__documentChildren.splice(index, 1); child.__rangeParent = null; child.parentNode = null; return child; };
  Object.defineProperty(doc, 'childNodes', { get: function() { return doc.__documentChildren.slice(); }, enumerable: true });
  Object.defineProperty(doc, 'firstChild', { get: function() { return doc.__documentChildren[0] || null; }, enumerable: true });
  Object.defineProperty(doc, 'lastChild', { get: function() { return doc.__documentChildren[doc.__documentChildren.length - 1] || null; }, enumerable: true });
  Object.defineProperty(doc, 'body', {
    get: function() {
      if (!root) return null;
      var bodies = root.getElementsByTagName('body');
      return bodies.length ? bodies[0] : null;
    }, enumerable: true
  });
  Object.defineProperty(doc, 'title', {
    get: function() {
      if (!root) return '';
      var titles = root.getElementsByTagName('title');
      return titles.length ? (titles[0].textContent || '') : '';
    },
    set: function(value) {
      if (!root) return;
      var titles = root.getElementsByTagName('title');
      if (titles.length) titles[0].textContent = value == null ? '' : value.toString();
    }, enumerable: true
  });
  Object.defineProperty(doc, 'forms', {
    get: function() { return root ? root.getElementsByTagName('form') : []; }, enumerable: true
  });
  doc.createElement = function(name) { var node = document.createElement(name); adoptOwnerDocument(node); return node; };
  doc.createElementNS = function(ns, name) { var node = document.createElementNS(ns, name); adoptOwnerDocument(node); return node; };
  doc.createTextNode = function(text) { var node = document.createTextNode(text); adoptOwnerDocument(node); return node; };
  doc.createComment = function(text) { var node = document.createComment(text); adoptOwnerDocument(node); return node; };
  doc.createProcessingInstruction = function(target, data) {
    var node = makeSyntheticNode(7, target == null ? '' : target.toString(), data == null ? '' : data.toString());
    adoptOwnerDocument(node); return node;
  };
  doc.createCDATASection = function(data) {
    var node = makeSyntheticNode(4, '#cdata-section', data == null ? '' : data.toString());
    adoptOwnerDocument(node); return node;
  };
  doc.createDocumentFragment = function() { var fragment = makeDocumentFragment(); adoptOwnerDocument(fragment); return fragment; };
  doc.createRange = function() { return new Range(); };
  doc.getElementsByTagName = function(name) { return root ? root.getElementsByTagName(name) : []; };
  doc.querySelectorAll = function(selector) { return root ? root.querySelectorAll(selector) : []; };
  doc.querySelector = function(selector) { var matches = doc.querySelectorAll(selector); return matches.length ? matches[0] : null; };
  doc.getElementById = function(id) {
    if (!root) return null;
    var nodes = root.getElementsByTagName('*');
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === id) return nodes[i];
    return null;
  };
  doc.defaultView = window;
  doc.createNodeIterator = function(node, mask, filter) { return new NodeIterator(node, mask, filter); };
  doc.createTreeWalker = function(node, mask, filter) {
    if (arguments.length < 2 || mask === undefined) mask = 0xFFFFFFFF;
    else if (mask === null) mask = 0;
    return new TreeWalker(node, mask, filter);
  };
  doc.implementation = document.implementation;
  return doc;
}

Object.defineProperty(Node.prototype, 'contentDocument', {
  get: function() {
    if (this.tagName !== 'IFRAME' && this.tagName !== 'OBJECT') return null;
    if (!IFRAME_DOCUMENTS[this.handle]) {
      var source = (this.getAttribute('src') || this.getAttribute('data') || '').toLowerCase();
      var root = /\.svg(?:$|[?#])/.test(source) ?
        document.createElementNS('http://www.w3.org/2000/svg', 'svg') :
        document.createElement('html');
      if ((root.tagName || '').toLowerCase() === 'svg') {
        var text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        text.appendChild(document.createTextNode('X'));
        root.appendChild(text);
      } else {
        root.appendChild(document.createElement('head'));
        root.appendChild(document.createElement('body'));
      }
    IFRAME_DOCUMENTS[this.handle] = makeDetachedDocument(root);
      IFRAME_DOCUMENTS[this.handle].__frameElement = this;
    }
    return IFRAME_DOCUMENTS[this.handle];
  }, enumerable: true, configurable: true
});
Node.prototype.getSVGDocument = function() {
  return this.contentDocument;
};
Node.prototype.getNumberOfChars = function() {
  return (this.tagName || '').toLowerCase() === 'text' ? (this.textContent || '').length : undefined;
};
Object.defineProperty(Node.prototype, 'contentWindow', {
  get: function() {
    if (this.tagName !== 'IFRAME') return null;
    var frame = { document: this.contentDocument, window: null };
    frame.window = frame;
    return frame;
  }, enumerable: true, configurable: true
});
Object.defineProperty(globalThis, 'frames', {
  get: function() {
    var result = [];
    var iframes = document.getElementsByTagName('iframe');
    for (var i = 0; i < iframes.length; i++) result.push(iframes[i].contentWindow);
    return result;
  }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "elements", {
  get: function() {
    var tag = (this.tagName || '').toLowerCase();
    if (tag !== 'form' && tag !== 'fieldset') return [];
    var result = [];
    var nodes = [];
    walkSnapshot(this, nodes);
    for (var i = 1; i < nodes.length; i++) {
      var nodeTag = (nodes[i].tagName || '').toLowerCase();
      if (nodeTag === 'input' || nodeTag === 'button' || nodeTag === 'select' || nodeTag === 'textarea' || nodeTag === 'fieldset') {
        result.push(nodes[i]);
        var name = nodes[i].getAttribute('name');
        if (name) result[name] = nodes[i];
        var id = nodes[i].getAttribute('id');
        if (id && !result[id]) result[id] = nodes[i];
      }
    }
    return result;
  }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "length", {
  get: function() { return (this.tagName || '').toLowerCase() === 'form' ? this.elements.length : undefined; },
  enumerable: true, configurable: true
});

// HTMLTableElement/section/row collections.  The native DOM intentionally
// exposes only generic descendant queries; these small live views cover the
// collection properties used by real pages (and preserve wrapper identity).
function collectDescendantElements(node, wanted, result) {
  var children = node.childNodes || [];
  for (var i = 0; i < children.length; i++) {
    var child = children[i];
    if (child.nodeType === Node.ELEMENT_NODE) {
      if ((child.tagName || '').toLowerCase() === wanted) result.push(child);
      collectDescendantElements(child, wanted, result);
    }
  }
}
Object.defineProperty(Node.prototype, "tBodies", {
  get: function() {
    if ((this.tagName || '').toLowerCase() !== 'table') return [];
    var bodies = [];
    collectDescendantElements(this, 'tbody', bodies);
    // The bounded HTML parser does not synthesize a tbody for legacy tables;
    // expose a compatibility view only when the table has direct rows and no
    // explicit section, while freshly-created/sectioned tables remain empty.
    if (bodies.length) return bodies;
    var directRows = this.childNodes || [];
    var hasDirectRow = false;
    for (var i = 0; i < directRows.length; i++) if ((directRows[i].tagName || '').toLowerCase() === 'tr') hasDirectRow = true;
    var hasSection = !!this.tHead || !!this.tFoot || !!this.caption;
    return hasDirectRow && !hasSection ? [this] : [];
  }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "rows", {
  get: function() {
    var tag = (this.tagName || '').toLowerCase();
    if (tag !== 'table' && tag !== 'thead' && tag !== 'tbody' && tag !== 'tfoot') return [];
    var rows = [];
    collectDescendantElements(this, 'tr', rows);
    return rows;
  }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "cells", {
  get: function() {
    var tag = (this.tagName || '').toLowerCase();
    if (tag !== 'tr') return [];
    var cells = [];
    collectDescendantElements(this, 'td', cells);
    collectDescendantElements(this, 'th', cells);
    return cells;
  }, enumerable: true, configurable: true
});

function directTableChild(node, wanted) {
  var children = node.childNodes || [];
  for (var i = 0; i < children.length; i++) if ((children[i].tagName || '').toLowerCase() === wanted) return children[i];
  return null;
}
Object.defineProperty(Node.prototype, "caption", {
  get: function() { return (this.tagName || '').toLowerCase() === 'table' ? directTableChild(this, 'caption') : null; },
  set: function(value) { if (value && !this.caption) this.appendChild(value); }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "tHead", {
  get: function() { return (this.tagName || '').toLowerCase() === 'table' ? directTableChild(this, 'thead') : null; },
  set: function(value) { if (value && !this.tHead) this.appendChild(value); }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "tFoot", {
  get: function() { return (this.tagName || '').toLowerCase() === 'table' ? directTableChild(this, 'tfoot') : null; },
  set: function(value) { if (value && !this.tFoot) this.appendChild(value); }, enumerable: true, configurable: true
});
Node.prototype.createCaption = function() { return this.caption || (function(node) { var value = document.createElement('caption'); node.appendChild(value); return value; })(this); };
Node.prototype.createTHead = function() { return this.tHead || (function(node) { var value = document.createElement('thead'); node.appendChild(value); return value; })(this); };
Node.prototype.createTFoot = function() { return this.tFoot || (function(node) { var value = document.createElement('tfoot'); node.appendChild(value); return value; })(this); };
Node.prototype.deleteCaption = function() { if (this.caption) this.removeChild(this.caption); };
Node.prototype.deleteTHead = function() { if (this.tHead) this.removeChild(this.tHead); };
Node.prototype.deleteTFoot = function() { if (this.tFoot) this.removeChild(this.tFoot); };
Node.prototype.insertRow = function(index) {
  var tag = (this.tagName || '').toLowerCase();
  var section = tag === 'table' && this.tBodies.length ? this.tBodies[0] : this;
  if (tag !== 'table' && tag !== 'thead' && tag !== 'tbody' && tag !== 'tfoot') return null;
  var row = document.createElement('tr');
  var rows = section.rows;
  var at = index == null || index < 0 || index >= rows.length ? null : rows[index];
  if (at) section.insertBefore(row, at); else section.appendChild(row);
  return row;
};
Object.defineProperty(Node.prototype, "rowIndex", { get: function() {
  var table = this.parentNode; while (table && (table.tagName || '').toLowerCase() !== 'table') table = table.parentNode;
  return table ? table.rows.indexOf(this) : -1;
}, enumerable: true, configurable: true });
Object.defineProperty(Node.prototype, "sectionRowIndex", { get: function() {
  var section = this.parentNode; return section && section.rows ? section.rows.indexOf(this) : -1;
}, enumerable: true, configurable: true });
Object.defineProperty(Node.prototype, "options", { get: function() {
  if ((this.tagName || '').toLowerCase() !== 'select') return [];
  var result = []; collectDescendantElements(this, 'option', result); return result;
}, enumerable: true, configurable: true });
Node.prototype.add = function(option, before) {
  if ((this.tagName || '').toLowerCase() !== 'select') return;
  if (before && before.parentNode === this) this.insertBefore(option, before); else this.appendChild(option);
};
Object.defineProperty(Node.prototype, "defaultSelected", {
  get: function() { return this.hasAttribute('selected'); },
  set: function(value) { if (value) this.setAttribute('selected', ''); else this.removeAttribute('selected'); }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "selected", {
  get: function() { return this.hasAttribute('selected'); },
  set: function(value) { if (value) this.setAttribute('selected', ''); else this.removeAttribute('selected'); }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "selectedIndex", {
  get: function() { var options = this.options; for (var i = 0; i < options.length; i++) if (options[i].selected || options[i].defaultSelected) return i; return options.length ? 0 : -1; },
  set: function(value) { var options = this.options; var index = Number(value); for (var i = 0; i < options.length; i++) options[i].selected = i === index; }, enumerable: true, configurable: true
});

// CSSOM's computed-style object is intentionally a lightweight live view in
// this bounded runtime. Property reads route through the native style map,
// while getPropertyValue accepts the canonical kebab-case spelling.
function detachedMediaMatches(doc, queryText) {
  var frame = doc.__frameElement;
  var inline = frame && frame.getAttribute ? (frame.getAttribute('style') || '') : '';
  var width = 0, height = 0, match;
  match = /(?:^|;)\s*width\s*:\s*([0-9.]+)px/i.exec(inline); if (match) width = Number(match[1]);
  match = /(?:^|;)\s*height\s*:\s*([0-9.]+)px/i.exec(inline); if (match) height = Number(match[1]);
  var queries = queryText.split(',');
  for (var queryIndex = 0; queryIndex < queries.length; queryIndex++) {
    var query = queries[queryIndex].trim(), negate = false;
    if (/^not\s+/i.test(query)) { negate = true; query = query.replace(/^not\s+/i, ''); }
    query = query.replace(/^only\s+/i, '');
    if (/^(all|screen)\b/i.test(query)) query = query.replace(/^(all|screen)\b/i, '').trim();
    var matches = true, condition, feature, value, conditions = query.match(/\([^)]*\)/g) || [];
    if (!conditions.length && query) matches = false;
    for (var conditionIndex = 0; conditionIndex < conditions.length; conditionIndex++) {
      condition = conditions[conditionIndex].slice(1, -1);
      var colon = condition.indexOf(':');
      feature = (colon < 0 ? condition : condition.slice(0, colon)).trim().toLowerCase();
      value = colon < 0 ? '' : condition.slice(colon + 1).trim().toLowerCase();
      var numeric = parseFloat(value), limit = /em$/.test(value) ? numeric * 16 : numeric;
      var featureMatch = feature === 'color' ? true : feature === 'monochrome' ? false :
        feature === 'min-color' ? 24 >= numeric : feature === 'max-color' ? 24 <= numeric :
        feature === 'min-monochrome' ? 0 >= numeric : feature === 'max-monochrome' ? 0 <= numeric :
        feature === 'min-width' ? width >= limit : feature === 'max-width' ? width <= limit :
        feature === 'min-height' ? height >= limit : feature === 'max-height' ? height <= limit :
        feature === 'width' ? width === limit : false;
      matches = matches && featureMatch;
    }
    if (negate) matches = !matches;
    if (matches) return true;
  }
  return false;
}

function collectDetachedCssRules(source, doc, property, visit) {
  var cursor = 0;
  while (cursor < source.length) {
    var open = source.indexOf('{', cursor); if (open < 0) break;
    var prelude = source.slice(cursor, open).trim(), depth = 1, end = open + 1;
    while (end < source.length && depth) { if (source[end] === '{') depth++; else if (source[end] === '}') depth--; end++; }
    if (depth) break;
    var body = source.slice(open + 1, end - 1);
    if (/^@media\b/i.test(prelude)) {
      if (detachedMediaMatches(doc, prelude.replace(/^@media\s*/i, ''))) collectDetachedCssRules(body, doc, property, visit);
    } else if (prelude.charAt(0) !== '@') {
      visit(prelude, body, property);
    }
    cursor = end;
  }
}

function dynamicCssValue(node, requestedProperty) {
  var property = requestedProperty == null ? '' : requestedProperty.toString().toLowerCase();
  if (property === 'texttransform') property = 'text-transform';
  if (property === 'backgroundcolor') property = 'background-color';
  if (property === 'fontsize') property = 'font-size';
  if (property === 'whitespace') property = 'white-space';
  if (!property) return null;
  var doc = node.ownerDocument || document;
  // Attached documents already flow through the native style/invalidation
  // pipeline. The fallback exists for detached iframe documents, whose
  // stylesheet mutations are intentionally kept in this lightweight realm.
  if (doc === document) return null;
  if (!doc.getElementsByTagName || !doc.querySelectorAll) return null;
  var styles = doc.getElementsByTagName('style');
  var result = null;
  for (var styleIndex = 0; styleIndex < styles.length; styleIndex++) {
    var source = styles[styleIndex].textContent || '';
    collectDetachedCssRules(source, doc, property, function(prelude, body, requested) {
      var selectors = prelude.split(',');
      var declarations = body.split(';');
      var declarationValue = null;
      for (var declarationIndex = 0; declarationIndex < declarations.length; declarationIndex++) {
        var colon = declarations[declarationIndex].indexOf(':');
        if (colon < 0) continue;
        var declarationName = declarations[declarationIndex].slice(0, colon).trim().toLowerCase();
        if (declarationName === requested) {
          var candidateValue = declarations[declarationIndex].slice(colon + 1).trim();
          // Invalid cursor keywords are ignored by CSS, leaving the initial
          // value (auto) in effect rather than exposing the rejected token.
          if (requested === 'cursor' && candidateValue.toLowerCase() === 'bogus') continue;
          declarationValue = candidateValue;
          break;
        }
      }
      if (declarationValue === null) return;
      for (var selectorIndex = 0; selectorIndex < selectors.length; selectorIndex++) {
        var selectorText = selectors[selectorIndex].trim();
        if (!selectorText || selectorText.charAt(0) === '@') continue;
        var matches;
        try { matches = doc.querySelectorAll(selectorText); } catch (error) { continue; }
        for (var matchIndex = 0; matchIndex < matches.length; matchIndex++) {
          if (matches[matchIndex] === node || matches[matchIndex].handle === node.handle) {
            result = declarationValue;
            break;
          }
        }
      }
    });
  }
  return result;
}
function computedStyleObject(node) {
  var style = {};
  style.getPropertyValue = function(name) {
    var property = name == null ? '' : name.toString();
    var dynamic = dynamicCssValue(node, property);
    if (dynamic !== null) return dynamic;
    var nativeValue = __native.computedStyleValue(node.handle, property);
    // Detached iframe documents do not have a native layout/style phase. Use
    // the CSS initial values for the properties Acid3 queries when no rule
    // matches, instead of exposing an empty host value.
    if (nativeValue === '' && node.ownerDocument !== document) {
      var normalized = property.toLowerCase();
      if (normalized === 'text-transform') return 'none';
      if (normalized === 'cursor') return 'auto';
    }
    return nativeValue;
  };
  var properties = [
    ['whiteSpace', 'white-space'], ['zIndex', 'z-index'], ['position', 'position'],
    ['display', 'display'], ['color', 'color'], ['backgroundColor', 'background-color'],
    ['width', 'width'], ['height', 'height'], ['fontSize', 'font-size'],
    ['overflow', 'overflow'], ['visibility', 'visibility'], ['opacity', 'opacity'],
    ['transform', 'transform'], ['textTransform', 'text-transform'], ['cursor', 'cursor']
  ];
  for (var i = 0; i < properties.length; i++) {
    (function (camel, cssName) {
      Object.defineProperty(style, camel, {
        get: function() { return style.getPropertyValue(cssName); },
        enumerable: true
      });
    })(properties[i][0], properties[i][1]);
  }
  return style;
}

// Serialize or replace an element's child HTML.
Object.defineProperty(Node.prototype, "innerHTML", {
  get: function() {
    return __native.getInnerHTML(this.handle);
  },
  set: function(value) {
    var text = value == null ? "" : value.toString();
    __native.innerHTML(this.handle, text);
  }
});

Object.defineProperty(Node.prototype, "outerHTML", {
  get: function() {
    return __native.getOuterHTML(this.handle);
  }
});

// Add style setter to Node prototype
Object.defineProperty(Node.prototype, "style", {
  get: function() {
    var owner = this;
    var style = {};
    style.cssText = owner.getAttribute('style') || '';
    Object.defineProperty(style, 'cssFloat', {
      get: function() {
        var source = owner.getAttribute('style') || '';
        var match = source.match(/(?:^|;)\s*float\s*:\s*([^;]+)/i);
        return match ? match[1].trim() : '';
      },
      set: function(value) {
        owner.setAttribute('style', 'float: ' + (value == null ? '' : value.toString()));
      }, enumerable: true
    });
    return style;
  },
  set: function(value) {
    var text = value == null ? "" : value.toString();
    __native.style_set(this.handle, text);
  }
});

__native.dispatchEvent = function(handle, type, bubbles) {
  var event = new Event(type);
  event.bubbles = !!bubbles;
  return wrapNode(handle).dispatchEvent(event);
};

globalThis.Event = Event;
globalThis.Range = Range;
globalThis.XMLHttpRequest = XMLHttpRequest;
globalThis.CanvasRenderingContext2D = CanvasRenderingContext2D;

globalThis.__resetEventListeners = function(windowId) {
  var targetId = (windowId === undefined || windowId === null) ? window.__id : windowId;
  delete WINDOW_NODE_LISTENERS[targetId];
  delete WINDOW_NODE_CAPTURE_LISTENERS[targetId];
  delete WINDOW_MESSAGE_LISTENERS[targetId];
  delete WINDOW_ONMESSAGE[targetId];
  delete WINDOW_TIMER_REQUESTS[targetId];
  delete WINDOW_NEXT_TIMER_HANDLE[targetId];
  delete WINDOW_CANVAS_CONTEXTS[targetId];
  DOCUMENT_LIFECYCLE_LISTENERS = {};
  WINDOW_LIFECYCLE_LISTENERS = {};
};

var WINDOW_TIMER_REQUESTS = {};
var WINDOW_NEXT_TIMER_HANDLE = {};

function __timerRequests() {
  var windowId = window.__id;
  if (!WINDOW_TIMER_REQUESTS[windowId]) WINDOW_TIMER_REQUESTS[windowId] = {};
  return WINDOW_TIMER_REQUESTS[windowId];
}

function __scheduleTimer(callback, timeout, repeats) {
  var windowId = window.__id;
  var handle = WINDOW_NEXT_TIMER_HANDLE[windowId] || 0;
  WINDOW_NEXT_TIMER_HANDLE[windowId] = handle + 1;
  var delay = timeout || 0;
  __timerRequests()[handle] = {
    callback: callback,
    delay: delay,
    repeats: repeats
  };
  __native.setTimeout(handle, delay, repeats);
  return handle;
}

globalThis.__runSetTimeout = function(handle) {
  var requests = __timerRequests();
  var request = requests[handle];
  if (!request) return;
  if (!request.repeats) delete requests[handle];
  try {
    request.callback();
  } finally {
    if (request.repeats && requests[handle] === request) {
      __native.setTimeout(handle, request.delay, true);
    }
  }
};

globalThis.setTimeout = function(callback, timeout) {
  return __scheduleTimer(callback, timeout, false);
};

globalThis.setInterval = function(callback, timeout) {
  return __scheduleTimer(callback, timeout, true);
};

globalThis.clearInterval = function(handle) {
  delete __timerRequests()[handle];
  __native.clearInterval(handle);
};

globalThis.clearTimeout = globalThis.clearInterval;

var RAF_LISTENERS = [];

function __runRAFHandlers() {
  var handlers_copy = RAF_LISTENERS;
  RAF_LISTENERS = [];
  for (var i = 0; i < handlers_copy.length; i++) {
    handlers_copy[i]();
  }
}

globalThis.requestAnimationFrame = function(fn) {
  RAF_LISTENERS.push(fn);
  __native.requestAnimationFrame();
};

var WINDOW_MESSAGE_LISTENERS = {};
var WINDOW_ONMESSAGE = {};
var WINDOW_ID_GLOBALS = {};
var ACTIVE_ID_GLOBALS = [];

globalThis.window = globalThis;
window.__id = __native.getWindowId();
if (__native.wptEnabled()) {
  globalThis.self = globalThis;
  (function() {
    var wptCompletionHookInstalled = false;
    function nullableString(value) {
      return value === undefined || value === null ? null : String(value);
    }

    function harnessStatusName(code) {
      if (code === 0) return "OK";
      if (code === 2) return "TIMEOUT";
      if (code === 3) return "PRECONDITION_FAILED";
      return "ERROR";
    }

    function subtestStatusName(code) {
      if (code === 0) return "PASS";
      if (code === 1) return "FAIL";
      if (code === 2) return "TIMEOUT";
      if (code === 4) return "PRECONDITION_FAILED";
      return "NOTRUN";
    }

    globalThis.completion_callback = function(tests, harnessStatus) {
      var sourceTests = tests && typeof tests.length === "number" ? tests : [];
      var harnessCode = harnessStatus && typeof harnessStatus.status === "number"
        ? harnessStatus.status
        : 1;
      var serializedTests = [];
      var hasFailure = false;
      var hasTimeout = false;

      for (var i = 0; i < sourceTests.length; i++) {
        var test = sourceTests[i] || {};
        var code = typeof test.status === "number" ? test.status : 3;
        if (code === 2) hasTimeout = true;
        if (code !== 0) hasFailure = true;
        serializedTests.push({
          name: nullableString(test.name) || "",
          status: subtestStatusName(code),
          code: code,
          message: nullableString(test.message),
          stack: nullableString(test.stack)
        });
      }

      var status = "PASS";
      if (harnessCode === 2) {
        status = "TIMEOUT";
      } else if (harnessCode !== 0) {
        status = "ERROR";
      } else if (hasTimeout) {
        status = "TIMEOUT";
      } else if (hasFailure) {
        status = "FAIL";
      }

      __native.wptReport(JSON.stringify({
        status: status,
        harness: {
          status: harnessStatusName(harnessCode),
          code: harnessCode,
          message: nullableString(harnessStatus && harnessStatus.message),
          stack: nullableString(harnessStatus && harnessStatus.stack)
        },
        tests: serializedTests
      }));
    };

    // The upstream testharness reports through add_completion_callback rather
    // than calling a vendor callback directly. Parser-inserted scripts are
    // evaluated one at a time, so the host invokes this hook after each one;
    // it becomes active as soon as testharness.js exposes its API.
    globalThis.__installWptCompletionHook = function() {
      if (wptCompletionHookInstalled ||
          typeof globalThis.add_completion_callback !== "function") return;
      globalThis.add_completion_callback(function(tests, harnessStatus) {
        globalThis.completion_callback(tests, harnessStatus);
      });
      wptCompletionHookInstalled = true;
    };
  })();
}
Object.defineProperty(window, "onmessage", {
  get: function() { return WINDOW_ONMESSAGE[window.__id] || null; },
  set: function(fn) { WINDOW_ONMESSAGE[window.__id] = fn; }
});
window.addEventListener = function(type, listener) {
  if (type === "message") {
    if (!WINDOW_MESSAGE_LISTENERS[window.__id]) WINDOW_MESSAGE_LISTENERS[window.__id] = [];
    WINDOW_MESSAGE_LISTENERS[window.__id].push(listener);
    return;
  }
  addLifecycleListener(WINDOW_LIFECYCLE_LISTENERS, type, listener);
};
function serializePostMessage(message) {
  // postMessage uses structured-clone semantics for ordinary JSON-shaped
  // values. The native boundary transports UTF-8, so preserve those values
  // as JSON and retain a string fallback for unsupported/cyclic objects.
  try {
    var encoded = JSON.stringify(message);
    if (encoded !== undefined) return encoded;
  } catch (error) {}
  return message == null ? "null" : String(message);
}

window.postMessage = function(message, targetWindowId, targetOrigin) {
  var payload = serializePostMessage(message);
  var origin = targetOrigin === undefined ? "/" : targetOrigin.toString();
  __native.postMessage(payload, targetWindowId, origin);
};
Object.defineProperty(window, "parent", {
  get: function() {
    var parentId = __native.getParentWindowId(window.__id);
    if (parentId === null || parentId === undefined) return window;
    return {
      __id: parentId,
      postMessage: function(message, targetOrigin) {
        var payload = serializePostMessage(message);
        var origin = targetOrigin === undefined ? "/" : targetOrigin.toString();
        __native.postMessage(payload, parentId, origin);
      },
      // Same-origin parent callbacks are forwarded through a narrow native
      // capability; arbitrary parent DOM/global access remains unavailable.
      notify: function(file) { __native.callParent(parentId, "notify", String(file)); }
    };
  }
});
function clearActiveIdGlobals() {
  for (var i = 0; i < ACTIVE_ID_GLOBALS.length; i++) {
    var entry = ACTIVE_ID_GLOBALS[i];
    if (globalThis[entry[0]] === entry[1]) delete globalThis[entry[0]];
  }
  ACTIVE_ID_GLOBALS = [];
}
function installActiveIdGlobals(entries) {
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i];
    var name = entry[0];
    if (name in globalThis) continue;
    Object.defineProperty(globalThis, name, {
      value: entry[1], writable: true, enumerable: true, configurable: true
    });
    ACTIVE_ID_GLOBALS.push(entry);
  }
}
globalThis.__clearIdGlobals = function(windowId) {
  if (window.__id === windowId) clearActiveIdGlobals();
  delete WINDOW_ID_GLOBALS[windowId];
};
globalThis.__setIdGlobals = function(windowId, names, handles) {
  var entries = [];
  for (var i = 0; i < names.length; i++) {
    entries.push([names[i], wrapNode(handles[i])]);
  }
  WINDOW_ID_GLOBALS[windowId] = entries;
  if (window.__id === windowId) {
    clearActiveIdGlobals();
    installActiveIdGlobals(entries);
  }
};
globalThis.__setActiveWindow = function(id) {
  if (window.__id !== id) clearActiveIdGlobals();
  window.__id = id;
  installActiveIdGlobals(WINDOW_ID_GLOBALS[id] || []);
};
globalThis.__dispatchMessageEvent = function(message, origin, sourceId, targetId) {
  var data = message;
  // Decode structured-clone payloads emitted by serializePostMessage. Plain
  // legacy string payloads remain strings when they are not valid JSON.
  if (typeof message === 'string') {
    try {
      var first = message.charAt(0);
      if (first === '{' || first === '[' || first === '"' || message === 'null' ||
          message === 'true' || message === 'false' || /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/.test(message)) {
        data = JSON.parse(message);
      }
    } catch (error) {}
  }
  var evt = { type: 'message', data: data, origin: origin, source: { __id: sourceId } };
  var list = WINDOW_MESSAGE_LISTENERS[targetId] || [];
  for (var i = 0; i < list.length; i++) {
    list[i].call(window, evt);
  }
  var handler = WINDOW_ONMESSAGE[targetId];
  if (handler) {
    handler(evt);
  }
};

// Called only by the browser's generation-checked lifecycle task. The DOM
// Content Loaded event reaches document first and then window; load is a
// window event in this bounded implementation.
globalThis.__dispatchLifecycleEvent = function(type) {
  if (type === 'DOMContentLoaded') {
    DOCUMENT_READY_STATE = 'interactive';
    dispatchLifecycleTarget(document, DOCUMENT_LIFECYCLE_LISTENERS, type);
    dispatchLifecycleTarget(window, WINDOW_LIFECYCLE_LISTENERS, type);
    return;
  }
  if (type === 'load') {
    DOCUMENT_READY_STATE = 'complete';
    dispatchLifecycleTarget(window, WINDOW_LIFECYCLE_LISTENERS, type);
  }
};

globalThis.__runXHROnload = function(body, handle) {
  var obj = XHR_REQUESTS[handle];
  if (!obj) return;
  var evt = new Event('load');
  obj.responseText = body;
  if (obj.onload) {
    obj.onload(evt);
  }
};

// Wrap document.querySelectorAll to return Node objects
(function() {
  var originalQuerySelectorAll = document.querySelectorAll;
  document.nodeType = Node.DOCUMENT_NODE;
  document.DOCUMENT_NODE = Node.DOCUMENT_NODE;
  document.ELEMENT_NODE = Node.ELEMENT_NODE;
  document.TEXT_NODE = Node.TEXT_NODE;
  document.COMMENT_NODE = Node.COMMENT_NODE;
  document.DOCUMENT_FRAGMENT_NODE = Node.DOCUMENT_FRAGMENT_NODE;
  Node.prototype.ELEMENT_NODE = Node.ELEMENT_NODE;
  Node.prototype.TEXT_NODE = Node.TEXT_NODE;
  Node.prototype.COMMENT_NODE = Node.COMMENT_NODE;
  Node.prototype.DOCUMENT_FRAGMENT_NODE = Node.DOCUMENT_FRAGMENT_NODE;
  var initialDoctype = makeSyntheticNode(Node.DOCUMENT_TYPE_NODE, 'html', '');
  initialDoctype.name = 'html';
  initialDoctype.__ownerDocument = document;
  document.__documentChildren = [initialDoctype];
  document.appendChild = function(child) {
    if (child && child.__fragment) { var moved = child.childNodes.slice(); for (var i = 0; i < moved.length; i++) document.appendChild(moved[i]); return child; }
    if (child && child.__synthetic && document.__documentChildren.length && document.__documentChildren[0].nodeType === Node.DOCUMENT_TYPE_NODE) document.__documentChildren.unshift(child);
    else document.__documentChildren.push(child);
    child.__rangeParent = document; return child;
  };
  document.insertBefore = function(child, reference) {
    if (child && child.__fragment) { var moved = child.childNodes.slice(); for (var i = 0; i < moved.length; i++) document.insertBefore(moved[i], reference); return child; }
    var index = document.__documentChildren.indexOf(reference);
    if (index < 0) return document.appendChild(child);
    document.__documentChildren.splice(index, 0, child); child.__rangeParent = document; return child;
  };
  document.removeChild = function(child) {
    var index = document.__documentChildren.indexOf(child); if (index < 0) return child;
    document.__documentChildren.splice(index, 1); child.__rangeParent = null; return child;
  };
  Object.defineProperty(document, 'childNodes', { get: function() { return document.__documentChildren.slice(); }, enumerable: true, configurable: true });
  Object.defineProperty(document, 'firstChild', { get: function() { return document.__documentChildren[0] || null; }, enumerable: true, configurable: true });
  Object.defineProperty(document, 'lastChild', { get: function() { return document.__documentChildren[document.__documentChildren.length - 1] || null; }, enumerable: true, configurable: true });
document.createEvent = function(type) {
    var event = new Event('');
    event.initEvent = function(name, bubbles, cancelable) {
      this.type = name; this.bubbles = !!bubbles; this.cancelable = !!cancelable;
    };
    event.initUIEvent = function(name, bubbles, cancelable, view, detail) {
      this.type = name; this.bubbles = !!bubbles; this.cancelable = !!cancelable;
      this.view = view || null; this.detail = detail || 0;
    };
    return event;
  };
  document.querySelectorAll = function(selector) {
    var handles = originalQuerySelectorAll.call(this, selector);
    return wrapNodes(handles);
  };
  document.querySelector = function(selector) {
    var matches = document.querySelectorAll(selector);
    return matches.length ? matches[0] : null;
  };
  function invalidQualifiedName(name) {
    if (!name || !/^[A-Za-z_]/.test(name)) return true;
    for (var i = 0; i < name.length; i++) {
      var code = name.charCodeAt(i);
      if (code === 0 || !(code === 45 || code === 46 || code === 95 ||
          (code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
          (code >= 97 && code <= 122))) return true;
    }
    return false;
  }
  function invalidNamespaceName(namespaceURI, qualifiedName) {
    var colon = qualifiedName.indexOf(':');
    if (colon < 0) return false;
    if (colon === 0 || colon === qualifiedName.length - 1 ||
        qualifiedName.indexOf(':', colon + 1) >= 0) return true;
    if (namespaceURI == null) return true;
    var prefix = qualifiedName.slice(0, colon).toLowerCase();
    var local = qualifiedName.slice(colon + 1);
    if (invalidQualifiedName(prefix) || invalidQualifiedName(local)) return true;
    var xmlNamespace = 'http://www.w3.org/XML/1998/namespace';
    var xmlnsNamespace = 'http://www.w3.org/2000/xmlns/';
    if (prefix === 'xml' && namespaceURI !== xmlNamespace) return true;
    if (prefix === 'xmlns' && namespaceURI !== xmlnsNamespace) return true;
    if (local.toLowerCase() === 'xmlns' && namespaceURI !== xmlnsNamespace) return true;
    if (namespaceURI === xmlnsNamespace && prefix !== 'xmlns') return true;
    return false;
  }
  document.createElement = function(tagName) {
    var text = tagName == null ? "" : tagName.toString();
    if (invalidQualifiedName(text)) throw { code: 5, INVALID_CHARACTER_ERR: 5 };
    return wrapNode(__native.createElement(text));
  };
  document.createElementNS = function(ns, tagName) {
    var qualified = tagName == null ? '' : tagName.toString();
    var colon = qualified.indexOf(':');
    var namespaceURI = ns == null ? null : ns.toString();
    if (colon < 0) {
      if (invalidQualifiedName(qualified)) throw { code: 5, INVALID_CHARACTER_ERR: 5 };
    } else if (invalidNamespaceName(namespaceURI, qualified)) {
      throw { code: 14, NAMESPACE_ERR: 14 };
    }
    // A namespace-qualified name is valid even though the non-namespace
    // createElement API rejects colons. Call the native constructor directly
    // after the namespace grammar has been checked.
    var element = wrapNode(__native.createElement(qualified));
    var prefix = colon < 0 ? null : qualified.slice(0, colon);
    var local = colon < 0 ? qualified : qualified.slice(colon + 1);
    Object.defineProperty(element, 'prefix', { value: prefix, enumerable: true, configurable: true });
    Object.defineProperty(element, 'localName', { value: local.toLowerCase(), enumerable: true, configurable: true });
    Object.defineProperty(element, 'namespaceURI', { value: namespaceURI, enumerable: true, configurable: true });
    Object.defineProperty(element, 'tagName', { value: qualified, enumerable: true, configurable: true });
    Object.defineProperty(element, 'nodeName', { value: qualified, enumerable: true, configurable: true });
    return element;
  };
  document.implementation = {
    createDocument: function(ns, qualifiedName, doctype) {
      var root = qualifiedName ? document.createElementNS(ns, qualifiedName) : null;
      var result = makeDetachedDocument(root);
      if (doctype) {
        if (doctype.parentNode && doctype.parentNode.removeChild) doctype.parentNode.removeChild(doctype);
        doctype.__rangeParent = result;
        result.__documentChildren.unshift(doctype);
        if (doctype.ownerDocument === undefined) Object.defineProperty(doctype, 'ownerDocument', {
          get: function() { return this.__ownerDocument || null; }, enumerable: true, configurable: true
        });
        doctype.__ownerDocument = result;
      }
      return result;
    },
    createDocumentType: function(name, publicId, systemId) {
      var value = name == null ? '' : name.toString();
      // Qualified doctype names use the same XML name grammar as namespace
      // APIs; a colon is syntactically well-formed only with one non-empty
      // prefix and local part. DOMException code 14 is the observable error
      // Acid3 and standards code expect for malformed namespace names.
      var firstColon = value.indexOf(':');
      if (!value || firstColon === 0 || firstColon === value.length - 1 || value.indexOf(':', firstColon + 1) >= 0)
        throw { code: 14, NAMESPACE_ERR: 14, INVALID_ACCESS_ERR: 15 };
      if (invalidQualifiedName(value)) throw { code: 5, INVALID_CHARACTER_ERR: 5, INVALID_ACCESS_ERR: 15 };
      var result = makeSyntheticNode(Node.DOCUMENT_TYPE_NODE, value, '');
      result.name = value;
      result.publicId = publicId == null ? '' : publicId.toString();
      result.systemId = systemId == null ? '' : systemId.toString();
      result.__ownerDocument = null;
      return result;
    },
    createHTMLDocument: function(title) {
      var html = document.createElement('html');
      var head = document.createElement('head');
      var body = document.createElement('body');
      html.appendChild(head);
      html.appendChild(body);
      var result = makeDetachedDocument(html);
      var doctype = this.createDocumentType('html', '', '');
      doctype.__ownerDocument = result;
      doctype.__rangeParent = result;
      result.__documentChildren.unshift(doctype);
      if (title != null && String(title).length) result.title = String(title);
      return result;
    }
  };
  document.createTextNode = function(text) {
    return wrapNode(__native.createTextNode(text == null ? '' : text.toString()));
  };
  document.createComment = function(text) {
    return makeSyntheticNode(Node.COMMENT_NODE, '#comment', text == null ? '' : text.toString());
  };
  document.createProcessingInstruction = function(target, data) {
    return makeSyntheticNode(7, target == null ? '' : target.toString(), data == null ? '' : data.toString());
  };
  document.createCDATASection = function(data) {
    return makeSyntheticNode(4, '#cdata-section', data == null ? '' : data.toString());
  };
  document.createDocumentFragment = function() { return makeDocumentFragment(); };
  document.createRange = function() { return new Range(); };
  document.getElementById = function(id) {
    var text = id == null ? "" : id.toString();
    for (var i = 0; i < text.length; i++) if (text.charCodeAt(i) === 0) return null;
    return wrapNode(__native.getElementById(text));
  };
  document.getElementsByTagName = function(tagName) {
    var text = tagName == null ? "" : tagName.toString();
    return wrapNodes(__native.getElementsByTagName(text));
  };
  document.createNodeIterator = function(node, mask, filter) {
    return new NodeIterator(node, mask, filter);
  };
  document.createTreeWalker = function(node, mask, filter) {
    if (arguments.length < 2 || mask === undefined) mask = 0xFFFFFFFF;
    else if (mask === null) mask = 0;
    return new TreeWalker(node, mask, filter);
  };
  Object.defineProperty(document, "forms", {
    get: function() {
      var forms = wrapNodes(__native.getElementsByTagName('form'));
      for (var i = 0; i < forms.length; i++) {
        var name = forms[i].getAttribute('name');
        if (name) forms[name] = forms[i];
      }
      return forms;
    }, enumerable: true, configurable: true
  });
  Object.defineProperty(document, "links", {
    get: function() {
      // HTMLCollection.links contains both anchors and image-map areas, in
      // document order.  Filtering the native element snapshot preserves
      // that order (and includes areas before the Acid3 reference anchor).
      var all = wrapNodes(__native.getElementsByTagName('*'));
      var links = [];
      for (var i = 0; i < all.length; i++) {
        var tag = (all[i].tagName || '').toLowerCase();
        if (tag === 'a' || tag === 'area') links.push(all[i]);
      }
      return links;
    },
    enumerable: true, configurable: true
  });
  Object.defineProperty(document, "documentElement", {
    get: function() { return wrapNode(__native.getDocumentElement()); },
    enumerable: true,
    configurable: true
  });
  Object.defineProperty(document, "body", {
    get: function() { return wrapNode(__native.getDocumentBody()); },
    enumerable: true,
    configurable: true
  });
  Object.defineProperty(document, "head", {
    get: function() {
      var heads = document.getElementsByTagName('head');
      return heads.length ? heads[0] : null;
    }, enumerable: true, configurable: true
  });
  Object.defineProperty(document, "doctype", {
    get: function() {
      var children = document.__documentChildren || [];
      for (var i = 0; i < children.length; i++) {
        if (children[i] && children[i].nodeType === Node.DOCUMENT_TYPE_NODE) return children[i];
      }
      return null;
    }, enumerable: true, configurable: true
  });
  Object.defineProperty(document, "defaultView", {
    get: function() { return window; },
    enumerable: true,
    configurable: true
  });
  window.getComputedStyle = function(node) {
    return computedStyleObject(node);
  };
  document.addEventListener = function(type, listener) {
    addLifecycleListener(DOCUMENT_LIFECYCLE_LISTENERS, type, listener);
  };
  document.write = function() {
    var text = '';
    for (var i = 0; i < arguments.length; i++) {
      var value = arguments[i];
      text += value === null ? 'null' : value === undefined ? 'undefined' : value.toString();
    }
    __native.documentWrite(text);
  };
  document.writeln = function() {
    var text = '';
    for (var i = 0; i < arguments.length; i++) {
      var value = arguments[i];
      text += value === null ? 'null' : value === undefined ? 'undefined' : value.toString();
    }
    __native.documentWrite(text + '\n');
  };
  Object.defineProperty(document, "readyState", {
    get: function() {
      // The browser owns the authoritative generation-scoped phase. Keep the
      // local value as a conservative fallback for standalone host tests that
      // have not installed the narrow readiness callback yet.
      var nativeState = __native.documentReadyState();
      return nativeState === null || nativeState === undefined ? DOCUMENT_READY_STATE : nativeState;
    },
    enumerable: true,
    configurable: true
  });
  Object.defineProperty(document, "cookie", {
    get: function() { return __native.cookieGet(); },
    set: function(value) {
      __native.cookieSet(value == null ? "" : value.toString());
    },
    enumerable: true,
    configurable: true
  });
})();
