//! Live CSS declaration and synchronous computed-style readback regressions.
const std = @import("std");
const document = @import("../document/parser.zig");
const Js = @import("../script/js.zig");

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
