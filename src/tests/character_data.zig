//! CharacterData DOMString, Range repair, and native data-retirement regressions.
const std = @import("std");
const parser = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

fn check(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const html = try parser.HTMLParser.init(allocator, "<html><head></head><body><div id=host>old &amp; text</div></body></html>");
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
        std.debug.print("CharacterData regression: {s}\n", .{try Js.formatValue(result, &buffer)});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(result.toBoolean());
}

test "CharacterData invalidation precedes data retirement and completion observes new text" {
    const allocator = std.testing.allocator;
    const html = try parser.HTMLParser.init(allocator, "<html><body><p>old</p></body></html>");
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
    const Observer = struct {
        prepared: bool = false,
        completed: bool = false,
        renders: usize = 0,
        fn prepare(context: ?*anyopaque, node: *parser.Node, kind: Js.DomMutationKind) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.prepared = kind == .structural and std.mem.eql(u8, node.element.children.items[0].text.text, "old");
        }
        fn complete(context: ?*anyopaque, node: *parser.Node) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.completed = self.prepared and std.mem.eql(u8, node.element.children.items[0].text.text, "new");
        }
        fn render(context: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.renders += 1;
        }
    };
    var observer = Observer{};
    js.setDomMutationCallback(0, Observer.prepare, &observer);
    js.setDomMutationCompleteCallback(0, Observer.complete, &observer);
    js.setRenderCallback(0, Observer.render, &observer);
    try std.testing.expect((try js.evaluate(0,
        \\var text=document.querySelector('p').firstChild, sibling=text.nextSibling;
        \\text.data='new';
        \\var detached=new Text('old'); detached.data='new';
        \\text === document.querySelector('p').firstChild && text.nextSibling === sibling
    )).toBoolean());
    try std.testing.expect(observer.prepared and observer.completed);
    try std.testing.expectEqual(@as(usize, 1), observer.renders);
}

test "CharacterData methods share literal UTF16 storage through moves and clones" {
    try check(
        \\var host = document.getElementById('host'), text = host.firstChild;
        \\if (text.data !== 'old & text') throw Error('readback');
        \\text.replaceData(4, 1, '&amp;');
        \\if (text.data !== 'old &amp; text') throw Error('literal');
        \\if (host.innerHTML !== 'old &amp;amp; text') throw Error('serialization');
        \\text.data = 'A\ud83c\udf20B';
        \\var tail = text.splitText(2);
        \\if (text.data !== 'A\ud83c' || tail.data !== '\udf20B') throw Error('surrogate split');
        \\if (host.textContent !== 'A\ud83c\udf20B') throw Error('UTF16 aggregation');
        \\var clone = tail.cloneNode(); host.removeChild(tail); host.appendChild(tail);
        \\if (clone.data !== '\udf20B') throw Error('clone');
        \\host.normalize();
        \\host.firstChild === text && text.data === 'A\ud83c\udf20B' && tail.data === '\udf20B' && tail.parentNode === null
    );
}

test "CharacterData conversion order brands and unsigned offsets" {
    try check(
        \\var text = new Text('abcd'), order = [];
        \\text.replaceData({valueOf:function(){order.push('offset'); text.data='12345'; return 1;}},
        \\  {valueOf:function(){order.push('count'); return 2;}},
        \\  {toString:function(){order.push('data'); return 'X';}});
        \\if (text.data !== '1X45' || order.join() !== 'offset,count,data') throw Error('conversion');
        \\text.insertData(4294967296, null);
        \\if (text.data !== 'null1X45') throw Error('modulo/null');
        \\text.data = undefined; if (text.data !== 'undefined') throw Error('undefined');
        \\text.nodeValue = null; if (text.length !== 0) throw Error('null');
        \\text.data='data'; text.nodeValue=undefined; if (text.length !== 0) throw Error('nullable nodeValue');
        \\text.data='data'; text.textContent=undefined; if (text.length !== 0) throw Error('nullable textContent');
        \\try { text.appendData(); throw Error('missing'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\try { text.insertData(-1, 'x'); throw Error('offset'); } catch(e) { if (e.name !== 'IndexSizeError') throw e; }
        \\try { text.deleteData(0n, 0); throw Error('bigint'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\try { text.data = Symbol(); throw Error('symbol'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\try { CharacterData.prototype.appendData.call(document.body, 'x'); throw Error('brand'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\text instanceof Text && text instanceof CharacterData && text instanceof Node
    );
}

test "CharacterData replacement repairs all range offsets including full setters" {
    try check(
        \\var text = new Text('abcdef'), ranges = [];
        \\for (var i=0;i<=6;i++) {var r=document.createRange(); r.setStart(text,i); r.collapse(true); ranges.push(r);}
        \\text.replaceData(2,2,'XYZ');
        \\if (ranges.map(function(r){return r.startOffset;}).join() !== '0,1,2,2,2,6,7') throw Error('replace repair');
        \\text.insertData(2,'Q');
        \\if (ranges[2].startOffset !== 2 || ranges[5].endOffset !== 7) throw Error('insertion equality');
        \\text.textContent = text.data;
        \\ranges.every(function(r){return r.collapsed && r.startContainer === text && r.startOffset === 0;})
    );
}

test "CharacterData split repairs text and parent ranges but detached ranges clamp" {
    try check(
        \\var container = document.createElement('div'), text = container.appendChild(new Text('abcd'));
        \\container.appendChild(new Text('end'));
        \\var inText = document.createRange(); inText.setStart(text,2); inText.setEnd(text,4);
        \\var after = document.createRange(); after.setStart(container,1); after.setEnd(container,2);
        \\var tail = text.splitText(2);
        \\if (inText.startContainer !== text || inText.startOffset !== 2 || inText.endContainer !== tail || inText.endOffset !== 2) throw Error('text points');
        \\if (after.startOffset !== 2 || after.endOffset !== 3) throw Error('parent points');
        \\var detached = new Text('abcd'), r = document.createRange(); r.setStart(detached,3); r.setEnd(detached,4);
        \\detached.splitText(1);
        \\r.startContainer === detached && r.endContainer === detached && r.startOffset === 1 && r.endOffset === 1
    );
}

test "CharacterData normalize respects barriers owners and retained identities" {
    try check(
        \\var doc = document.implementation.createHTMLDocument(''), f = doc.createDocumentFragment();
        \\var a=f.appendChild(doc.createTextNode('a')), empty=f.appendChild(doc.createTextNode('')), b=f.appendChild(doc.createTextNode('bc'));
        \\var marker=f.appendChild(doc.createComment('barrier')), c=f.appendChild(doc.createTextNode('d'));
        \\var r=doc.createRange(); r.setStart(f,2); r.setEnd(b,1);
        \\f.normalize();
        \\if(f.childNodes.length !== 3 || a.data !== 'abc' || marker.textContent !== 'barrier') throw Error('normalization');
        \\if(r.startContainer !== a || r.startOffset !== 1 || r.endContainer !== a || r.endOffset !== 2) throw Error('merge points');
        \\if(f.textContent !== 'abcd' || b.data !== 'bc' || empty.parentNode !== null) throw Error('retention');
        \\var tail=a.splitText(1);
        \\tail.ownerDocument === doc && tail.nextSibling === marker && tail.data === 'bc'
    );
}

test "CharacterData synthetic kinds share data and ranges without merging CDATA" {
    try check(
        \\var doc = document.implementation.createDocument(null,'root',null), root=doc.documentElement;
        \\var comment=doc.createComment('abc'), pi=doc.createProcessingInstruction('target','abc'), cdata=doc.createCDATASection('abc');
        \\[comment,pi,cdata].forEach(function(n){ var r=doc.createRange(); r.setStart(n,2); r.setEnd(n,3); n.deleteData(1,100); if(n.data !== 'a' || n.nodeValue !== 'a' || n.textContent !== 'a' || r.endOffset !== 1) throw Error('synthetic'); });
        \\root.appendChild(doc.createTextNode('left')); root.appendChild(cdata); root.appendChild(doc.createTextNode('right'));
        \\root.normalize();
        \\cdata.wholeText === 'leftaright' && root.childNodes.length === 3 && pi.target === 'target'
    );
}

test "CharacterData Range insertion and extraction also repair other live ranges" {
    try check(
        \\var container=document.createElement('p'), t=container.appendChild(new Text('abcdef'));
        \\var selection=document.createRange(); selection.setStart(t,2); selection.setEnd(t,4);
        \\var observer=document.createRange(); observer.setStart(t,4); observer.setEnd(t,6);
        \\var result=selection.extractContents();
        \\if(result.textContent !== 'cd' || t.data !== 'abef' || observer.startOffset !== 2 || observer.endOffset !== 4) throw Error('extract');
        \\selection.insertNode(document.createElement('b'));
        \\observer.startContainer === t && observer.startOffset === 2 && observer.endContainer === container.lastChild && observer.endOffset === 2 && selection.endContainer === container && selection.endOffset === 2
    );
}
