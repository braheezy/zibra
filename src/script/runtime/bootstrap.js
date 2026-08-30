// Zibra's page-visible JavaScript shims over the synchronous __native host.
// Node constructor that wraps a native identity. The cache below is the one
// canonical JavaScript wrapper for each identity in this document realm.
function Node(handle) {
  this.handle = handle;
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
Node.TEXT_NODE = 3;
Node.DOCUMENT_NODE = 9;
Node.DOCUMENT_TYPE_NODE = 10;
Node.DOCUMENT_FRAGMENT_NODE = 11;
Node.COMMENT_NODE = 8;

globalThis.NodeFilter = {
  SHOW_ALL: 0xFFFFFFFF,
  SHOW_ELEMENT: 0x1,
  SHOW_TEXT: 0x4,
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
  if (node.nodeType === Node.ELEMENT_NODE) return !!(mask & 0x1);
  if (node.nodeType === Node.TEXT_NODE) return !!(mask & 0x4);
  if (node.nodeType === Node.COMMENT_NODE) return !!(mask & 0x80);
  return !!(mask & 0x20);
}

function filterResult(filter, node, mask) {
  if (!nodeShown(node, mask)) return 3;
  if (typeof filter !== 'function') return 1;
  var result = filter(node);
  if (result === true) return 1;
  var number = Number(result);
  return number === 1 ? 1 : number === 2 ? 2 : 3;
}

function NodeIterator(root, mask, filter) {
  this.root = root; this.mask = mask == null ? 0xFFFFFFFF : Number(mask);
  this.filter = filter; this.currentNode = null;
}
NodeIterator.prototype.nextNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var start = this.currentNode === null ? -1 : nodes.indexOf(this.currentNode);
  for (var i = start + 1; i < nodes.length; i++) {
    var result = filterResult(this.filter, nodes[i], this.mask);
    if (result === 1) { this.currentNode = nodes[i]; return nodes[i]; }
  }
  return null;
};
NodeIterator.prototype.previousNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var start = this.currentNode === null ? nodes.length : nodes.indexOf(this.currentNode);
  if (start < 0) start = nodes.length;
  for (var i = start - 1; i >= 0; i--) {
    var result = filterResult(this.filter, nodes[i], this.mask);
    if (result === 1) { this.currentNode = nodes[i]; return nodes[i]; }
  }
  return null;
};

function TreeWalker(root, mask, filter) {
  this.root = root; this.mask = mask == null ? 0xFFFFFFFF : Number(mask);
  this.filter = filter; this.currentNode = root;
}
TreeWalker.prototype.__children = function(node) { return node.childNodes || []; };
TreeWalker.prototype.firstChild = function() {
  var children = this.__children(this.currentNode);
  for (var i = 0; i < children.length; i++) {
    var result = filterResult(this.filter, children[i], this.mask);
    if (result === 1) { this.currentNode = children[i]; return children[i]; }
    if (result === 3) {
      var nested = new TreeWalker(children[i], this.mask, this.filter);
      var found = nested.nextNode();
      if (found) { this.currentNode = found; return found; }
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
      var nested = new TreeWalker(children[i], this.mask, this.filter);
      var found = nested.lastDescendant();
      if (found) { this.currentNode = found; return found; }
    }
  }
  return null;
};
TreeWalker.prototype.lastDescendant = function() {
  var children = this.__children(this.currentNode);
  for (var i = children.length - 1; i >= 0; i--) {
    var result = filterResult(this.filter, children[i], this.mask);
    if (result === 1) {
      var nested = new TreeWalker(children[i], this.mask, this.filter);
      var deeper = nested.lastDescendant();
      return deeper || children[i];
    }
  }
  return null;
};
TreeWalker.prototype.parentNode = function() {
  var parent = this.currentNode.parentNode;
  while (parent && parent !== this.root) {
    var result = filterResult(this.filter, parent, this.mask);
    if (result === 1) { this.currentNode = parent; return parent; }
    parent = parent.parentNode;
  }
  if (parent === this.root) { var result = filterResult(this.filter, parent, this.mask); if (result === 1) { this.currentNode = parent; return parent; } }
  return null;
};
TreeWalker.prototype.nextSibling = function() {
  var sibling = this.currentNode.nextSibling;
  while (sibling) {
    var result = filterResult(this.filter, sibling, this.mask);
    if (result === 1) { this.currentNode = sibling; return sibling; }
    sibling = sibling.nextSibling;
  }
  return null;
};
TreeWalker.prototype.previousSibling = function() {
  var sibling = this.currentNode.previousSibling;
  while (sibling) {
    var result = filterResult(this.filter, sibling, this.mask);
    if (result === 1) { this.currentNode = sibling; return sibling; }
    sibling = sibling.previousSibling;
  }
  return null;
};
TreeWalker.prototype.nextNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var index = nodes.indexOf(this.currentNode);
  for (var i = index + 1; i < nodes.length; i++) {
    var result = filterResult(this.filter, nodes[i], this.mask);
    if (result === 1) { this.currentNode = nodes[i]; return nodes[i]; }
  }
  return null;
};
TreeWalker.prototype.previousNode = function() {
  var nodes = []; walkSnapshot(this.root, nodes);
  var index = nodes.indexOf(this.currentNode);
  for (var i = index - 1; i >= 0; i--) {
    var result = filterResult(this.filter, nodes[i], this.mask);
    if (result === 1) { this.currentNode = nodes[i]; return nodes[i]; }
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

function listenersForWindow(windowId) {
  if (!WINDOW_NODE_LISTENERS[windowId]) WINDOW_NODE_LISTENERS[windowId] = {};
  return WINDOW_NODE_LISTENERS[windowId];
}

Node.prototype.addEventListener = function(type, listener) {
  var listeners = listenersForWindow(window.__id);
  if (!listeners[this.handle]) listeners[this.handle] = {};
  var dict = listeners[this.handle];
  if (!dict[type]) dict[type] = [];
  var list = dict[type];
  list.push(listener);
};

function dispatchNodeEvent(target, event, inlineHandler) {
  var path = event.bubbles ? __native.eventPath(target.handle) : [target.handle];
  var listeners = listenersForWindow(window.__id);
  event.propagation_stopped = false;
  event.target = path.length ? wrapNode(path[0]) : target;
  for (var pathIndex = 0; pathIndex < path.length; pathIndex++) {
    var currentTarget = wrapNode(path[pathIndex]);
    event.currentTarget = currentTarget;
    var dict = listeners[path[pathIndex]];
    var list = (dict && dict[event.type]) || [];
    for (var listenerIndex = 0; listenerIndex < list.length; listenerIndex++) {
      list[listenerIndex].call(currentTarget, event);
    }
    // An authored handler is an event handler on its element, after ordinary
    // target listeners. It remains a same-target delivery even when a target
    // listener stopped propagation, but never runs on bubbling ancestors.
    if (pathIndex === 0 && typeof inlineHandler === 'function') {
      try {
        if (inlineHandler.call(currentTarget, event) === false) event.preventDefault();
      } catch (error) {}
    }
    if (event.propagation_stopped) break;
  }
  event.currentTarget = null;
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
  if (!child || typeof child.handle !== 'number') {
    if (this.__documentChildren) {
      this.__documentChildren.push(child);
      child.__rangeParent = this;
      return child;
    }
    if (child && child.__synthetic) {
      if (!this.__syntheticChildren) this.__syntheticChildren = [];
      this.__syntheticChildren.push(child); child.__rangeParent = this; return child;
    }
    throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
  }
  if (child && isAncestorNode(child, this)) throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
  if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
  __native.appendChild(this.handle, child && child.handle);
  child.__rangeParent = this;
  return child;
};

Node.prototype.insertBefore = function(child, reference) {
  if (child && child.__fragment) {
    var moved = child.childNodes.slice();
    for (var fi = 0; fi < moved.length; fi++) this.insertBefore(moved[fi], reference);
    return child;
  }
  if (!child || typeof child.handle !== 'number') {
    if (child && child.__synthetic) {
      if (!this.__syntheticChildren) this.__syntheticChildren = [];
      var syntheticIndex = reference ? this.__syntheticChildren.indexOf(reference) : -1;
      if (syntheticIndex < 0) this.__syntheticChildren.push(child); else this.__syntheticChildren.splice(syntheticIndex, 0, child);
      child.__rangeParent = this; return child;
    }
    throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
  }
  if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
  var referenceHandle = reference === null ? null : reference && reference.handle;
  __native.insertBefore(this.handle, child && child.handle, referenceHandle);
  child.__rangeParent = this;
  return child;
};

Node.prototype.removeChild = function(child) {
  if (this.__documentChildren) {
    var index = this.__documentChildren.indexOf(child);
    if (index < 0) throw new Error('NotFoundError');
    this.__documentChildren.splice(index, 1);
    child.__rangeParent = null;
    return child;
  }
  if (child && child.__synthetic && this.__syntheticChildren) {
    var syntheticIndex = this.__syntheticChildren.indexOf(child);
    if (syntheticIndex < 0) throw new Error('NotFoundError');
    this.__syntheticChildren.splice(syntheticIndex, 1); child.__rangeParent = null; return child;
  }
  __native.removeChild(this.handle, child && child.handle);
  child.__rangeParent = null;
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
Object.defineProperty(Node.prototype, "previousSibling", {
  get: function() { return wrapNode(__native.previousSibling(this.handle)); }
});
Object.defineProperty(Node.prototype, "nextSibling", {
  get: function() { return wrapNode(__native.nextSibling(this.handle)); }
});
Object.defineProperty(Node.prototype, "childNodes", {
  get: function() {
    var result = wrapNodes(__native.childNodes(this.handle));
    if (this.__syntheticChildren) result = result.concat(this.__syntheticChildren);
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
  get: function() { return __native.nodeData(this.handle); },
  set: function(value) { __native.setNodeData(this.handle, value == null ? '' : value.toString()); }
});
Object.defineProperty(Node.prototype, "textContent", {
  get: function() { return __native.textContent(this.handle); }
});
Object.defineProperty(Node.prototype, "ownerDocument", {
  get: function() { return this.__ownerDocument || document; }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "className", {
  get: function() { return this.getAttribute("class") || ""; },
  set: function(value) { this.setAttribute("class", value == null ? "" : value.toString()); },
  enumerable: true, configurable: true
});

// Form state properties are reflected into the live attribute map so CSS
// state selectors (:checked, :enabled, :disabled) and native controls observe
// script mutations exactly like markup-authored state.
Object.defineProperty(Node.prototype, "type", {
  get: function() { return this.getAttribute("type") || "text"; },
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
  set: function(value) { if (value) this.setAttribute("checked", ""); else this.removeAttribute("checked"); },
  enumerable: true, configurable: true
});
Node.prototype.click = function() {
  var event = new Event("click");
  event.bubbles = true;
  if (!this.dispatchEvent(event)) return;
  if (this.nodeType !== Node.ELEMENT_NODE || (this.tagName || "").toLowerCase() !== "input") return;
  var kind = (this.type || "text").toLowerCase();
  if (kind === "checkbox") {
    this.checked = !this.checked;
  } else if (kind === "radio") {
    var group = document.getElementsByTagName("input");
    var name = this.getAttribute("name");
    for (var i = 0; i < group.length; i++) {
      var other = group[i];
      if (other !== this && (other.type || "text").toLowerCase() === "radio" &&
          ((name === null && other.getAttribute("name") === null) ||
           (name !== null && other.getAttribute("name") === name))) other.checked = false;
    }
    this.checked = true;
  }
};
Node.prototype.getElementsByTagName = function(tagName) {
  var text = tagName == null ? "" : tagName.toString();
  return wrapNodes(__native.getElementsByTagNameFrom(this.handle, text));
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
    data: value || '', nodeValue: value || '', textContent: value || '', childNodes: [], children: []
  };
  node.firstChild = null; node.lastChild = null; node.parentNode = null;
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
    return range.endContainer === node && range.endOffset === 0 ? shallowCloneNode(node) : null;
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
Range.prototype.setStart = function(node, offset) { this.startContainer = node; this.startOffset = Math.max(0, Number(offset) || 0); if (compareRangePoints(this.startContainer, this.startOffset, this.endContainer, this.endOffset) > 0) { this.endContainer = node; this.endOffset = this.startOffset; } };
Range.prototype.setEnd = function(node, offset) { this.endContainer = node; this.endOffset = Math.max(0, Number(offset) || 0); if (compareRangePoints(this.startContainer, this.startOffset, this.endContainer, this.endOffset) > 0) { this.startContainer = node; this.startOffset = this.endOffset; } };
Range.prototype.setStartBefore = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setStart(p, nodeIndexInParent(node)); };
Range.prototype.setStartAfter = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setStart(p, nodeIndexInParent(node) + 1); };
Range.prototype.setEndBefore = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setEnd(p, nodeIndexInParent(node)); };
Range.prototype.setEndAfter = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.setEnd(p, nodeIndexInParent(node) + 1); };
Range.prototype.selectNode = function(node) { var p = nodeParentForRange(node); if (!p) throw { code: 2, INVALID_NODE_TYPE_ERR: 2 }; this.startContainer = p; this.startOffset = nodeIndexInParent(node); this.endContainer = p; this.endOffset = this.startOffset + 1; };
Range.prototype.selectNodeContents = function(node) { this.startContainer = node; this.startOffset = 0; this.endContainer = node; this.endOffset = node.nodeType === Node.TEXT_NODE ? (node.data || '').length : nodeChildrenForRange(node).length; };
Range.prototype.collapse = function(toStart) { if (toStart) { this.endContainer = this.startContainer; this.endOffset = this.startOffset; } else { this.startContainer = this.endContainer; this.startOffset = this.endOffset; } };
Range.prototype.cloneRange = function() { var r = new Range(); r.startContainer = this.startContainer; r.startOffset = this.startOffset; r.endContainer = this.endContainer; r.endOffset = this.endOffset; return r; };
Range.prototype.cloneContents = function() { var f = makeDocumentFragment(); var root = this.commonAncestorContainer; if (root.nodeType === Node.TEXT_NODE) { var start = this.startContainer === root ? this.startOffset : 0; var end = this.endContainer === root ? this.endOffset : (root.data || '').length; if (end > start) f.appendChild(document.createTextNode((root.data || '').slice(start, end))); return f; } var children = nodeChildrenForRange(root); for (var i = 0; i < children.length; i++) { var c = cloneRangeNode(this, children[i], false, f); if (c) f.appendChild(c); } return f; };
Range.prototype.extractContents = function() { var f = makeDocumentFragment(); var root = this.commonAncestorContainer; if (root.nodeType === Node.TEXT_NODE) { var start = this.startContainer === root ? this.startOffset : 0; var end = this.endContainer === root ? this.endOffset : (root.data || '').length; if (end > start) { f.appendChild(document.createTextNode((root.data || '').slice(start, end))); if (root.handle) __native.setNodeData(root.handle, (root.data || '').slice(0, start) + (root.data || '').slice(end)); } this.collapse(true); return f; } var children = nodeChildrenForRange(root).slice(); for (var i = 0; i < children.length; i++) { var extracted = extractRangeNode(this, children[i]); if (extracted) f.appendChild(extracted); } this.collapse(true); return f; };
Range.prototype.deleteContents = function() { this.extractContents(); };
Range.prototype.insertNode = function(node) { var container = this.startContainer; if (container.nodeType === Node.TEXT_NODE) { var parent = nodeParentForRange(container); if (!parent) return; var before = container.data.slice(0, this.startOffset), after = container.data.slice(this.startOffset); __native.setNodeData(container.handle, before); var tail = document.createTextNode(after); var reference = container.nextSibling; if (node !== reference) parent.insertBefore(node, reference); var afterNode = node.nextSibling; if (afterNode) parent.insertBefore(tail, afterNode); else parent.appendChild(tail); return; } var children = nodeChildrenForRange(container), reference = children[this.startOffset] || null; if (reference) container.insertBefore(node, reference); else container.appendChild(node); };
Range.prototype.surroundContents = function(node) {
  if (this.startContainer && this.startContainer.nodeType === Node.COMMENT_NODE || this.endContainer && this.endContainer.nodeType === Node.COMMENT_NODE) throw { code: 1 };
  if (this.commonAncestorContainer && this.commonAncestorContainer.nodeType === Node.DOCUMENT_NODE && !this.collapsed) throw { code: 3, HIERARCHY_REQUEST_ERR: 3 };
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
  Object.defineProperty(doc, 'documentElement', { get: function() { return root; }, enumerable: true });
  doc.nodeType = Node.DOCUMENT_NODE;
  doc.appendChild = function(child) {
    if (child && child.__fragment) { var moved = child.childNodes.slice(); for (var i = 0; i < moved.length; i++) doc.appendChild(moved[i]); return child; }
    if (child.parentNode && child.parentNode.removeChild) child.parentNode.removeChild(child);
    doc.__documentChildren.push(child); child.__rangeParent = doc;
    adoptOwnerDocument(child);
    root = child.nodeType === Node.ELEMENT_NODE ? child : root;
    return child;
  };
  doc.removeChild = function(child) { var index = doc.__documentChildren.indexOf(child); if (index < 0) throw new Error('NotFoundError'); doc.__documentChildren.splice(index, 1); child.__rangeParent = null; return child; };
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
  doc.createDocumentFragment = function() { var fragment = makeDocumentFragment(); adoptOwnerDocument(fragment); return fragment; };
  doc.createRange = function() { return new Range(); };
  doc.getElementsByTagName = function(name) { return root ? root.getElementsByTagName(name) : []; };
  doc.getElementById = function(id) {
    if (!root) return null;
    var nodes = root.getElementsByTagName('*');
    for (var i = 0; i < nodes.length; i++) if (nodes[i].id === id) return nodes[i];
    return null;
  };
  doc.defaultView = window;
  doc.createNodeIterator = function(node, mask, filter) { return new NodeIterator(node, mask, filter); };
  doc.createTreeWalker = function(node, mask, filter) { return new TreeWalker(node, mask, filter); };
  return doc;
}

Object.defineProperty(Node.prototype, 'contentDocument', {
  get: function() {
    if (this.tagName !== 'IFRAME') return null;
    if (!IFRAME_DOCUMENTS[this.handle]) {
      var root = document.createElement('html');
      IFRAME_DOCUMENTS[this.handle] = makeDetachedDocument(root);
    }
    return IFRAME_DOCUMENTS[this.handle];
  }, enumerable: true, configurable: true
});
Object.defineProperty(Node.prototype, "elements", {
  get: function() {
    return this.getElementsByTagName('input');
  }, enumerable: true, configurable: true
});

// CSSOM's computed-style object is intentionally a lightweight live view in
// this bounded runtime. Property reads route through the native style map,
// while getPropertyValue accepts the canonical kebab-case spelling.
function computedStyleObject(node) {
  var style = {};
  style.getPropertyValue = function(name) {
    return __native.computedStyleValue(node.handle, name == null ? '' : name.toString());
  };
  var properties = [
    ['whiteSpace', 'white-space'], ['zIndex', 'z-index'], ['position', 'position'],
    ['display', 'display'], ['color', 'color'], ['backgroundColor', 'background-color'],
    ['width', 'width'], ['height', 'height'], ['fontSize', 'font-size'],
    ['overflow', 'overflow'], ['visibility', 'visibility'], ['opacity', 'opacity'],
    ['transform', 'transform']
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
window.postMessage = function(message, targetWindowId, targetOrigin) {
  var payload = message == null ? "null" : message.toString();
  var origin = targetOrigin === undefined ? "/" : targetOrigin.toString();
  __native.postMessage(payload, targetWindowId, origin);
};
Object.defineProperty(window, "parent", {
  get: function() {
    var parentId = __native.getParentWindowId(window.__id);
    if (parentId === null || parentId === undefined) return null;
    return {
      __id: parentId,
      postMessage: function(message, targetOrigin) {
        var payload = message == null ? "null" : message.toString();
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
  var evt = { type: 'message', data: message, origin: origin, source: { __id: sourceId } };
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
  document.__documentChildren = [{ nodeType: Node.DOCUMENT_TYPE_NODE, nodeName: 'html', name: 'html', ownerDocument: document }];
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
    return event;
  };
  document.querySelectorAll = function(selector) {
    var handles = originalQuerySelectorAll.call(this, selector);
    return wrapNodes(handles);
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
        throw { code: 14, NAMESPACE_ERR: 14 };
      if (invalidQualifiedName(value)) throw { code: 5, INVALID_CHARACTER_ERR: 5 };
      var result = {
        nodeType: Node.DOCUMENT_TYPE_NODE,
        nodeName: value,
        name: value,
        publicId: publicId == null ? '' : publicId.toString(),
        systemId: systemId == null ? '' : systemId.toString()
      };
      Object.defineProperty(result, 'ownerDocument', {
        get: function() { return this.__ownerDocument || null; }, enumerable: true, configurable: true
      });
      return result;
    }
  };
  document.createTextNode = function(text) {
    return wrapNode(__native.createTextNode(text == null ? '' : text.toString()));
  };
  document.createComment = function(text) {
    return makeSyntheticNode(Node.COMMENT_NODE, '#comment', text == null ? '' : text.toString());
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
    get: function() { return wrapNodes(__native.getElementsByTagName('a')); },
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
