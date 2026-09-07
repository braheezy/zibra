// Document tree accessors shared by live Window documents and detached trees.
// Keep no cached root/title/head/body pointers: every read follows current
// wrapper topology, and every write uses the existing native mutation boundary.
function documentElementMatches(node, namespace, localName) {
  return !!node && node.nodeType === Node.ELEMENT_NODE &&
      node.namespaceURI === namespace && node.localName === localName;
}

function firstDocumentChild(parent, predicate) {
  var children = parent ? parent.childNodes : [];
  for (var i = 0; i < children.length; i++) {
    if (predicate(children[i])) return children[i];
  }
  return null;
}

function documentChildText(node) {
  var text = '', children = node ? node.childNodes : [];
  for (var i = 0; i < children.length; i++) {
    // CDATASection inherits Text; comments and descendant element text are
    // deliberately excluded from the DOM's child-text-content algorithm.
    if (children[i].nodeType === Node.TEXT_NODE || children[i].nodeType === 4)
      text += children[i].data;
  }
  return text;
}

function htmlDocumentTitle(doc) {
  var pending = doc.childNodes.slice().reverse();
  while (pending.length) {
    var node = pending.pop();
    if (documentElementMatches(node, 'http://www.w3.org/1999/xhtml', 'title')) return node;
    var children = node.childNodes || [];
    for (var i = children.length - 1; i >= 0; i--) pending.push(children[i]);
  }
  return null;
}

function svgDocumentTitle(root) {
  return firstDocumentChild(root, function(node) {
    return documentElementMatches(node, 'http://www.w3.org/2000/svg', 'title');
  });
}

// Called only when a wrapper is created or its namespace metadata is installed.
// Foreign title elements must not acquire HTMLTitleElement's .text interface.
function updateElementInterfaces(node) {
  updateDatasetInterface(node);
  if (documentElementMatches(node, 'http://www.w3.org/1999/xhtml', 'meta')) {
    Object.defineProperty(node, 'content', {
      get: function() { return this.getAttribute('content') || ''; },
      set: function(value) {
        if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to DOMString');
        this.setAttribute('content', String(value));
      }, enumerable: true, configurable: true
    });
  }
  if (node.nodeType === Node.ELEMENT_NODE && node.namespaceURI === 'http://www.w3.org/1999/xhtml' &&
      ['a', 'area', 'iframe', 'img', 'link', 'script'].indexOf(node.localName) >= 0) {
    Object.defineProperty(node, 'referrerPolicy', {
      get: function() {
        var value = (this.getAttribute('referrerpolicy') || '').replace(/[A-Z]/g, function(c) { return c.toLowerCase(); });
        return ['no-referrer', 'no-referrer-when-downgrade', 'same-origin', 'origin',
          'strict-origin', 'origin-when-cross-origin', 'strict-origin-when-cross-origin', 'unsafe-url'].indexOf(value) >= 0 ? value : '';
      },
      set: function(value) {
        if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to DOMString');
        this.setAttribute('referrerpolicy', String(value));
      },
      enumerable: true, configurable: true
    });
  } else {
    delete node.referrerPolicy;
  }
  if (documentElementMatches(node, 'http://www.w3.org/1999/xhtml', 'title')) {
    Object.setPrototypeOf(node, HTMLTitleElement.prototype);
  } else if (Object.getPrototypeOf(node) === HTMLTitleElement.prototype) {
    Object.setPrototypeOf(node, Node.prototype);
  }
}

function initializeDocumentAccessors() {
  var htmlNamespace = 'http://www.w3.org/1999/xhtml';
  var svgNamespace = 'http://www.w3.org/2000/svg';
  function requireDocument(value) {
    if (!DOM_NODE_BRAND.has(value) || value.nodeType !== Node.DOCUMENT_NODE)
      throw new TypeError('Expected a Document');
  }
  function htmlChild(doc, names) {
    var root = doc.documentElement;
    if (!documentElementMatches(root, htmlNamespace, 'html')) return null;
    return firstDocumentChild(root, function(node) {
      return node.nodeType === Node.ELEMENT_NODE && node.namespaceURI === htmlNamespace &&
          names.indexOf(node.localName) >= 0;
    });
  }
  Object.defineProperties(Document.prototype, {
    referrer: {
      get: function() {
        requireDocument(this);
        return this === document ? __native.documentReferrer() : '';
      }, enumerable: true, configurable: true
    },
    documentElement: {
      get: function() {
        requireDocument(this);
        return firstDocumentChild(this, function(node) { return node.nodeType === Node.ELEMENT_NODE; });
      }, enumerable: true, configurable: true
    },
    head: {
      get: function() { requireDocument(this); return htmlChild(this, ['head']); },
      enumerable: true, configurable: true
    },
    body: {
      get: function() { requireDocument(this); return htmlChild(this, ['body', 'frameset']); },
      set: function(value) {
        requireDocument(this);
        if (value != null && (!DOM_NODE_BRAND.has(value) ||
            value.nodeType !== Node.ELEMENT_NODE || value.namespaceURI !== htmlNamespace))
          throw new TypeError('Expected an HTMLElement');
        if (!value || (value.localName !== 'body' && value.localName !== 'frameset'))
          throw domException('HierarchyRequestError');
        var body = this.body;
        if (body === value) return;
        if (body) body.parentNode.replaceChild(value, body);
        else {
          var root = this.documentElement;
          if (!root) throw domException('HierarchyRequestError');
          root.appendChild(value);
        }
      }, enumerable: true, configurable: true
    },
    title: {
      get: function() {
        requireDocument(this);
        var root = this.documentElement;
        var title = documentElementMatches(root, svgNamespace, 'svg') ?
            svgDocumentTitle(root) : htmlDocumentTitle(this);
        return documentChildText(title).replace(/[\t\n\f\r ]+/g, ' ').replace(/^ | $/g, '');
      },
      set: function(value) {
        requireDocument(this);
        // Web IDL DOMString conversion precedes all tree inspection, including
        // the no-op branches; null is "null", and a Symbol must throw.
        if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to DOMString');
        var text = String(value), root = this.documentElement, title;
        if (documentElementMatches(root, svgNamespace, 'svg')) {
          title = svgDocumentTitle(root);
          if (!title) {
            title = this.createElementNS(svgNamespace, 'title');
            root.insertBefore(title, root.firstChild);
          }
        } else if (root && root.namespaceURI === htmlNamespace) {
          title = htmlDocumentTitle(this);
          if (!title) {
            var head = this.head;
            if (!head) return;
            title = this.createElementNS(htmlNamespace, 'title');
            head.appendChild(title);
          }
        } else return;
        title.textContent = text;
      }, enumerable: true, configurable: true
    }
  });
  globalThis.HTMLTitleElement = function HTMLTitleElement() { throw new TypeError('Illegal constructor'); };
  HTMLTitleElement.prototype = Object.create(HTMLElement.prototype);
  Object.defineProperty(HTMLTitleElement.prototype, 'constructor', {
    value: HTMLTitleElement, writable: true, configurable: true
  });
  function requireTitle(value) {
    if (!DOM_NODE_BRAND.has(value) || !documentElementMatches(value, htmlNamespace, 'title'))
      throw new TypeError('Expected an HTMLTitleElement');
  }
  Object.defineProperty(HTMLTitleElement.prototype, 'text', {
    get: function() { requireTitle(this); return documentChildText(this); },
    set: function(value) {
      requireTitle(this);
      if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol to DOMString');
      this.textContent = String(value);
    }, enumerable: true, configurable: true
  });
}
