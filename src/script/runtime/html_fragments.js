// Realm-local dynamic markup APIs. Parsing stays native; existing mutation
// boundaries transfer nodes without serializing/recreating surrounding content.
function htmlMarkupString(value, nullIsEmpty) {
  if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to a DOMString');
  return nullIsEmpty && value === null ? '' : String(value);
}

function requireMarkupElement(value) {
  if (!DOM_NODE_BRAND.has(value) || value.nodeType !== Node.ELEMENT_NODE)
    throw new TypeError('Expected an Element');
}

function htmlFragmentContainer(context, text) {
  var doc = context.ownerDocument || document;
  var tag = context.nodeType === Node.ELEMENT_NODE ? context.localName : 'body';
  var container = doc.createElement(tag);
  container.innerHTML = text;
  return container;
}

function insertParsedChildren(parent, reference, container) {
  while (container.firstChild) parent.insertBefore(container.firstChild, reference);
}

Object.defineProperty(Node.prototype, 'innerHTML', {
  get: function() { return __native.getInnerHTML(this.handle); },
  set: function(value) {
    requireMarkupElement(this);
    var text = htmlMarkupString(value, true);
    var removed = this.childNodes.slice();
    __native.innerHTML(this.handle, text);
    // Native replacement preserves published old subtrees. Drop logical parent
    // overrides only after it succeeds, and repair live wrapper/range views.
    for (var i = removed.length - 1; i >= 0; i--) {
      adjustRangesForRemoval(this, removed[i], i);
      removed[i].__rangeParent = null;
      if (removed[i].__synthetic) removed[i].parentNode = null;
    }
    this.__logicalChildren = null;
    if (this.__childNodeList) refreshNodeList(this.__childNodeList, childNodeValues(this));
    if (this.ownerDocument !== document) {
      var descendants = [];
      walkSnapshot(this, descendants);
      for (var j = 1; j < descendants.length; j++) descendants[j].__ownerDocument = this.ownerDocument;
    }
  }
});

Object.defineProperty(Node.prototype, 'outerHTML', {
  get: function() { return __native.getOuterHTML(this.handle); },
  set: function(value) {
    requireMarkupElement(this);
    var text = htmlMarkupString(value, true);
    var parent = this.parentNode;
    if (!parent) return;
    if (parent.nodeType === Node.DOCUMENT_NODE) throw domException('NoModificationAllowedError');
    var container = htmlFragmentContainer(parent, text);
    insertParsedChildren(parent, this, container);
    parent.removeChild(this);
  }
});

Node.prototype.insertAdjacentHTML = function(position, markup) {
  requireMarkupElement(this);
  if (arguments.length < 2) throw new TypeError('insertAdjacentHTML requires position and markup');
  position = htmlMarkupString(position, false).replace(/[A-Z]/g, function(c) { return c.toLowerCase(); });
  var text = htmlMarkupString(markup, false);
  var parent, reference;
  if (position === 'beforebegin' || position === 'afterend') {
    parent = this.parentNode;
    if (!parent || parent.nodeType === Node.DOCUMENT_NODE) throw domException('NoModificationAllowedError');
    reference = position === 'beforebegin' ? this : this.nextSibling;
  } else if (position === 'afterbegin' || position === 'beforeend') {
    parent = this;
    reference = position === 'afterbegin' ? this.firstChild : null;
  } else throw domException('SyntaxError');
  var context = parent;
  if (context.nodeType !== Node.ELEMENT_NODE ||
      (context.localName === 'html' && context.namespaceURI === 'http://www.w3.org/1999/xhtml'))
    context = (this.ownerDocument || document).createElement('body');
  insertParsedChildren(parent, reference, htmlFragmentContainer(context, text));
};
