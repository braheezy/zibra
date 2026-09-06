// Rectangle values own numbers, never a live Element or layout generation.
(function() {
  var rectData = new WeakMap();
  function data(rect) {
    var value = rectData.get(rect);
    if (!value) throw new TypeError('Illegal DOMRect receiver');
    return value;
  }
  function number(value) { return value === undefined ? 0 : +value; }
  function DOMRectReadOnly(x, y, width, height) {
    if (!new.target) throw new TypeError('DOMRectReadOnly requires new');
    rectData.set(this, [number(x), number(y), number(width), number(height)]);
  }
  function DOMRect(x, y, width, height) {
    if (!new.target) throw new TypeError('DOMRect requires new');
    rectData.set(this, [number(x), number(y), number(width), number(height)]);
  }
  DOMRect.prototype = Object.create(DOMRectReadOnly.prototype);
  Object.defineProperty(DOMRect.prototype, 'constructor', { value: DOMRect, writable: true, configurable: true });
  ['x', 'y', 'width', 'height'].forEach(function(name, index) {
    Object.defineProperty(DOMRectReadOnly.prototype, name, {
      get: function() { return data(this)[index]; }, enumerable: true, configurable: true
    });
    Object.defineProperty(DOMRect.prototype, name, {
      get: function() { return data(this)[index]; },
      set: function(value) { data(this)[index] = +value; }, enumerable: true, configurable: true
    });
  });
  ['top', 'right', 'bottom', 'left'].forEach(function(name, index) {
    Object.defineProperty(DOMRectReadOnly.prototype, name, {
      get: function() {
        var r = data(this);
        if (index === 0) return Math.min(r[1], r[1] + r[3]);
        if (index === 1) return Math.max(r[0], r[0] + r[2]);
        if (index === 2) return Math.max(r[1], r[1] + r[3]);
        return Math.min(r[0], r[0] + r[2]);
      }, enumerable: true, configurable: true
    });
  });
  DOMRectReadOnly.prototype.toJSON = function() {
    var r = data(this);
    return { x: r[0], y: r[1], width: r[2], height: r[3],
      top: this.top, right: this.right, bottom: this.bottom, left: this.left };
  };
  function fromRect(Constructor, rect) {
    if (rect === undefined || rect === null) rect = {};
    if (typeof rect !== 'object' && typeof rect !== 'function') throw new TypeError('Expected rectangle dictionary');
    return new Constructor(rect.x, rect.y, rect.width, rect.height);
  }
  DOMRectReadOnly.fromRect = function(rect) { return fromRect(DOMRectReadOnly, rect); };
  DOMRect.fromRect = function(rect) { return fromRect(DOMRect, rect); };
  Object.defineProperty(DOMRectReadOnly.prototype, Symbol.toStringTag, { value: 'DOMRectReadOnly', configurable: true });
  Object.defineProperty(DOMRect.prototype, Symbol.toStringTag, { value: 'DOMRect', configurable: true });
  globalThis.DOMRectReadOnly = DOMRectReadOnly;
  globalThis.DOMRect = DOMRect;

  var listData = new WeakMap();
  function DOMRectList() { throw new TypeError('Illegal constructor'); }
  function listItems(list) {
    var items = listData.get(list);
    if (!items) throw new TypeError('Illegal DOMRectList receiver');
    return items;
  }
  Object.defineProperty(DOMRectList.prototype, 'length', {
    get: function() { return listItems(this).length; }, enumerable: true, configurable: true
  });
  DOMRectList.prototype.item = function(index) {
    var items = listItems(this);
    if (!arguments.length) throw new TypeError('item requires an index');
    return items[(+index) >>> 0] || null;
  };
  DOMRectList.prototype[Symbol.iterator] = function() { return listItems(this)[Symbol.iterator](); };
  Object.defineProperty(DOMRectList.prototype, Symbol.toStringTag, { value: 'DOMRectList', configurable: true });
  globalThis.DOMRectList = DOMRectList;

  function rectangles(element, unscaled) {
    if (!element || !DOM_NODE_BRAND.has(element) || element.nodeType !== 1) throw new TypeError('Geometry requires an Element');
    var values = __native.elementRects(element.handle, unscaled);
    var items = [];
    for (var i = 0; i < values.length; i += 4)
      items.push(new DOMRect(values[i], values[i + 1], values[i + 2], values[i + 3]));
    return items;
  }
  function bounding(items, includeEmpty) {
    if (!items.length) return new DOMRect();
    var result = null;
    for (var i = 0; i < items.length; i++) {
      var r = items[i];
      if (!includeEmpty && (r.width === 0 || r.height === 0)) continue;
      if (!result) { result = DOMRect.fromRect(r); continue; }
      var left = Math.min(result.left, r.left), top = Math.min(result.top, r.top);
      var right = Math.max(result.right, r.right), bottom = Math.max(result.bottom, r.bottom);
      result = new DOMRect(left, top, right - left, bottom - top);
    }
    return result || DOMRect.fromRect(items[0]);
  }
  Node.prototype.getClientRects = function() {
    var items = rectangles(this, false);
    var list = Object.create(DOMRectList.prototype);
    listData.set(list, items);
    for (var i = 0; i < items.length; i++) Object.defineProperty(list, i, { value: items[i], enumerable: true });
    return list;
  };
  Node.prototype.getBoundingClientRect = function() { return bounding(rectangles(this, false), false); };
  ['offsetWidth', 'offsetHeight'].forEach(function(name, index) {
    Object.defineProperty(Node.prototype, name, {
      get: function() {
        var rect = bounding(rectangles(this, true), true);
        return Math.round(index ? rect.height : rect.width);
      }, enumerable: true, configurable: true
    });
  });
  ['clientLeft', 'clientTop', 'clientWidth', 'clientHeight', 'offsetLeft', 'offsetTop', 'offsetParent'].forEach(function(name, index) {
    Object.defineProperty(Node.prototype, name, {
      get: function() {
        if (!DOM_NODE_BRAND.has(this) || this.nodeType !== 1) throw new TypeError('Geometry requires an Element');
        var values = __native.elementMetrics(this.handle);
        return index === 6 ? (values[6] ? wrapNode(values[6]) : null) : Math.round(values[index]);
      }, enumerable: true, configurable: true
    });
  });
})();
