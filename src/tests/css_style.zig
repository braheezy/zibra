//! Live CSS declaration and synchronous computed-style readback regressions.
const std = @import("std");
const document = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

test "CSS supports namespace overload conversion and queries leave live declarations untouched" {
    try checkInlineStyle(
        \\equal(typeof CSS, 'object'); equal(CSS, window.CSS);
        \\equal(Object.prototype.toString.call(CSS), '[object CSS]');
        \\equal(CSS.supports.length, 1); equal(CSS.supports.name, 'supports');
        \\equal(Object.getOwnPropertyDescriptor(globalThis, 'CSS').enumerable, false);
        \\equal(Object.getOwnPropertyDescriptor(CSS, 'supports').enumerable, true);
        \\function throwsType(label, fn) { var threw=false; try { fn(); } catch(e) { threw=e instanceof TypeError; } if (!threw) throw Error('Expected TypeError: ' + label); }
        \\throwsType('arity', function(){ CSS.supports(); });
        \\throwsType('condition symbol', function(){ CSS.supports(Symbol()); });
        \\throwsType('value symbol', function(){ CSS.supports('color', Symbol()); });
        \\throwsType('construct', function(){ new CSS.supports('color:red'); });
        \\var order = '';
        \\equal(CSS.supports({toString:function(){order+='p';return 'color';}}, {toString:function(){order+='v';return 'red';}}, {toString:function(){throw Error('extra converted');}}),true);
        \\equal(order,'pv');
        \\equal(CSS.supports(undefined), false); equal(CSS.supports(null), false);
        \\equal(CSS.supports('color:red', undefined), false);
        \\equal(CSS.supports.call(null,'color','red'), true);
        \\var saved = style.cssText, attribute = target.getAttribute('style');
        \\equal(CSS.supports('WIDTH','1px'), true); equal(CSS.supports(' width','1px'), false);
        \\equal(CSS.supports('display','nonsense'), false); equal(CSS.supports('position','sticky'), true);
        \\equal(CSS.supports('animation','pulse 1s both'), true);
        \\equal(CSS.supports('w\\69 dth','1px'), false); equal(CSS.supports('w\\69 dth:1px'), true);
        \\equal(CSS.supports('color','red!important'), false); equal(CSS.supports('color:red!important'), true);
        \\equal(CSS.supports('--empty',''), true); equal(CSS.supports('--empty',';'), false);
        \\equal(CSS.supports('color','var(--not-defined)'), true);
        \\equal(CSS.supports('width','nonsense'), false); equal(CSS.supports('unicode-range','inherit'), false);
        \\equal(CSS.supports('selector(:is(main > .card, #target))'), true);
        \\equal(CSS.supports('selector(:is(.card, :unknown))'), false);
        \\equal(CSS.supports('not selector(:is(.card, :unknown))'), true);
        \\equal(CSS.supports('(color:red) or garbage'), false);
        \\equal(style.cssText, saved); equal(target.getAttribute('style'), attribute);
        \\style.display = 'block'; style.display = 'nonsense'; equal(style.display, 'block');
    );
}

test "responsive CSSOM updates custom properties without losing declarations or case" {
    const allocator = std.testing.allocator;
    var html = try document.HTMLParser.init(allocator, "<html style='font-size:10px;--Tone:red'><body><div id=target style='font-size:var(--size, 1.6rem);color:var(--Tone);width:20px'></div></body></html>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    try document.style(allocator, &root, &.{});
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    const Flush = struct {
        root: *document.Node,
        fn run(raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try document.style(std.testing.allocator, self.root, &.{});
        }
    };
    var flush = Flush{ .root = &root };
    js.setStyleFlushCallback(0, Flush.run, &flush);
    const result = try js.evaluate(0,
        \\var root = document.documentElement;
        \\var target = document.getElementById('target');
        \\var style = root.style;
        \\if (style !== root.style) throw new Error('style must be live and cached');
        \\style.setProperty('--Tone', 'blue');
        \\style.setProperty('--tone', 'green');
        \\style.setProperty('--size', '2rem', 'important');
        \\if (style.getPropertyPriority('--size') !== 'important') throw new Error('priority');
        \\if (parseFloat(getComputedStyle(target).fontSize) !== 20) throw new Error('new inherited name');
        \\if (getComputedStyle(target).getPropertyValue('--Tone') !== 'blue') throw new Error('case');
        \\style.fontSize = '20px';
        \\if (parseFloat(getComputedStyle(target).fontSize) !== 40) throw new Error('dirty root dependency');
        \\if (style.removeProperty('--size') !== '2rem') throw new Error('remove');
        \\if (parseFloat(getComputedStyle(target).fontSize) !== 32) throw new Error('fallback');
        \\target.style.setProperty('--text', '"a;b:c"');
        \\target.style.cssFloat = 'left';
        \\target.style.getPropertyValue('--text') === '"a;b:c"' &&
        \\target.style.width === '20px' && style.getPropertyValue('--tone') === 'green'
    );
    try std.testing.expect(result.toBoolean());
}

test "CSSOM value normalization reaches native computed values and preserves token boundaries" {
    try checkInlineStyle(
        \\style.cssText = 'width: +001.50P\\58; color: #FC0; --\\54 one: .50EM; --n: 12; --space\\ name: 22PX';
        \\equal(style.width, '1.5px'); equal(style.color, 'rgb(255, 204, 0)');
        \\equal(style.getPropertyValue('--Tone'), '.50EM');
        \\equal(style.getPropertyValue('--space name'), '22PX');
        \\style.width = 'var(--space\\ name)';
        \\equal(getComputedStyle(target).width, '22px');
        \\style.width = 'var(--n)px';
        \\equal(getComputedStyle(target).width, 'auto');
        \\style.width = '20px'; style.width = '1/**/px'; equal(style.width, '20px');
        \\style.width = 'var(not-a-custom-name)'; equal(style.width, '20px');
        \\style.setProperty('--text', 'A/**/  +01PX');
        \\equal(style.getPropertyValue('--text'), 'A/**/  +01PX');
        \\style.setProperty('--text', 'url(a b)'); equal(style.getPropertyValue('--text'), 'A/**/  +01PX');
        \\style.backgroundImage = 'url(A\\20 B.png'; equal(style.backgroundImage, 'url("A B.png")');
        \\style.backgroundImage = 'url("bad" extra)'; equal(style.backgroundImage, 'url("A B.png")');
        \\style.content = "'EOF\\"; equal(style.content, '"EOF"');
        \\const retained = style.cssText;
        \\style.cssText = retained; equal(style.getPropertyValue('--space name'), '22PX');
        \\style.zIndex = '3'; style.zIndex = '1e2'; equal(style.zIndex, '3');
    );
}

test "CSSOM animation expansion priority resets and computed shorthand serialization" {
    try checkInlineStyle(
        \\style.animation = 'pulse 2000ms linear -500ms 2.5 alternate-reverse both paused';
        \\equal(style.animationName, 'pulse'); equal(style.animationDuration, '2000ms');
        \\equal(style.animationDelay, '-500ms'); equal(style.animationIterationCount, '2.5');
        \\equal(style.animationDirection, 'alternate-reverse'); equal(style.animationFillMode, 'both');
        \\equal(style.animationPlayState, 'paused');
        \\equal(getComputedStyle(target).animation, '2s linear -0.5s 2.5 alternate-reverse both paused pulse');
        \\style.setProperty('animation-fill-mode', 'forwards', 'important');
        \\equal(style.animation, ''); equal(style.getPropertyPriority('animation-fill-mode'), 'important');
        \\style.animation = 'none';
        \\equal(style.animationFillMode, 'none'); equal(style.animationPlayState, 'running');
        \\equal(style.animationDuration, '0s'); equal(style.animationDelay, '0s');
        \\equal(style.getPropertyPriority('animation-fill-mode'), '');
        \\style.animation = 'pulse 1s linear'; style.animationFillMode = 'nonsense';
        \\equal(style.animationFillMode, 'none'); equal(style.animationName, 'pulse');
        \\style.margin = '1px 2px'; equal(getComputedStyle(target).margin, '1px 2px');
        \\style.animationDuration = 'calc(2 * 3s)';
        \\equal(getComputedStyle(target).animationDuration, '6s');
        \\style.fontSize = '20px'; style.animationDelay = 'calc(1em / 1px * 1s)';
        \\equal(getComputedStyle(target).animationDelay, '20s');
        \\style.fontSize = '10px'; equal(getComputedStyle(target).animationDelay, '10s');
        \\style.animationDuration = 'calc(-1s)'; equal(getComputedStyle(target).animationDuration, '0s');
    );
}

fn checkInlineStyle(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const html = try document.HTMLParser.init(allocator, "<html style='--space:10px 20px'><body><div id=target style='margin:var(--space);width:20px;height:10px'></div></body></html>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    const Flush = struct {
        fn run(raw: ?*anyopaque) anyerror!void {
            try document.style(std.testing.allocator, @ptrCast(@alignCast(raw.?)), &.{});
        }
    };
    js.setStyleFlushCallback(0, Flush.run, &root);
    const script = try std.fmt.allocPrint(
        allocator,
        "try {{ var target = document.getElementById('target'); var style = target.style; function equal(a,b) {{ if(a!==b) throw Error(String(a)+' != '+String(b)); }} {s}\n true; }} catch(e) {{ String(e.stack || e); }}",
        .{source},
    );
    defer allocator.free(script);
    const result = try js.evaluate(0, script);
    if (result.isString()) {
        const failure = try result.asString().toUtf8(allocator);
        defer allocator.free(failure);
        std.debug.print("CSSOM failure: {s}\n", .{failure});
    }
    try std.testing.expect(result.isBoolean() and result.toBoolean());
}

test "CSS resolved color readback is live while declarations retain specified keywords" {
    try checkInlineStyle(
        \\style.color = 'RebeccaPurple'; style.backgroundColor = 'currentcolor';
        \\const computed = getComputedStyle(target);
        \\equal(style.color, 'rebeccapurple'); equal(style.backgroundColor, 'currentcolor');
        \\equal(computed.color, 'rgb(102, 51, 153)');
        \\equal(computed.backgroundColor, computed.color);
        \\equal(computed['background-color'], computed.backgroundColor);
        \\equal(computed.getPropertyValue('BACKGROUND-COLOR'), computed.backgroundColor);
        \\equal(computed.borderTopColor, computed.color);
        \\equal(computed.getPropertyValue('border-left-color'), computed.color);
        \\const retained = computed.color;
        \\style.color = 'rgba(1, 2, 3, .12345)';
        \\equal(computed.color, 'rgba(1, 2, 3, 0.12345)');
        \\equal(computed.backgroundColor, computed.color); equal(computed.borderRightColor, computed.color);
        \\equal(retained, 'rgb(102, 51, 153)');
        \\style.backgroundColor = 'transparent'; equal(computed.backgroundColor, 'rgba(0, 0, 0, 0)');
        \\style.backgroundColor = 'aliceblue'; equal(computed.backgroundColor, 'rgb(240, 248, 255)');
        \\style.setProperty('--Tone', 'teal'); style.color = 'var(--Tone)';
        \\equal(computed.color, 'rgb(0, 128, 128)');
        \\equal(computed.getPropertyValue('--Tone'), 'teal'); equal(computed.getPropertyValue('--tone'), '');
        \\style.color = 'unknown-color'; equal(computed.color, 'rgb(0, 128, 128)');
        \\style.color = 'var(--missing)'; equal(computed.color, 'rgb(0, 0, 0)');
    );
}

test "CSS currentcolor follows parent changes and inherited colors resolve on the receiving element" {
    try checkInlineStyle(
        \\var ancestor = target.parentNode;
        \\ancestor.style.color = 'red'; ancestor.style.backgroundColor = 'currentcolor';
        \\ancestor.style.borderColor = 'currentcolor';
        \\style.color = 'currentcolor'; style.backgroundColor = 'inherit'; style.borderColor = 'inherit';
        \\var computed = getComputedStyle(target);
        \\equal(computed.color, 'rgb(255, 0, 0)'); equal(computed.backgroundColor, computed.color);
        \\ancestor.style.color = 'green'; equal(computed.color, 'rgb(0, 128, 0)');
        \\equal(computed.backgroundColor, computed.color); equal(computed.borderBottomColor, computed.color);
        \\style.color = 'blue'; equal(computed.backgroundColor, 'rgb(0, 0, 255)');
        \\equal(computed.borderLeftColor, 'rgb(0, 0, 255)');
        \\ancestor.style.backgroundColor = 'red'; equal(computed.backgroundColor, 'rgb(255, 0, 0)');
        \\ancestor.style.backgroundColor = 'currentcolor'; equal(computed.backgroundColor, 'rgb(0, 0, 255)');
        \\ancestor.style.color = 'transparent'; style.color = 'currentcolor';
        \\equal(computed.color, 'rgba(0, 0, 0, 0)'); equal(computed.backgroundColor, computed.color);
        \\document.documentElement.style.color = 'currentcolor'; ancestor.style.color = 'inherit';
        \\equal(computed.color, 'rgb(0, 0, 0)');
    );
}

test "CSS color calculations recompute font dependencies and preserve missing components" {
    try checkInlineStyle(
        \\var ancestor = target.parentNode;
        \\ancestor.style.fontSize = '20px'; style.fontSize = 'inherit';
        \\style.color = 'rgb(calc(50% + sign(1em - 10px) * 10%) 0 0 / .5)';
        \\var computed = getComputedStyle(target);
        \\equal(computed.color, 'rgba(153, 0, 0, 0.5)');
        \\ancestor.style.fontSize = '8px';
        \\equal(computed.color, 'rgba(102, 0, 0, 0.5)');
        \\equal(style.color.indexOf('sign(') >= 0, true);
        \\style.backgroundColor = 'currentcolor';
        \\equal(computed.backgroundColor, computed.color);
        \\style.color = 'rgb(128 none 20% / none)';
        \\equal(computed.color, 'color(srgb 0.50196078 none 0.2 / none)');
        \\style.color = 'hsl(120 none 50% / none)';
        \\equal(computed.color, 'hsl(120 none 50% / none)');
        \\style.color = 'rgb(calc(infinity), calc(0 / 0), calc(-infinity))';
        \\equal(computed.color, 'rgb(255, 0, 0)');
        \\equal(CSS.supports('color', 'rgb(calc(2px) 0 0)'), false);
    );
}

test "CSSOM reads native priority winners and edits expanded shorthand declarations" {
    try checkInlineStyle(
        \\style.cssText = 'width:10px; color:red; width:20px; padding:10px !/**/important; padding-left:30px';
        \\equal(style, target.style); equal(style.length, 6);
        \\equal(style[0], 'color'); equal(style.item(1), 'width'); equal(style[6], undefined);
        \\equal(Array.from(style).join(','), 'color,width,padding-top,padding-right,padding-bottom,padding-left');
        \\equal(style.paddingLeft, '10px'); equal(style.getPropertyPriority('padding'), 'important');
        \\style.paddingLeft = '4px'; equal(style.paddingLeft, '4px'); equal(style.padding, '');
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('padding-left')), 4);
        \\style.setProperty('padding', '2px 3px'); equal(style.padding, '2px 3px');
        \\equal(style.getPropertyPriority('padding'), '');
        \\equal(style.removeProperty('padding'), '2px 3px'); equal(style.length, 2);
        \\equal(style.cssText, 'color: red; width: 20px;');
        \\style['font-weight'] = 'bold'; equal(style.fontWeight, 'bold');
        \\style.cssFloat = 'left'; equal(style.getPropertyValue('float'), 'left');
    );
}

test "CSSOM pending shorthand ownership survives unrelated edits, clone and relocation" {
    try checkInlineStyle(
        \\style.marginLeft = '4px';
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-right')), 20);
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-left')), 4);
        \\target.setAttribute('class', 'changed');
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-right')), 20);
        \\equal(style.removeProperty('margin-top'), '');
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-top')), 0);
        \\var clone = target.cloneNode(true); clone.id = 'copy'; document.body.appendChild(clone);
        \\clone.style.marginRight = '8px';
        \\equal(parseFloat(getComputedStyle(clone).getPropertyValue('margin-bottom')), 10);
        \\equal(parseFloat(getComputedStyle(clone).getPropertyValue('margin-right')), 8);
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-right')), 20);
        \\target.setAttribute('style', target.getAttribute('style'));
        \\equal(parseFloat(getComputedStyle(target).getPropertyValue('margin-right')), 0);
        \\target.removeAttribute('style'); equal(style.length, 0); equal(style.cssText, '');
        \\style.width = '31px'; equal(parseFloat(getComputedStyle(target).width), 31);
    );
}

test "CSSOM invalid setters preserve authored attribute and custom component values" {
    try checkInlineStyle(
        \\target.setAttribute('style', 'width:20px; invalid');
        \\equal(style.cssText, 'width: 20px;');
        \\style.width = 'nonsense'; style.color = 'unknown color';
        \\style.setProperty('width', 'var(--x); color:red');
        \\style.setProperty('--text', 'x !important');
        \\style.setProperty('width', '30px', 'invalid'); style.removeProperty('margin');
        \\equal(target.getAttribute('style'), 'width:20px; invalid');
        \\equal(parseFloat(getComputedStyle(target).width), 20);
        \\style.setProperty('--text', '[a;{b:c}]'); equal(style.getPropertyValue('--text'), '[a;{b:c}]');
        \\style.setProperty('--Text', 'url(a!important)'); equal(style.getPropertyPriority('--Text'), '');
        \\style.setProperty('width', '', 'invalid'); equal(style.width, '');
        \\style.cssText = 'color:green; @future {color:red;} height:12px;';
        \\equal(style.cssText, 'color: green; height: 12px;');
        \\var heldText = style.cssText, heldHeight = style.height, heldName = style.item(0);
        \\for (var i = 0; i < 40; i++) { style.height = String(100 + i) + 'px'; style.cssText; }
        \\target.removeAttribute('style');
        \\equal(heldText, 'color: green; height: 12px;'); equal(heldHeight, '12px'); equal(heldName, 'color');
    );
}

test "CSS grammar edits share colors positions escaped selectors and computed substitution" {
    try checkInlineStyle(
        \\target.className = 'sm:card a.b w-[50%] caf\u00e9';
        \\target.setAttribute('data-x', 'a b');
        \\equal(document.querySelector('.sm\\:card.a\\.b'), target);
        \\equal(document.querySelector('[da\\74 a-x="a\\20 b"]'), target);
        \\equal(document.querySelector('.w-\\[50\\%\\].caf\u00e9'), target);
        \\target.setAttribute('lang', 'en-US'); equal(document.querySelector('#target:lang(e\\6e)'), target);
        \\equal(document.querySelector('#target:lang("\\20 en")'), null);
        \\style.color = 'hsl(.5turn 100% 50% / 25%)'; equal(style.color, 'rgba(0, 255, 255, 0.25)');
        \\style.color = 'rgb(20%, 10%, 0)'; equal(style.color, 'rgba(0, 255, 255, 0.25)');
        \\style.setProperty('--channels', '0 128 0'); style.color = 'rgb(var(--channels) / .75)';
        \\equal(getComputedStyle(target).color, 'rgba(0, 128, 0, 0.75)');
        \\style.setProperty('--channels', '0, 128, 0'); equal(getComputedStyle(target).color, 'rgb(0, 0, 0)');
        \\style.background = 'none bottom -2px right 10% / 20px 30px no-repeat fixed rgb(0 128 0)';
        \\equal(style.backgroundPosition, 'right 10% bottom -2px');
        \\equal(style.backgroundSize, '20px 30px');
        \\var text = style.cssText; style.cssText = text; equal(style.cssText, text);
        \\style.backgroundPosition = 'left right'; equal(style.backgroundPosition, 'right 10% bottom -2px');
        \\style.backgroundPosition = 'top left'; equal(style.backgroundPosition, 'left top');
    );
}

test "logical selectors share DOM queries and synchronous style invalidation after mutations" {
    const CSS = @import("../document/css_parser.zig");
    const allocator = std.testing.allocator;
    var html = try document.HTMLParser.init(allocator, "<main id=container><aside id=toggle></aside><section id=target class=card><span class=badge></span></section></main>");
    defer html.deinit(allocator);
    var root = try html.parse();
    defer root.deinit(allocator);
    document.fixParentPointers(&root, null);
    var parser = try CSS.init(allocator, ".card { width:10px } :is(main > .card):not(.active + .card) { width:40px }" ++
        ":is(.active + .card) { width:80px } :where(#target) { width:99px }", false);
    defer parser.deinit(allocator);
    const rules = try parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }
    try document.style(allocator, &root, rules);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    const js = try Js.init(allocator, std.testing.io, &environ);
    defer js.deinit(allocator);
    js.setNodes(0, &root);
    defer js.setNodes(0, null);
    const Flush = struct {
        root: *document.Node,
        rules: []CSS.CSSRule,
        fn run(raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try document.style(std.testing.allocator, self.root, self.rules);
        }
    };
    var flush = Flush{ .root = &root, .rules = rules };
    js.setStyleFlushCallback(0, Flush.run, &flush);
    const result = try js.evaluate(0,
        \\try {
        \\var target = document.getElementById('target'), toggle = document.getElementById('toggle');
        \\function equal(a,b) { if (a !== b) throw Error(String(a) + ' != ' + String(b)); }
        \\equal(document.querySelector(':is(:unknown, main > .card):not(.absent, aside)'), target);
        \\equal(document.querySelector(':where()'), null);
        \\equal(document.querySelector(':where(), .card'), target);
        \\equal(document.querySelectorAll('.card, :is(.card)').length, 1);
        \\equal(document.getElementById('container').querySelector(':is(main > .card)'), target);
        \\equal(target.querySelector(':is(main:has(:is(body .badge)) > .card) .badge'), target.firstElementChild);
        \\equal(document.querySelector(':is(, :unknown, .card,)'), target);
        \\equal(getComputedStyle(target).width, '40px');
        \\toggle.className = 'active';
        \\equal(document.querySelector(':is(.active + .card)'), target);
        \\equal(document.querySelector('.card:not(.active ~ .card)'), null);
        \\equal(getComputedStyle(target).width, '80px');
        \\target.style.width = '60px'; equal(getComputedStyle(target).width, '60px');
        \\target.style.removeProperty('width'); equal(getComputedStyle(target).width, '80px');
        \\toggle.className = ''; equal(getComputedStyle(target).width, '40px');
        \\var invalid = false;
        \\try { document.querySelector(':not(.card, :unknown)'); } catch (e) { invalid = e.name === 'SyntaxError'; }
        \\equal(invalid, true);
        \\invalid = false;
        \\try { document.querySelector('.card, :unknown'); } catch(e) { invalid = e.name === 'SyntaxError'; }
        \\equal(invalid, true);
        \\var detachedDoc = document.implementation.createHTMLDocument('');
        \\invalid = false;
        \\try { detachedDoc.querySelector(':not(.a, :unknown)'); } catch(e) { invalid = e.name === 'SyntaxError'; }
        \\equal(invalid, true);
        \\true; } catch (e) { String(e.stack || e); }
    );
    if (result.isString()) {
        const failure = try result.asString().toUtf8(allocator);
        defer allocator.free(failure);
        std.debug.print("Selector host failure: {s}\n", .{failure});
    }
    try std.testing.expect(result.isBoolean() and result.toBoolean());
}
