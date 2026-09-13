// Realm-local live view over the Element's native ordered declaration owner.
// String conversion stays here; grammar, priority, storage and mutation are native.
var inlineStylePropertyNames = __native.cssPropertyNames();
var computedStylePropertyNames = __native.cssPropertyNames(false);
Object.defineProperty(globalThis, 'CSS', {
  value: {
    supports(property) {
      // Kiesel currently permits construction of concise methods.
      if (new.target) throw new TypeError('CSS.supports is not a constructor');
      if (arguments.length === 0) throw new TypeError('CSS.supports requires an argument');
      function cssString(value) {
        if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to a CSS string');
        return String(value);
      }
      var first = cssString(property);
      return arguments.length >= 2 ? __native.cssSupports(first, cssString(arguments[1])) : __native.cssSupports(first);
    },
    [Symbol.toStringTag]: 'CSS'
  }, writable: true, configurable: true
});
Object.defineProperty(CSS, Symbol.toStringTag, { writable: false, enumerable: false });
function createInlineStyleDeclaration(owner) {
  var style = {};
  Object.defineProperty(style, 'cssText', {
    get: function() { return __native.cssStyleQuery(owner.handle, 'text'); },
    set: function(value) { __native.cssStyleMutate(owner.handle, 'text', value == null ? '' : String(value)); },
    enumerable: true
  });
  Object.defineProperty(style, 'length', { get: function() { return __native.cssStyleQuery(owner.handle, 'length'); } });
  style[Symbol.iterator] = Array.prototype[Symbol.iterator];
  style.item = function(index) { return __native.cssStyleQuery(owner.handle, 'item', Number(index) >>> 0); };
  style.getPropertyValue = function(name) { return __native.cssStyleQuery(owner.handle, 'value', String(name)); };
  style.getPropertyPriority = function(name) { return __native.cssStyleQuery(owner.handle, 'priority', String(name)); };
  style.removeProperty = function(name) {
    name = String(name);
    var previous = style.getPropertyValue(name);
    __native.cssStyleMutate(owner.handle, 'remove', name);
    return previous;
  };
  style.setProperty = function(name, value, priority) {
    __native.cssStyleMutate(owner.handle, 'set', String(name), value == null ? '' : String(value), priority == null ? '' : String(priority));
  };
  function accessor(property, name) {
    Object.defineProperty(style, property, {
      get: function() { return style.getPropertyValue(name); },
      set: function(value) { style.setProperty(name, value); }, enumerable: true
    });
  }
  for (var i = 0; i < inlineStylePropertyNames.length; i++) {
    var name = inlineStylePropertyNames[i];
    accessor(name, name);
    var camel = name.replace(/-([a-z])/g, function(_, c) { return c.toUpperCase(); });
    if (camel !== name) accessor(camel, name);
  }
  accessor('cssFloat', 'float');
  return new Proxy(style, {
    get: function(target, name, receiver) {
      if (typeof name === 'string' && /^(0|[1-9][0-9]*)$/.test(name)) {
        return Number(name) < style.length ? style.item(Number(name)) : undefined;
      }
      return Reflect.get(target, name, receiver);
    }
  });
}
