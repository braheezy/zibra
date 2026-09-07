//! Dynamic markup parsing, detached-source lifetime, and wrapper identity.
const std = @import("std");
const parser = @import("../document/parser.zig");
const fragments = @import("../document/html_fragment.zig");
const Js = @import("../script/js.zig");

fn check(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const html = try parser.HTMLParser.init(allocator, "<html><head></head><body><div id=host></div></body></html>");
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
    const diagnostic = try std.fmt.allocPrint(allocator, "try {{ {s}\n }} catch (e) {{ String(e.stack || e); }}", .{source});
    defer allocator.free(diagnostic);
    const result = try js.evaluate(0, diagnostic);
    if (!result.isBoolean()) {
        var buffer: [4096]u8 = undefined;
        std.debug.print("Fragment regression: {s}\n", .{try Js.formatValue(result, &buffer)});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(result.toBoolean());
}

test "HTML fragments preserve removed identities and live views across innerHTML" {
    try check(
        \\var host = document.getElementById('host');
        \\host.innerHTML = '<b id=old>retained &amp; alive</b>';
        \\var old = host.firstChild, text = old.firstChild, list = host.childNodes;
        \\var range = document.createRange(); range.selectNodeContents(old);
        \\host.innerHTML = '<i>new</i><em>tail</em>';
        \\if (old.parentNode !== null || old.firstChild !== text || text.parentNode !== old) throw Error('old topology');
        \\if (text.data !== 'retained & alive' || list.length !== 2 || list[0] !== host.firstChild) throw Error('views');
        \\if (range.startContainer !== host || range.startOffset !== 0) throw Error('range');
        \\host.innerHTML = ''; host.appendChild(old);
        \\host.firstChild === old && old.firstChild === text && text.data === 'retained & alive'
    );
}

test "HTML fragments insert around stable listeners without merging text" {
    try check(
        \\var host = document.getElementById('host');
        \\host.innerHTML = '<button>keep</button>';
        \\var button = host.firstChild, hits = 0;
        \\button.addEventListener('click', function() { hits++; });
        \\button.insertAdjacentHTML('beforeBegin', '<i>before</i>');
        \\button.insertAdjacentHTML('afterEND', '<b>after</b>tail');
        \\button.insertAdjacentHTML('afterbegin', 'first');
        \\button.insertAdjacentHTML('beforeend', 'last');
        \\button.dispatchEvent(new Event('click'));
        \\if (button.childNodes.length !== 3 || button.textContent !== 'firstkeeplast' || hits !== 1) throw Error('identity');
        \\button.previousSibling.localName === 'i' && button.nextSibling.localName === 'b' && host.lastChild.data === 'tail'
    );
}

test "HTML fragments outerHTML replacement preserves detached target and context" {
    try check(
        \\var table = document.getElementById('host');
        \\table.innerHTML = '<i>old</i>';
        \\var old = table.firstChild;
        \\old.outerHTML = '<p>one<p>two';
        \\if (old.parentNode !== null || old.textContent !== 'old' || table.children.length !== 2) throw Error('replace');
        \\old.outerHTML = '<b>ignored</b>';
        \\if (old.localName !== 'i') throw Error('detached');
        \\try { document.documentElement.outerHTML = ''; throw Error('allowed document'); } catch (e) { if (e.name !== 'NoModificationAllowedError' || e.code !== 7) throw e; }
        \\var fragment = document.createDocumentFragment(); fragment.appendChild(old);
        \\old.outerHTML = '<span>new</span>';
        \\fragment.firstChild.localName === 'span' && old.parentNode === null
    );
}

test "HTML fragments table cells and RCDATA use context with no wrapper escape" {
    try check(
        \\var table = document.createElement('table');
        \\table.innerHTML = '<tr><td>one<td>two<tr><th>three';
        \\if (table.innerHTML !== '<tbody><tr><td>one</td><td>two</td></tr><tr><th>three</th></tr></tbody>') throw Error(table.innerHTML);
        \\table.firstChild.insertAdjacentHTML('beforeend', '<tr><td>four');
        \\if (table.firstChild.children.length !== 3) throw Error('row insertion');
        \\var area = document.createElement('textarea');
        \\area.innerHTML = '<b>&amp;</b></textarea><i>literal';
        \\if (area.children.length || area.textContent !== '<b>&</b></textarea><i>literal') throw Error('RCDATA');
        \\var div = document.createElement('div');
        \\div.innerHTML = '</html></body><p>first<p>second';
        \\div.children.length === 2 && div.textContent === 'firstsecond'
    );
}

test "HTML fragments string conversions happen before context lookup" {
    try check(
        \\var host = document.getElementById('host');
        \\host.innerHTML = undefined;
        \\if (host.textContent !== 'undefined') throw Error('undefined');
        \\host.innerHTML = null;
        \\if (host.childNodes.length) throw Error('null');
        \\host.insertAdjacentHTML('beforeend', null);
        \\if (host.textContent !== 'null') throw Error('method null');
        \\try { host.innerHTML = Symbol(); throw Error('allowed Symbol'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\try { host.insertAdjacentHTML('beforebeg\u0131n', ''); throw Error('allowed position'); } catch(e) { if (e.name !== 'SyntaxError') throw e; }
        \\var old = host.appendChild(document.createElement('b'));
        \\old.outerHTML = {toString: function() { old.remove(); return '<i>ignored</i>'; }};
        \\host.textContent === 'null' && old.parentNode === null
    );
}

test "HTML fragments text readback decodes references once but not literal script or XML text" {
    try check(
        \\var div = document.createElement('div');
        \\div.innerHTML = '&amp;amp;&#169;';
        \\if (div.firstChild.data !== '&amp;\u00a9' || div.textContent !== '&amp;\u00a9') throw Error('HTML decode');
        \\div.firstChild.data = '&amp;';
        \\if (div.textContent !== '&amp;') throw Error('setter literal');
        \\div.innerHTML = '<script>&amp;<' + '/script>';
        \\if (div.firstChild.textContent !== '&amp;') throw Error('script data');
        \\var xml = new DOMParser().parseFromString('<root>&amp;amp;</root>', 'application/xml');
        \\if (xml.documentElement.textContent !== '&amp;') throw Error('XML double decode');
        \\var html = new DOMParser().parseFromString('<noembed>&lt;a&gt;</noembed>', 'text/html');
        \\html.querySelector('noembed').textContent === '&lt;a&gt;'
    );
}

test "HTML fragments in detached HTML documents inherit the correct owner" {
    try check(
        \\var doc = document.implementation.createHTMLDocument('Other');
        \\doc.body.innerHTML = '<div><b>one</b></div>';
        \\var div = doc.body.firstChild;
        \\div.insertAdjacentHTML('beforeend', '<i><em>two</em></i>');
        \\div.firstChild.outerHTML = '<strong>three</strong>';
        \\div.ownerDocument === doc && div.firstChild.ownerDocument === doc && div.lastChild.firstChild.ownerDocument === doc
    );
}

test "HTML fragments nested list queries exclude the receiver" {
    try check(
        \\var div = document.createElement('div');
        \\div.innerHTML = '<ul><li><ul><li>nested</li></ul></li></ul>';
        \\var outer = div.querySelector('ul'), inner = outer.querySelector('ul');
        \\outer !== inner && outer.querySelectorAll('ul').length === 1 && inner.querySelector('ul') === null && inner.innerHTML === '<li>nested</li>'
    );
}

fn allocatedFragment(allocator: std.mem.Allocator) !void {
    var result = try fragments.parse(allocator, "<tr><td>one<td><script>inert()</script><tr><td>two", "table");
    defer allocator.free(result.source);
    defer result.root.deinit(allocator);
    const script = &result.root.element.children.items[0].element.children.items[0].element.children.items[1].element.children.items[0];
    try std.testing.expect(script.element.script_started);
}

test "HTML fragments own parser allocations on every failure and keep scripts inert" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocatedFragment, .{});
}
