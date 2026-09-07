// Realm-local CharacterData algorithms. All offsets and slices are DOMString
// (UTF-16) units; native storage commits finish before live ranges are repaired.
var CHARACTER_DATA_BRAND, SYNTHETIC_DATA;
function initializeCharacterData() {
  CHARACTER_DATA_BRAND = new WeakSet();
  SYNTHETIC_DATA = new WeakMap();
  function CharacterData() { throw new TypeError('Illegal constructor'); }
  function Text(data) {
    if (!new.target) throw new TypeError('Text requires new');
    return document.createTextNode(data === undefined ? '' : data);
  }
  function Comment(data) {
    if (!new.target) throw new TypeError('Comment requires new');
    return document.createComment(data === undefined ? '' : data);
  }
  function ProcessingInstruction() { throw new TypeError('Illegal constructor'); }
  function CDATASection() { throw new TypeError('Illegal constructor'); }
  CharacterData.prototype = Object.create(Node.prototype);
  [Text, Comment, ProcessingInstruction].forEach(function(ctor) {
    ctor.prototype = Object.create(CharacterData.prototype);
  });
  CDATASection.prototype = Object.create(Text.prototype);
  [CharacterData, Text, Comment, ProcessingInstruction, CDATASection].forEach(function(ctor) {
    Object.defineProperty(ctor.prototype, 'constructor', {value: ctor, writable: true, configurable: true});
    Object.defineProperty(ctor.prototype, Symbol.toStringTag, {value: ctor.name, configurable: true});
    globalThis[ctor.name] = ctor;
  });
  Object.defineProperty(CharacterData.prototype, 'data', {
    get: function() { return characterDataValue(checkedCharacterData(this)); },
    set: function(value) {
      checkedCharacterData(this);
      var data = domDataString(value === null ? '' : value);
      replaceCharacterData(this, 0, characterDataValue(this).length, data);
    }, enumerable: true, configurable: true
  });
  Object.defineProperty(CharacterData.prototype, 'length', {
    get: function() { return characterDataValue(checkedCharacterData(this)).length; },
    enumerable: true, configurable: true
  });
  CharacterData.prototype.substringData = function(offset, count) {
    checkedCharacterData(this); requireDataArguments(arguments, 2);
    offset = (+offset) >>> 0; count = (+count) >>> 0;
    var data = characterDataValue(this);
    if (offset > data.length) throw domException('IndexSizeError');
    return data.slice(offset, offset + count);
  };
  CharacterData.prototype.appendData = function(data) {
    checkedCharacterData(this); requireDataArguments(arguments, 1);
    data = domDataString(data);
    replaceCharacterData(this, characterDataValue(this).length, 0, data);
  };
  CharacterData.prototype.insertData = function(offset, data) {
    checkedCharacterData(this); requireDataArguments(arguments, 2);
    offset = (+offset) >>> 0; data = domDataString(data);
    replaceCharacterData(this, offset, 0, data);
  };
  CharacterData.prototype.deleteData = function(offset, count) {
    checkedCharacterData(this); requireDataArguments(arguments, 2);
    offset = (+offset) >>> 0; count = (+count) >>> 0;
    replaceCharacterData(this, offset, count, '');
  };
  CharacterData.prototype.replaceData = function(offset, count, data) {
    checkedCharacterData(this); requireDataArguments(arguments, 3);
    offset = (+offset) >>> 0; count = (+count) >>> 0; data = domDataString(data);
    replaceCharacterData(this, offset, count, data);
  };
  Text.prototype.splitText = function(offset) {
    checkedText(this); requireDataArguments(arguments, 1);
    offset = (+offset) >>> 0;
    var data = characterDataValue(this);
    if (offset > data.length) throw domException('IndexSizeError');
    var tail = (this.ownerDocument || document).createTextNode(data.slice(offset));
    var parent = nodeParentForRange(this);
    if (parent) {
      var index = nodeIndexInParent(this);
      parent.insertBefore(tail, this.nextSibling);
      adjustRangesForSplit(this, tail, offset, parent, index);
    }
    replaceCharacterData(this, offset, data.length - offset, '');
    return tail;
  };
  Object.defineProperty(Text.prototype, 'wholeText', {
    get: function() {
      checkedText(this);
      var first = this, result = '';
      while (isTextNode(first.previousSibling)) first = first.previousSibling;
      for (var node = first; isTextNode(node); node = node.nextSibling) result += node.data;
      return result;
    }, enumerable: true, configurable: true
  });
  Node.prototype.normalize = normalizeNode;
}
function domDataString(value) {
  if (typeof value === 'symbol') throw new TypeError('Cannot convert Symbol to DOMString');
  return String(value);
}
function requireDataArguments(args, count) {
  if (args.length < count) throw new TypeError('Missing CharacterData argument');
}
function checkedCharacterData(node) {
  if (!CHARACTER_DATA_BRAND.has(node)) throw new TypeError('Receiver is not CharacterData');
  return node;
}
function isTextNode(node) { return node && (node.nodeType === 3 || node.nodeType === 4); }
function checkedText(node) {
  checkedCharacterData(node);
  if (!isTextNode(node)) throw new TypeError('Receiver is not Text');
  return node;
}
function initializeCharacterDataNode(node, type, value) {
  var ctor = type === 3 ? Text : type === 4 ? CDATASection : type === 7 ? ProcessingInstruction : type === 8 ? Comment : null;
  if (!ctor) return;
  CHARACTER_DATA_BRAND.add(node);
  if (node.__synthetic) {
    delete node.data; delete node.nodeValue; delete node.textContent;
    SYNTHETIC_DATA.set(node, value);
  }
  Object.setPrototypeOf(node, ctor.prototype);
}
function characterDataValue(node) {
  return node.__synthetic ? SYNTHETIC_DATA.get(node) : __native.nodeData(node.handle);
}
function replaceCharacterData(node, offset, count, data) {
  var old = characterDataValue(node);
  if (offset > old.length) throw domException('IndexSizeError');
  count = Math.min(count, old.length - offset);
  var replacement = old.slice(0, offset) + data + old.slice(offset + count);
  if (node.__synthetic) SYNTHETIC_DATA.set(node, replacement);
  else __native.setNodeData(node.handle, replacement);
  adjustRangesForData(node, offset, count, data.length);
}
function normalizeNode() {
  checkedRangeNode(this);
  // Snapshot identities, not native addresses. Removals may relocate siblings.
  var pending = nodeChildrenForRange(this).slice().reverse();
  while (pending.length) {
    var node = pending.pop();
    if (node.nodeType !== 3) {
      var children = nodeChildrenForRange(node);
      for (var i = children.length - 1; i >= 0; i--) pending.push(children[i]);
      continue;
    }
    var parent = nodeParentForRange(node);
    if (!parent) continue;
    if (!node.length) { parent.removeChild(node); continue; }
    var following = [], next = node.nextSibling, addition = '', length = node.length;
    while (next && next.nodeType === 3) {
      following.push(next); addition += next.data; next = next.nextSibling;
    }
    replaceCharacterData(node, length, 0, addition);
    for (var j = 0; j < following.length; j++) {
      var sibling = following[j];
      adjustRangesForMerge(node, sibling, parent, nodeIndexInParent(sibling), length);
      length += sibling.length;
    }
    for (var k = 0; k < following.length; k++) parent.removeChild(following[k]);
  }
}
