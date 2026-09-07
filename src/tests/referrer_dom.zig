//! Live policy-container mutation and JavaScript referrer reflection.
const std = @import("std");
const parser = @import("../document/parser.zig");
const Js = @import("../script/js.zig");
const Policy = @import("../document/referrer.zig").Policy;

test "Referrer metadata observes insertion and attribute changes but not removal or detached parsing" {
    const a = std.testing.allocator;
    var html = try parser.HTMLParser.init(a, "<html><head></head><body></body></html>");
    defer html.deinit(a);
    var root = try html.parse();
    defer root.deinit(a);
    parser.fixParentPointers(&root, null);
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    const js = try Js.init(a, std.testing.io, &environ);
    defer js.deinit(a);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    var policy: Policy = .origin;
    js.setDocumentReferrer(0, "https://source.example/", &policy);
    _ = try js.evaluate(0,
        \\var first = document.createElement('meta');
        \\first.setAttribute('name', 'ReFeRrEr');
        \\first.setAttribute('content', 'no-referrer');
    );
    try std.testing.expectEqual(Policy.origin, policy);
    _ = try js.evaluate(0, "document.head.appendChild(first)");
    try std.testing.expectEqual(Policy.no_referrer, policy);
    _ = try js.evaluate(0,
        \\var second = document.createElement('meta');
        \\second.setAttribute('name', 'referrer');
        \\second.setAttribute('content', 'unsafe-url');
        \\document.head.insertBefore(second, first);
    );
    try std.testing.expectEqual(Policy.unsafe_url, policy);
    _ = try js.evaluate(0, "first.setAttribute('content', 'SAME-ORIGIN')");
    try std.testing.expectEqual(Policy.same_origin, policy);
    _ = try js.evaluate(0,
        \\first.remove(); second.remove();
        \\new DOMParser().parseFromString('<meta name=referrer content=unsafe-url>', 'text/html');
        \\var template = document.createElement('template');
        \\template.innerHTML = '<meta name=referrer content=unsafe-url>';
        \\document.body.appendChild(template);
    );
    try std.testing.expectEqual(Policy.same_origin, policy);
    _ = try js.evaluate(0, "document.body.innerHTML = '<meta name=referrer content=origin>'");
    try std.testing.expectEqual(Policy.origin, policy);
    const result = try js.evaluate(0,
        \\if (document.referrer !== 'https://source.example/') throw Error('incoming referrer changed');
        \\document.referrer = 'forged';
        \\if (document.referrer !== 'https://source.example/') throw Error('writable referrer');
        \\document.implementation.createHTMLDocument('').referrer === ''
    );
    try std.testing.expect(result.toBoolean());
}

test "ReferrerPolicy reflection canonicalizes only recognized HTML tokens" {
    const a = std.testing.allocator;
    var html = try parser.HTMLParser.init(a, "<html><head></head><body><img id=parsed referrerpolicy=ORIGIN></body></html>");
    defer html.deinit(a);
    var root = try html.parse();
    defer root.deinit(a);
    parser.fixParentPointers(&root, null);
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    const js = try Js.init(a, std.testing.io, &environ);
    defer js.deinit(a);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    const result = try js.evaluate(0,
        \\if (document.getElementById('parsed').referrerPolicy !== 'origin') throw Error('parsed');
        \\['a','area','iframe','img','link','script'].forEach(function(tag) {
        \\  var element = document.createElement(tag);
        \\  if (element.referrerPolicy !== '') throw Error('missing');
        \\  element.referrerPolicy = 'STRICT-ORIGIN';
        \\  if (element.referrerPolicy !== 'strict-origin' || element.getAttribute('referrerpolicy') !== 'STRICT-ORIGIN') throw Error('reflection');
        \\  [' origin', 'origin ', 'origin, unsafe-url', 'always', '', null, undefined].forEach(function(value) {
        \\    element.referrerPolicy = value;
        \\    if (element.referrerPolicy !== '') throw Error('invalid: ' + value);
        \\  });
        \\  try { element.referrerPolicy = Symbol(); throw Error('symbol'); } catch(e) { if (!(e instanceof TypeError)) throw e; }
        \\});
        \\!('referrerPolicy' in document.createElement('div'))
    );
    try std.testing.expect(result.toBoolean());

    var nodes = std.ArrayList(*parser.Node).empty;
    defer nodes.deinit(a);
    try parser.treeToList(a, &root, &nodes);
    for (nodes.items) |node| {
        if (node.* != .element or !std.mem.eql(u8, node.element.tag, "img")) continue;
        inline for (.{ "src", "srcset", "sizes", "href", "referrerpolicy" }) |name| {
            node.element.parser_referrer_policy = .unsafe_url;
            _ = try js.evaluate(0, "document.getElementById('parsed').setAttribute('" ++ name ++ "', 'new-value')");
            try std.testing.expect(node.element.parser_referrer_policy == null);
            node.element.parser_referrer_policy = .unsafe_url;
            _ = try js.evaluate(0, "document.getElementById('parsed').removeAttribute('" ++ name ++ "')");
            try std.testing.expect(node.element.parser_referrer_policy == null);
        }
    }
}
