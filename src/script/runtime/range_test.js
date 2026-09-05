// Shared by the native host regression and the visible manual fixture.
function checkRangeBoundaries() {
  function check(condition, label) { if (!condition) throw new Error(label); }
  function throws(name, code, callback) {
    try { callback(); } catch (error) {
      check(error.name === name, 'exception name: ' + name + ', got ' + error.name);
      if (code !== null) check(error instanceof DOMException && error.code === code, 'DOMException identity/code: ' + name);
      else check(error instanceof TypeError, 'TypeError identity');
      return;
    }
    throw new Error('missing exception: ' + name);
  }
  function point(node, offset) { var r = new Range(); r.setStart(node, offset); r.collapse(true); return r; }
  function same(r, node, start, end) {
    check(r.startContainer === node && r.endContainer === node && r.startOffset === start && r.endOffset === end,
      'boundary state');
  }
  var host = document.createElement('div');
  var p = document.createElement('p'), text = document.createTextNode('A\uD83D\uDE00B');
  var tail = document.createElement('p');
  p.appendChild(text); host.appendChild(p); host.appendChild(tail);
  document.body.appendChild(host);
  try {
    check(document.nodeName === '#document' && document instanceof Document && String(document).length > 0, 'document identity');
    var rootIndex = Array.prototype.indexOf.call(document.childNodes, document.documentElement);
    check(rootIndex >= 0 && document.documentElement.parentNode === document &&
      document.documentElement.previousSibling === (rootIndex ? document.childNodes[rootIndex - 1] : null), 'document root topology');
    check(text.length === 4, 'UTF-16 CharacterData length');
    var comment = document.createComment('note');
    tail.appendChild(comment);
    check(tail.firstChild === comment && tail.lastChild === comment && comment.length === 4, 'synthetic child topology');
    // Every distinct DOM position remains ordered, including nested zero and
    // end offsets that can paint at the same caret location.
    var points = [[host, 0], [p, 0], [text, 0], [text, 1], [text, 2], [text, 4], [p, 1], [host, 1], [tail, 0], [host, 2]];
    for (var i = 0; i < points.length; i++) {
      var left = point(points[i][0], points[i][1]);
      for (var j = 0; j < points.length; j++) {
        var right = point(points[j][0], points[j][1]);
        var order = i < j ? -1 : i > j ? 1 : 0;
        check(left.compareBoundaryPoints(0, right) === order, 'point ordering ' + i + '/' + j);
        check(left.comparePoint(points[j][0], points[j][1]) === -order, 'comparePoint ' + i + '/' + j);
        check(left.isPointInRange(points[j][0], points[j][1]) === (i === j), 'point containment');
      }
    }
    var r = point(text, 1); r.setEnd(text, 3);
    var other = point(text, 2); other.setEnd(text, 4);
    [-1, 1, -1, -1].forEach(function(expected, mode) {
      check(r.compareBoundaryPoints(mode, other) === expected, 'comparison mode ' + mode);
      check(r.compareBoundaryPoints(String(65536 + mode), other) === expected, 'unsigned short conversion');
    });
    check(r.isPointInRange(text, 1) && r.isPointInRange(text, 3), 'inclusive endpoints');
    check(r.intersectsNode(p) && r.intersectsNode(document) && !r.intersectsNode(tail), 'node overlap');
    check(!point(host, 0).intersectsNode(p) && !point(host, 1).intersectsNode(p), 'strict intersection edges');
    check(point(p, 0).intersectsNode(p), 'collapsed interior intersection');

    // Conversion precedes DOM validation; failing setters cannot publish a
    // new container while retaining an old offset.
    ['setStart', 'setEnd'].forEach(function(method) {
      throws('IndexSizeError', 1, function() { r[method](p, 99); }); same(r, text, 1, 3);
      throws('IndexSizeError', 1, function() { r[method](text, -1); }); same(r, text, 1, 3);
      throws('TypeError', null, function() { r[method](null, 0); });
      throws('TypeError', null, function() { r[method](text); });
      throws('TypeError', null, function() { r[method](text, 0n); });
      throws('TypeError', null, function() { r[method](text, Symbol()); });
    });
    [NaN, Infinity, -Infinity, -0.5, undefined, null, 4294967296].forEach(function(offset) {
      var converted = new Range(); converted.setStart(text, offset);
      check(converted.startOffset === 0, 'unsigned long zero conversion');
    });
    check(point(text, 4294967297.8).startOffset === 1, 'unsigned long wrap and truncation');
    var dt = document.implementation.createDocumentType('html', '', '');
    throws('InvalidNodeTypeError', 24, function() { r.setStart(dt, 99); }); same(r, text, 1, 3);
    throws('InvalidNodeTypeError', 24, function() { r.selectNodeContents(dt); }); same(r, text, 1, 3);
    ['setStartBefore', 'setStartAfter', 'setEndBefore', 'setEndAfter', 'selectNode'].forEach(function(method) {
      throws('InvalidNodeTypeError', 24, function() { r[method](document); });
      throws('TypeError', null, function() { r[method](null); });
      same(r, text, 1, 3);
    });
    throws('TypeError', null, function() { Range.prototype.setStart.call({}, text, 0); });
    throws('TypeError', null, function() { r.compareBoundaryPoints(0, {}); });
    throws('TypeError', null, function() { r.intersectsNode({}); });
    throws('TypeError', null, function() { r.intersectsNode({ nodeType: 1 }); });

    // Different trees in the same document are different roots, too.
    var detached = document.createTextNode('away');
    check(!r.isPointInRange(detached, 999) && !r.isPointInRange(dt, 999), 'different root wins over validation');
    throws('WrongDocumentError', 4, function() { r.comparePoint(dt, 999); });
    throws('WrongDocumentError', 4, function() { r.compareBoundaryPoints(0, point(detached, 0)); });
    throws('NotSupportedError', 9, function() { r.compareBoundaryPoints(4, point(detached, 0)); });
    r.setStart(detached, 2); same(r, detached, 2, 2);
    r.setEnd(text, 3); same(r, text, 3, 3);
    r.setEnd(text, 1); same(r, text, 1, 1);
    r.setStart(text, 2); same(r, text, 2, 2);
    var doc = document.implementation.createHTMLDocument('range');
    same(doc.createRange(), doc, 0, 0);
    var xml = document.implementation.createDocument(null, 'root', null);
    var pi = xml.createProcessingInstruction('target', 'data');
    check(pi.target === 'target' && pi.length === 4, 'ProcessingInstruction properties');
    var fragment = document.createDocumentFragment();
    r.selectNodeContents(fragment);
    check(r.intersectsNode(fragment) && r.isPointInRange(fragment, 0), 'empty root intersects itself');
    var a = fragment.appendChild(document.createElement('a'));
    var b = fragment.appendChild(document.createElement('b'));
    r.setStart(a, 0); r.setEnd(b, 0);
    check(r.commonAncestorContainer === fragment && r.intersectsNode(fragment), 'fragment common root');
    check(a.parentNode === fragment && a.nextSibling === b && b.previousSibling === a, 'fragment topology');
    fragment.removeChild(b);
    check(b.parentNode === null && a.nextSibling === null && r.endContainer === fragment && r.endOffset === 1, 'fragment removal repair');

    // detach() is a compatibility no-op, including for live mutation repair.
    r.selectNodeContents(text); r.detach();
    p.removeChild(text); same(r, p, 0, 0);
    check(r.isPointInRange(p, 0), 'query after detach and mutation');
    p.appendChild(text);
    var selection = getSelection(); selection.removeAllRanges();
    selection.addRange(point(detached, 0)); check(selection.rangeCount === 0, 'selection rejects detached root');
    selection.addRange(doc.createRange()); check(selection.rangeCount === 0, 'selection rejects foreign document');
    selection.addRange(r); check(selection.rangeCount === 1 && selection.getRangeAt(0) === r, 'selection keeps identity');
    selection.collapse(detached, 0); check(selection.getRangeAt(0) === r, 'foreign collapse is inert');
    throws('IndexSizeError', 1, function() { selection.collapse(detached, 99); });
    check(selection.getRangeAt(0) === r, 'failed collapse preserves selection');
    selection.collapse(null); check(selection.rangeCount === 0, 'null collapse clears selection');
    check(selection.type === 'None', 'empty selection type');
    selection.collapse(text, 1); check(selection.type === 'Caret', 'collapsed selection type');
    return 'PASS';
  } catch (error) {
    return 'FAIL: ' + error.name + ': ' + error.message;
  } finally {
    getSelection().removeAllRanges();
    host.parentNode.removeChild(host);
  }
}
