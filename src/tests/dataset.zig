//! Live data-* reflection, property semantics, and retained Element identity.
const std = @import("std");
const parser = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

fn check(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const html = try parser.HTMLParser.init(allocator, "<html><head></head><body><div id=host data-z=first data-a=second data-z=ignored></div></body></html>");
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
        std.debug.print("Dataset regression: {s}\n", .{try Js.formatValue(result, &buffer)});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(result.toBoolean());
}

test "dataset retains one live map with parser and mutation attribute order" {
    try check(
        \\var host=document.getElementById('host'), data=host.dataset;
        \\if (data.z !== 'first' || Object.keys(data).join() !== 'z,a') throw Error('parsed attributes');
        \\host.setAttribute('DATA-Z','changed'); data.b='third'; delete data.a; data.a='last';
        \\if (Object.keys(data).join() !== 'z,b,a' || data.z !== 'changed') throw Error('mutation order');
        \\data['9']='nine'; data['2']='two';
        \\if (Object.keys(data).join() !== 'z,b,a,9,2') throw Error('named numeric order');
        \\host.removeAttribute('DATA-Z');
        \\host.dataset === data && !('z' in data) && data instanceof DOMStringMap && Object.prototype.toString.call(data)==='[object DOMStringMap]'
    );
}

test "dataset performs DOMString conversion before name validation without partial writes" {
    try check(
        \\var element=document.createElement('div'), data=element.dataset, called=0;
        \\data.foo=null; data.bar=undefined; data.answer=42;
        \\if (data.foo!=='null' || data.bar!=='undefined' || data.answer!=='42') throw Error('conversion');
        \\try { data['bad-name']={toString:function(){called++; data.side='effect'; return 'x';}}; throw Error('accepted'); }
        \\catch(e) { if(e.name!=='SyntaxError') throw e; }
        \\if(called!==1 || data.side!=='effect' || element.hasAttribute('data-bad-name')) throw Error('conversion order');
        \\for (var name of ['bad name','bad/name','bad=name','bad>name','bad\0name']) {
        \\  try { data[name]='x'; throw Error('invalid name'); } catch(e) { if(e.name!=='InvalidCharacterError') throw e; }
        \\}
        \\try { data.foo=Symbol(); throw Error('symbol'); } catch(e) { if(!(e instanceof TypeError)) throw e; }
        \\data.foo==='null' && data['bad-name']===undefined
    );
}

test "dataset overrides inherited names without prototype pollution and exposes descriptors" {
    try check(
        \\var element=document.createElement('div'), data=element.dataset;
        \\Object.defineProperty(DOMStringMap.prototype,'x',{get:function(){return 'inherited';},set:function(){throw Error('prototype setter');},configurable:true});
        \\if(data.x!=='inherited') throw Error('inheritance');
        \\data.x='own'; data.toString='text'; data.__proto__='safe'; data.constructor='ctor';
        \\if(data.x!=='own' || data.toString!=='text' || data.__proto__!=='safe' || data.constructor!=='ctor') throw Error('override');
        \\if(Object.getPrototypeOf(data)!==DOMStringMap.prototype) throw Error('pollution');
        \\var desc=Object.getOwnPropertyDescriptor(data,'x');
        \\if(!desc.writable || !desc.enumerable || !desc.configurable || desc.value!=='own') throw Error('descriptor');
        \\delete data.x; delete data.toString; delete data.__proto__; delete data.constructor;
        \\data.x==='inherited' && data.toString===Object.prototype.toString && Object.keys(data).length===0
    );
}

test "dataset handles symbols definitions alternate receivers and nonextensibility" {
    try check(
        \\var data=document.createElement('div').dataset, symbol=Symbol('metadata');
        \\data[symbol]=23; Object.defineProperty(data,'x',{value:7});
        \\if(data.x!=='7' || data[symbol]!==23) throw Error('define');
        \\if(Reflect.defineProperty(data,'accessor',{get:function(){return 1;}})) throw Error('accessor');
        \\var receiver={}; Reflect.set(data,'x',8,receiver);
        \\if(data.x!=='7' || receiver.x!==8) throw Error('receiver');
        \\if(Reflect.preventExtensions(data) || !Object.isExtensible(data)) throw Error('extensibility');
        \\delete data[symbol];
        \\Reflect.ownKeys(data).join()==='x'
    );
}

test "dataset survives detach sibling relocation cloning and fragment replacement" {
    try check(
        \\var retained=document.getElementById('host'), data=retained.dataset;
        \\for(var i=0;i<100;i++) document.body.appendChild(document.createElement('p'));
        \\data.relocated='yes';
        \\var clone=retained.cloneNode(true); clone.dataset.relocated='clone';
        \\document.body.innerHTML='<div>replacement</div>'; data.retained='yes';
        \\document.body.appendChild(retained);
        \\retained.dataset===data && data.relocated==='yes' && data.retained==='yes' && clone.dataset.relocated==='clone' && clone.dataset!==data
    );
}

test "dataset is namespace scoped and respects XML case and ASCII-only mapping" {
    try check(
        \\var svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
        \\svg.setAttribute('data-Foo','ignored'); svg.setAttribute('data-foo','value'); svg.setAttribute('data-\u00c4','upper unicode');
        \\if(svg.dataset.foo!=='value' || 'Foo' in svg.dataset || svg.dataset['\u00c4']!=='upper unicode') throw Error('SVG mapping');
        \\var xml=document.implementation.createDocument(null,'root',null);
        \\var xmlElement=xml.createElementNS('http://www.w3.org/1999/xhtml','html');
        \\xmlElement.setAttribute('data-Foo','ignored'); xmlElement.setAttribute('data-foo','value');
        \\if(Object.keys(xmlElement.dataset).join()!=='foo') throw Error('XML case');
        \\var arbitrary=document.createElementNS('urn:example','item'), math=document.createElementNS('http://www.w3.org/1998/Math/MathML','math');
        \\!('dataset' in arbitrary) && !('dataset' in new Text()) && math.dataset instanceof DOMStringMap
    );
}

test "dataset attribute methods normalize HTML case and retain DOMString null values" {
    try check(
        \\var element=document.createElement('div'); element.setAttribute('DATA-STATE',null);
        \\if(element.dataset.state!=='null' || element.getAttribute('DATA-State')!=='null') throw Error('HTML case/null');
        \\element.setAttribute('data-state',undefined); if(element.dataset.state!=='undefined') throw Error('undefined');
        \\element.removeAttribute('DATA-STATE');
        \\try { element.setAttribute('x'); throw Error('arity'); } catch(e) { if(!(e instanceof TypeError)) throw e; }
        \\try { element.setAttribute('bad name','x'); throw Error('name'); } catch(e) { if(e.name!=='InvalidCharacterError') throw e; }
        \\!('state' in element.dataset)
    );
}
