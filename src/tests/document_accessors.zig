//! HTML document accessors over live native trees and detached wrapper topology.
const std = @import("std");
const parser = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

fn check(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var html = try parser.HTMLParser.init(allocator, "<!doctype html><html><head><title>  Initial   title  </title></head><body><div id=original>Content</div></body></html>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    parser.fixParentPointers(&root, null);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    const result = try js.evaluate(0, source);
    try std.testing.expect(result.toBoolean());
}

test "document accessors live title is child text with ASCII whitespace normalization" {
    try check(
        \\var title = document.head.firstChild;
        \\if (document.title !== 'Initial title' || title.text !== '  Initial   title  ') throw Error('initial');
        \\if (!(title instanceof HTMLTitleElement) || !(title instanceof HTMLElement)) throw Error('interface');
        \\if ('text' in document.createElement('div')) throw Error('unrelated interface');
        \\title.text = '';
        \\title.appendChild(document.createTextNode(' \tone\n'));
        \\title.appendChild(document.createComment('ignored'));
        \\var child = title.appendChild(document.createElement('span'));
        \\child.textContent = 'ignored descendant';
        \\title.appendChild(document.createTextNode('\rtwo\f\u00a0 '));
        \\if (title.text !== ' \tone\n\rtwo\f\u00a0 ' || document.title !== 'one two \u00a0') throw Error('child text');
        \\document.title = ' Changed\t\t title ';
        \\if (title.childNodes.length !== 1 || title.firstChild.data !== ' Changed\t\t title ') throw Error('replace all');
        \\title.firstChild.data = ' reactive   edit ';
        \\document.title === 'reactive edit' && child.parentNode === null
    );
}

test "document accessors title conversion and creation follow current tree" {
    try check(
        \\var title = document.head.firstChild;
        \\document.title = null;
        \\if (title.text !== 'null') throw Error('DOMString null');
        \\title.text = undefined;
        \\if (document.title !== 'undefined') throw Error('DOMString undefined');
        \\try { title.text = Symbol(); throw Error('symbol accepted'); } catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\title.remove();
        \\document.title = '';
        \\if (!(document.head.lastChild instanceof HTMLTitleElement) || document.head.lastChild.childNodes.length) throw Error('empty creation');
        \\var head = document.head;
        \\document.title = {toString: function() { head.remove(); return 'ignored'; }};
        \\if (document.title !== '' || document.head !== null) throw Error('conversion order');
        \\var late = document.body.appendChild(document.createElement('title'));
        \\late.text = 'body title';
        \\document.title = 'updated body title';
        \\late.text === 'updated body title' && head.lastChild.text === ''
    );
}

test "document accessors empty and replaced detached roots have no stale reads" {
    try check(
        \\var doc = new Document();
        \\var list = doc.childNodes, forms = doc.getElementsByTagName('form');
        \\if (doc.documentElement !== null || list.length !== 0 || doc.head !== null || doc.body !== null) throw Error('empty read mutates');
        \\doc.title = 'ignored';
        \\var html = doc.createElement('html');
        \\doc.insertBefore(html, null);
        \\var head = html.appendChild(doc.createElement('head'));
        \\var body = html.appendChild(doc.createElement('body'));
        \\body.appendChild(doc.createElement('form'));
        \\doc.title = ' First   title ';
        \\if (doc.title !== 'First title' || forms.length !== 1 || list[0] !== html) throw Error('attached read');
        \\doc.removeChild(html);
        \\if (doc.documentElement !== null || doc.title !== '' || forms.length !== 0 || doc.querySelector('form') !== null) throw Error('stale root');
        \\var next = doc.createElement('html');
        \\doc.appendChild(next);
        \\if (doc.head !== null || doc.body !== null) throw Error('stale accessors');
        \\doc.open();
        \\doc.documentElement === null && next.parentNode === null && list.length === 0
    );
}

test "document accessors head and body use namespaces local names and direct child order" {
    try check(
        \\var ns = 'http://www.w3.org/1999/xhtml';
        \\var doc = document.implementation.createDocument(ns, 'h:html', null);
        \\var root = doc.documentElement;
        \\root.appendChild(doc.createElementNS('urn:foreign', 'head'));
        \\root.appendChild(doc.createElementNS(ns, 'HEAD'));
        \\var nested = root.appendChild(doc.createElement('div'));
        \\nested.appendChild(doc.createElement('head'));
        \\nested.appendChild(doc.createElement('body'));
        \\if (doc.head !== null || doc.body !== null) throw Error('nested or foreign');
        \\var head = root.appendChild(doc.createElementNS(ns, 'h:head'));
        \\root.appendChild(doc.createElementNS('urn:foreign', 'frameset'));
        \\var frameset = root.appendChild(doc.createElementNS(ns, 'h:frameset'));
        \\var body = root.appendChild(doc.createElement('body'));
        \\if (doc.head !== head || doc.body !== frameset) throw Error('first namespaced child');
        \\frameset.remove();
        \\doc.body === body && doc.createElementNS('', 'body').namespaceURI === null
    );
}

test "document accessors body setter validates and replaces body or frameset" {
    try check(
        \\var original = document.body;
        \\function rejects(value, name) {
        \\  try { document.body = value; } catch (e) { if (e.name === name) return; throw e; }
        \\  throw Error('accepted invalid body');
        \\}
        \\rejects('text', 'TypeError'); rejects({}, 'TypeError');
        \\rejects(document.createTextNode('body'), 'TypeError');
        \\rejects(document.createElementNS('urn:foreign', 'body'), 'TypeError');
        \\rejects(null, 'HierarchyRequestError'); rejects(document.createElement('div'), 'HierarchyRequestError');
        \\if (document.body !== original) throw Error('failed setter mutated');
        \\var frameset = document.createElement('frameset');
        \\document.body = frameset;
        \\if (document.body !== frameset || original.parentNode !== null) throw Error('replace');
        \\document.body = frameset;
        \\document.body = original;
        \\if (frameset.parentNode !== null || document.getElementById('original').parentNode !== original) throw Error('restore');
        \\var doc = document.implementation.createDocument('urn:foreign', 'root', null);
        \\doc.body = doc.createElement('body');
        \\doc.body === null && doc.documentElement.firstChild.localName === 'body'
    );
}

test "document accessors SVG title uses first direct child and XML setters are inert" {
    try check(
        \\var ns = 'http://www.w3.org/2000/svg', htmlNS = 'http://www.w3.org/1999/xhtml';
        \\var doc = document.implementation.createDocument(ns, 'svg', null);
        \\var group = doc.documentElement.appendChild(doc.createElementNS(ns, 'g'));
        \\var nested = group.appendChild(doc.createElementNS(ns, 'title'));
        \\nested.textContent = 'ignored';
        \\if ('text' in nested || doc.title !== '') throw Error('foreign interface');
        \\doc.title = ' SVG   title ';
        \\var title = doc.documentElement.firstChild;
        \\if (title.namespaceURI !== ns || title.localName !== 'title' || doc.title !== 'SVG title') throw Error('SVG creation');
        \\title.appendChild(doc.createCDATASection(' CDATA'));
        \\if (doc.title !== 'SVG title CDATA') throw Error('CDATA text');
        \\doc.title = '';
        \\if (title.childNodes.length || nested.textContent !== 'ignored') throw Error('SVG replacement');
        \\var xml = document.implementation.createDocument(ns, 'SVG', null);
        \\xml.title = 'ignored';
        \\if (xml.documentElement.childNodes.length) throw Error('case sensitive root');
        \\var htmlTitle = xml.documentElement.appendChild(xml.createElementNS(htmlNS, 'h:title'));
        \\htmlTitle.text = 'readable';
        \\xml.title = 'ignored';
        \\xml.title === 'readable' && htmlTitle.text === 'readable'
    );
}

test "document accessors prototypes reject incompatible receivers" {
    try check(
        \\['documentElement', 'head', 'body', 'title'].forEach(function(name) {
        \\  var getter = Object.getOwnPropertyDescriptor(Document.prototype, name).get;
        \\  try { getter.call(document.body); } catch (e) { if (e instanceof TypeError) return; throw e; }
        \\  throw Error('unbranded document');
        \\});
        \\var text = Object.getOwnPropertyDescriptor(HTMLTitleElement.prototype, 'text');
        \\var rejected = false;
        \\try { text.get.call(document.body); } catch (e) { if (!(e instanceof TypeError)) throw e; rejected = true; }
        \\if (!rejected) throw Error('unbranded title');
        \\text.enumerable && text.configurable && Object.getPrototypeOf(HTMLTitleElement.prototype) === HTMLElement.prototype
    );
}
