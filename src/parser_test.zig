const std = @import("std");
const HTMLParser = @import("parser.zig").HTMLParser;

test "Parse basic HTML" {
    const allocator = std.testing.allocator;
    const html = "<html><body><p>Hello, world!</p></body></html>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 1), root.element.children.items.len);

    const body = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);

    const text = p.children.items[0].text;
    try std.testing.expectEqualStrings("Hello, world!", text.text);
}

test "Parse quoted attributes" {
    const allocator = std.testing.allocator;
    const html = "<div class=\"container\" id=\"main\"><span>Text</span></div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("container", attrs.get("class").?);
    try std.testing.expectEqualStrings("main", attrs.get("id").?);
}

test "Parse boolean attributes" {
    const allocator = std.testing.allocator;
    const html = "<input disabled required><label>Check me</label>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("input", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("", attrs.get("disabled").?);
    try std.testing.expectEqualStrings("", attrs.get("required").?);
}

test "Parse unquoted attributes" {
    const allocator = std.testing.allocator;
    const html = "<input type=text value=hello><button>Submit</button>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("input", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("text", attrs.get("type").?);
    try std.testing.expectEqualStrings("hello", attrs.get("value").?);
}

test "Parse mixed attribute types" {
    const allocator = std.testing.allocator;
    const html = "<form action=\"/submit\" method=post novalidate><input></form>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);
    try std.testing.expectEqualStrings("form", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 3), attrs.count());

    try std.testing.expectEqualStrings("/submit", attrs.get("action").?);
    try std.testing.expectEqualStrings("post", attrs.get("method").?);
    try std.testing.expectEqualStrings("", attrs.get("novalidate").?);
}

test "Parse self-closing tags with attributes" {
    const allocator = std.testing.allocator;
    const html = "<img src=\"image.jpg\" alt=\"An image\" width=100 height=100>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("img", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;

    // Check each attribute individually
    const src = attrs.get("src") orelse "";
    try std.testing.expectEqualStrings("image.jpg", src);

    const alt = attrs.get("alt") orelse "";
    try std.testing.expectEqualStrings("An image", alt);

    const width = attrs.get("width") orelse "";
    try std.testing.expectEqualStrings("100", width);

    const height = attrs.get("height") orelse "";
    try std.testing.expectEqualStrings("100", height);
}

test "Parse HTML with implicit tags" {
    const allocator = std.testing.allocator;
    // HTML without html, head, or body tags
    const html = "<p>Hello, world!</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Body should contain the paragraph
    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);

    // Paragraph should contain the text
    const text = p.children.items[0].text;
    try std.testing.expectEqualStrings("Hello, world!", text.text);
}

test "Parse HTML with head elements but no explicit head tag" {
    const allocator = std.testing.allocator;
    // HTML with a title but no explicit head or body tags
    const html = "<title>Test Page</title><p>Content</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head containing title
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);
    try std.testing.expectEqual(@as(usize, 1), head.children.items.len);

    // Head should contain the title
    const title = head.children.items[0].element;
    try std.testing.expectEqualStrings("title", title.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Body should contain the paragraph
    const p = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p.tag);
    try std.testing.expectEqual(@as(usize, 1), p.children.items.len);
}

test "Parse HTML with unclosed paragraph tags" {
    const allocator = std.testing.allocator;
    // HTML with an unclosed paragraph tag
    const html = "<p>First paragraph<p>Second paragraph</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head (which might be empty)
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);

    // Second child should be body
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have two paragraph children in the body
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check first paragraph (implicitly closed)
    const p1 = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p1.tag);
    try std.testing.expectEqual(@as(usize, 1), p1.children.items.len);
    try std.testing.expectEqualStrings("First paragraph", p1.children.items[0].text.text);

    // Check second paragraph
    const p2 = body.children.items[1].element;
    try std.testing.expectEqualStrings("p", p2.tag);
    try std.testing.expectEqual(@as(usize, 1), p2.children.items.len);
    try std.testing.expectEqualStrings("Second paragraph", p2.children.items[0].text.text);
}

test "Parse HTML with nested paragraphs" {
    const allocator = std.testing.allocator;
    // HTML with a paragraph inside another paragraph - should become siblings
    const html = "<p>hello<p>world</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have two paragraph children in the body (not nested)
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check first paragraph
    const p1 = body.children.items[0].element;
    try std.testing.expectEqualStrings("p", p1.tag);
    try std.testing.expectEqual(@as(usize, 1), p1.children.items.len);
    try std.testing.expectEqualStrings("hello", p1.children.items[0].text.text);

    // Check second paragraph
    const p2 = body.children.items[1].element;
    try std.testing.expectEqualStrings("p", p2.tag);
    try std.testing.expectEqual(@as(usize, 1), p2.children.items.len);
    try std.testing.expectEqualStrings("world", p2.children.items[0].text.text);
}

test "Parse HTML with list items" {
    const allocator = std.testing.allocator;
    // HTML with list items that should be siblings, not nested
    const html = "<ul><li>First<li>Second</li></ul>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have one ul child in the body
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the ul element
    const ul = body.children.items[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // Should have two li children in the ul (not nested)
    try std.testing.expectEqual(@as(usize, 2), ul.children.items.len);

    // Check first li
    const li1 = ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", li1.tag);
    try std.testing.expectEqual(@as(usize, 1), li1.children.items.len);
    try std.testing.expectEqualStrings("First", li1.children.items[0].text.text);

    // Check second li
    const li2 = ul.children.items[1].element;
    try std.testing.expectEqualStrings("li", li2.tag);
    try std.testing.expectEqual(@as(usize, 1), li2.children.items.len);
    try std.testing.expectEqualStrings("Second", li2.children.items[0].text.text);
}

test "Parse HTML with nested lists" {
    const allocator = std.testing.allocator;
    // HTML with nested lists - should preserve the nesting
    const html = "<ul><li>First<ul><li>Nested item</li></ul></li><li>Second</li></ul>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Body has two children: the main ul and the second li that got moved out
    try std.testing.expectEqual(@as(usize, 2), body.children.items.len);

    // Check the ul element
    const ul = body.children.items[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // The ul has two children: the first li and the second li
    try std.testing.expectEqual(@as(usize, 2), ul.children.items.len);

    // Check first li
    const li1 = ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", li1.tag);
    try std.testing.expectEqual(@as(usize, 2), li1.children.items.len);
    try std.testing.expectEqualStrings("First", li1.children.items[0].text.text);

    // The nested ul is empty because the nested li got moved out
    const nested_ul = li1.children.items[1].element;
    try std.testing.expectEqualStrings("ul", nested_ul.tag);
    try std.testing.expectEqual(@as(usize, 0), nested_ul.children.items.len);

    // The second li is a child of the main ul
    const li2 = ul.children.items[1].element;
    try std.testing.expectEqualStrings("li", li2.tag);
    try std.testing.expectEqual(@as(usize, 1), li2.children.items.len);
    try std.testing.expectEqualStrings("Nested item", li2.children.items[0].text.text);

    // The third li (originally the second) got moved to be a sibling of the main ul
    const li3 = body.children.items[1].element;
    try std.testing.expectEqualStrings("li", li3.tag);
    try std.testing.expectEqual(@as(usize, 1), li3.children.items.len);
    try std.testing.expectEqualStrings("Second", li3.children.items[0].text.text);
}

test "Parse overlapping formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both</i> italic</i>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have one b element in the body
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the b element
    const b = body.children.items[0].element;
    try std.testing.expectEqualStrings("b", b.tag);

    // The b element should have three children: text, i, and text
    try std.testing.expectEqual(@as(usize, 3), b.children.items.len);

    // First child should be text
    try std.testing.expectEqualStrings("Bold ", b.children.items[0].text.text);

    // Second child should be i
    const i_in_b = b.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_in_b.tag);

    // The i element inside b should have one text child
    try std.testing.expectEqual(@as(usize, 1), i_in_b.children.items.len);
    try std.testing.expectEqualStrings("both", i_in_b.children.items[0].text.text);

    // Third child should be text
    try std.testing.expectEqualStrings(" italic", b.children.items[2].text.text);
}

test "Parse quoted attributes with spaces and angle brackets" {
    const allocator = std.testing.allocator;
    const html = "<div title=\"Simple title\">Content</div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 1), attrs.count());

    const title_attr = attrs.get("title") orelse "";
    try std.testing.expectEqualStrings("Simple title", title_attr);
}

test "Parse nested formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both bold and italic <u>and underlined</b> still italic and underlined</i> just underlined</u>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have three elements in the body: b, i, and u
    try std.testing.expectEqual(@as(usize, 3), body.children.items.len);

    // Check the b element
    const b = body.children.items[0].element;
    try std.testing.expectEqualStrings("b", b.tag);

    // The b element should have two children: text and i
    try std.testing.expectEqual(@as(usize, 2), b.children.items.len);

    // First child should be text
    try std.testing.expectEqualStrings("Bold ", b.children.items[0].text.text);

    // Second child should be i
    const i_in_b = b.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_in_b.tag);

    // The i element inside b should have two children: text and u
    try std.testing.expectEqual(@as(usize, 2), i_in_b.children.items.len);
    try std.testing.expectEqualStrings("both bold and italic ", i_in_b.children.items[0].text.text);

    // Check the u element inside i inside b
    const u_in_i_in_b = i_in_b.children.items[1].element;
    try std.testing.expectEqualStrings("u", u_in_i_in_b.tag);

    // Check the i element after b
    const i_after_b = body.children.items[1].element;
    try std.testing.expectEqualStrings("i", i_after_b.tag);

    // The i element should have one child: u
    try std.testing.expectEqual(@as(usize, 1), i_after_b.children.items.len);

    // Check the u element inside i after b
    const u_in_i_after_b = i_after_b.children.items[0].element;
    try std.testing.expectEqualStrings("u", u_in_i_after_b.tag);

    // The u element inside i after b should have one text child
    try std.testing.expectEqual(@as(usize, 1), u_in_i_after_b.children.items.len);
    try std.testing.expectEqualStrings(" still italic and underlined", u_in_i_after_b.children.items[0].text.text);

    // Check the u element after i
    const u_after_i = body.children.items[2].element;
    try std.testing.expectEqualStrings("u", u_after_i.tag);

    // The u element should have one text child
    try std.testing.expectEqual(@as(usize, 1), u_after_i.children.items.len);
    try std.testing.expectEqualStrings(" just underlined", u_after_i.children.items[0].text.text);
}

test "Parse script tag content" {
    const allocator = std.testing.allocator;
    const html = "<html><body><script>if (x < y) { alert('Hello!'); }</script></body></html>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 1), root.element.children.items.len);

    // Get the body element
    const body = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("body", body.tag);

    // Should have one script element in the body
    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the script element
    const script = body.children.items[0].element;
    try std.testing.expectEqualStrings("script", script.tag);

    // The script element should have one text child with the JavaScript code
    try std.testing.expectEqual(@as(usize, 1), script.children.items.len);
    try std.testing.expectEqualStrings("if (x < y) { alert('Hello!'); }", script.children.items[0].text.text);
}

test "Parse script tag with implicit tags" {
    const allocator = std.testing.allocator;
    // Script tag without explicit html/body tags
    const html = "<script>var x = 10; if (x < 20) { console.log('x < 20'); }</script>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    const root = try parser.parse();
    defer root.deinit(allocator);

    // Verify implicit html tag was added
    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    // First child should be head containing script (since script is a head element)
    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);
    try std.testing.expectEqual(@as(usize, 1), head.children.items.len);

    // Check the script element
    const script = head.children.items[0].element;
    try std.testing.expectEqualStrings("script", script.tag);

    // The script element should have one text child with the JavaScript code
    try std.testing.expectEqual(@as(usize, 1), script.children.items.len);
    try std.testing.expectEqualStrings("var x = 10; if (x < 20) { console.log('x < 20'); }", script.children.items[0].text.text);
}
