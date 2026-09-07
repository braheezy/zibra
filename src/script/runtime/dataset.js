// Realm-local live data-* views. Only wrappers are retained; native attribute
// storage, order, and style invalidation remain owned by the Element.
var DATASETS;
function initializeDataset() {
  DATASETS = new WeakMap();
  function DOMStringMap() { throw new TypeError('Illegal constructor'); }
  Object.defineProperty(DOMStringMap.prototype, Symbol.toStringTag, {
    value: 'DOMStringMap', configurable: true
  });
  globalThis.DOMStringMap = DOMStringMap;
}

function attributeName(node, value) {
  var name = domDataString(value), owner = node.ownerDocument;
  if (node.namespaceURI === 'http://www.w3.org/1999/xhtml' &&
      owner && owner.contentType === 'text/html') {
    name = name.replace(/[A-Z]/g, function(c) { return c.toLowerCase(); });
  }
  return name;
}
function validateAttributeName(name) {
  // DOM's attribute-local-name grammar, not the older XML Name grammar.
  if (!name.length || /[\0\t\n\f\r />=]/.test(name)) throw domException('InvalidCharacterError');
}
function datasetAttributeName(property) {
  return 'data-' + property.replace(/[A-Z]/g, function(c) { return '-' + c.toLowerCase(); });
}
function datasetEntries(element) {
  var attributes = __native.attributes(element.handle) || [], entries = [];
  for (var i = 0; i < attributes.length; i++) {
    var attribute = attributes[i], name = attribute.name;
    if (name.slice(0, 5) !== 'data-' || /[A-Z]/.test(name.slice(5))) continue;
    entries.push({name: name.slice(5).replace(/-([a-z])/g, function(_, c) { return c.toUpperCase(); }), value: attribute.value});
  }
  return entries;
}
function datasetValue(element, property) {
  if (typeof property !== 'string') return undefined;
  var entries = datasetEntries(element);
  for (var i = 0; i < entries.length; i++) if (entries[i].name === property) return entries[i].value;
  return undefined;
}
function setDatasetValue(element, property, value) {
  // Web IDL converts the value before name validation (conversion can mutate
  // this same Element). Never cache a native entry across that conversion.
  value = domDataString(value);
  if (/-[a-z]/.test(property)) throw domException('SyntaxError');
  var name = datasetAttributeName(property);
  validateAttributeName(name);
  __native.setAttribute(element.handle, name, value);
}
function datasetGetter() {
  checkedRangeNode(this);
  if (!supportsDataset(this)) throw new TypeError('Receiver does not support dataset');
  var existing = DATASETS.get(this);
  if (existing) return existing;
  var element = this, target = Object.create(DOMStringMap.prototype);
  var proxy = new Proxy(target, {
    get: function(object, property, receiver) {
      var value = datasetValue(element, property);
      return value !== undefined ? value : Reflect.get(object, property, receiver);
    },
    has: function(object, property) {
      return datasetValue(element, property) !== undefined || Reflect.has(object, property);
    },
    getOwnPropertyDescriptor: function(object, property) {
      var value = datasetValue(element, property);
      return value !== undefined ? {value: value, writable: true, enumerable: true, configurable: true} :
        Reflect.getOwnPropertyDescriptor(object, property);
    },
    ownKeys: function(object) {
      var keys = datasetEntries(element).map(function(entry) { return entry.name; });
      Reflect.ownKeys(object).forEach(function(key) { if (keys.indexOf(key) < 0) keys.push(key); });
      return keys;
    },
    set: function(object, property, value, receiver) {
      if (receiver !== proxy || typeof property !== 'string') return Reflect.set(object, property, value, receiver);
      setDatasetValue(element, property, value);
      return true;
    },
    defineProperty: function(object, property, descriptor) {
      if (typeof property !== 'string') return Reflect.defineProperty(object, property, descriptor);
      if (!('value' in descriptor || 'writable' in descriptor)) return false;
      // A JS Proxy cannot expose a virtual configurable property after an
      // explicitly non-configurable definition. Reject before any mutation;
      // full Web IDL support here requires a native exotic object.
      if (descriptor.configurable === false) return false;
      setDatasetValue(element, property, descriptor.value);
      return true;
    },
    deleteProperty: function(object, property) {
      if (datasetValue(element, property) !== undefined) {
        __native.removeAttribute(element.handle, datasetAttributeName(property));
        return true;
      }
      return Reflect.deleteProperty(object, property);
    },
    preventExtensions: function() { return false; }
  });
  DATASETS.set(element, proxy);
  return proxy;
}
function supportsDataset(node) {
  if (node.nodeType !== Node.ELEMENT_NODE) return false;
  var ns = node.namespaceURI;
  return ns === 'http://www.w3.org/1999/xhtml' || ns === 'http://www.w3.org/2000/svg' ||
      ns === 'http://www.w3.org/1998/Math/MathML';
}
function updateDatasetInterface(node) {
  if (supportsDataset(node)) {
    Object.defineProperty(node, 'dataset', {get: datasetGetter, enumerable: true, configurable: true});
  } else {
    delete node.dataset;
  }
}
