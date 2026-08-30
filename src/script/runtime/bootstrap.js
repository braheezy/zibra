// Zibra's page-visible JavaScript shims over the synchronous __native host.
// Node constructor that wraps a native identity. The cache below is the one
// canonical JavaScript wrapper for each identity in this document realm.
function Node(handle) {
  this.handle = handle;
}

var NODE_WRAPPERS = {};

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

Object.defineProperty(Node.prototype, "id", {
  get: function() { return this.getAttribute("id") || ""; },
  set: function(value) {
    this.setAttribute("id", value == null ? "" : value.toString());
  }
});

Node.prototype.appendChild = function(child) {
  __native.appendChild(this.handle, child && child.handle);
  return child;
};

Node.prototype.insertBefore = function(child, reference) {
  var referenceHandle = reference === null ? null : reference && reference.handle;
  __native.insertBefore(this.handle, child && child.handle, referenceHandle);
  return child;
};

Node.prototype.removeChild = function(child) {
  __native.removeChild(this.handle, child && child.handle);
  return child;
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
  get: function() { return wrapNode(__native.parentNode(this.handle)); }
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
  get: function() { return wrapNodes(__native.childNodes(this.handle)); }
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
  get: function() { return __native.nodeData(this.handle); }
});
Object.defineProperty(Node.prototype, "textContent", {
  get: function() { return __native.textContent(this.handle); }
});
Node.prototype.getElementsByTagName = function(tagName) {
  var text = tagName == null ? "" : tagName.toString();
  return wrapNodes(__native.getElementsByTagNameFrom(this.handle, text));
};

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
    return { __id: parentId, postMessage: function(message, targetOrigin) { var payload = message == null ? "null" : message.toString(); var origin = targetOrigin === undefined ? "/" : targetOrigin.toString(); __native.postMessage(payload, parentId, origin); } };
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
  document.querySelectorAll = function(selector) {
    var handles = originalQuerySelectorAll.call(this, selector);
    return wrapNodes(handles);
  };
  document.createElement = function(tagName) {
    var text = tagName == null ? "" : tagName.toString();
    return wrapNode(__native.createElement(text));
  };
  document.getElementById = function(id) {
    var text = id == null ? "" : id.toString();
    return wrapNode(__native.getElementById(text));
  };
  document.getElementsByTagName = function(tagName) {
    var text = tagName == null ? "" : tagName.toString();
    return wrapNodes(__native.getElementsByTagName(text));
  };
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
