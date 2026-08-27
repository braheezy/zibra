//! Regression tests for the tutorial HTML parser and DOM construction rules.

const std = @import("std");
const document_parser = @import("../document/parser.zig");
const HTMLParser = document_parser.HTMLParser;
const CSSParser = @import("../document/css_parser.zig").CSSParser;

test "Parse basic HTML" {
    const allocator = std.testing.allocator;
    const html = "<html><body><p>Hello, world!</p></body></html>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
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

test "input type helpers recognize hidden password and text defaults" {
    const allocator = std.testing.allocator;
    var hidden = try document_parser.Element.init(allocator, "input type=' HiDdEn '", null);
    defer hidden.deinit(allocator);
    var password = try document_parser.Element.init(allocator, "input type=PASSWORD", null);
    defer password.deinit(allocator);
    var text = try document_parser.Element.init(allocator, "input", null);
    defer text.deinit(allocator);

    try std.testing.expectEqualStrings("HiDdEn", hidden.inputType());
    try std.testing.expect(hidden.isHiddenInput());
    try std.testing.expect(!hidden.isPasswordInput());
    try std.testing.expect(password.isPasswordInput());
    try std.testing.expectEqualStrings("text", text.inputType());
}

test "HTML serialization emits live attributes children and void elements" {
    const allocator = std.testing.allocator;
    const html =
        "<section z=last empty data=\"a&amp;&quot;&lt;&gt;&apos;\">" ++
        "<span id=foo>Chris &amp; here</span><input checked></section>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const inner = try document_parser.serializeInnerHtml(allocator, &root);
    defer allocator.free(inner);
    try std.testing.expectEqualStrings(
        "<span id=\"foo\">Chris &amp; here</span><input checked=\"\">",
        inner,
    );

    const outer = try document_parser.serializeOuterHtml(allocator, &root);
    defer allocator.free(outer);
    try std.testing.expectEqualStrings(
        "<section data=\"a&amp;&quot;&lt;&gt;&apos;\" empty=\"\" z=\"last\">" ++
            "<span id=\"foo\">Chris &amp; here</span><input checked=\"\"></section>",
        outer,
    );
}

test "style element text can be collected and parsed as CSS" {
    const allocator = std.testing.allocator;
    const html =
        "<html><head><style>p { color: red; }\n.note { font-weight: bold; }</style></head>" ++
        "<body><p class=note>styled</p></body></html>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var nodes = std.ArrayList(*document_parser.Node).empty;
    defer nodes.deinit(allocator);
    try document_parser.treeToList(allocator, &root, &nodes);

    var style_text: ?[]u8 = null;
    var paragraph: ?*document_parser.Node = null;
    for (nodes.items) |node| {
        switch (node.*) {
            .element => |element| {
                if (std.mem.eql(u8, element.tag, "style")) {
                    style_text = try document_parser.collectInlineStyleText(allocator, node);
                } else if (std.mem.eql(u8, element.tag, "p")) {
                    paragraph = node;
                }
            },
            .text => {},
        }
    }
    defer if (style_text) |text| allocator.free(text);

    try std.testing.expectEqualStrings(
        "p { color: red; }\n.note { font-weight: bold; }",
        style_text.?,
    );

    var css_parser = try CSSParser.init(allocator, style_text.?, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    std.mem.sort(CSSParser.CSSRule, rules, {}, struct {
        fn lessThan(_: void, a: CSSParser.CSSRule, b: CSSParser.CSSRule) bool {
            return a.cascadePriority() < b.cascadePriority();
        }
    }.lessThan);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings(
        "red",
        paragraph.?.element.style.?.getPtr("color").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "bold",
        paragraph.?.element.style.?.getPtr("font-weight").?.get().*,
    );
}

test "Parse quoted attributes" {
    const allocator = std.testing.allocator;
    const html = "<div class=\"container\" id=\"main\"><span>Text</span></div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    try std.testing.expectEqualStrings("container", attrs.get("class").?);
    try std.testing.expectEqualStrings("main", attrs.get("id").?);
}

test "attribute character references decode into element-owned strings" {
    const allocator = std.testing.allocator;
    const html =
        "<a href=\"https://example.com/?a=1&amp;b=&quot;two&quot;&apos;&#x1F642;\" " ++
        "data-unknown=\"&unknown;\">label &amp; text</a>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings(
        "https://example.com/?a=1&b=\"two\"'🙂",
        root.element.attributes.?.get("href").?,
    );
    try std.testing.expectEqualStrings(
        "&unknown;",
        root.element.attributes.?.get("data-unknown").?,
    );
    try std.testing.expect(root.element.owned_strings != null);
    try std.testing.expectEqual(@as(usize, 1), root.element.owned_strings.?.items.len);

    // Text stays escaped in the DOM and is decoded once by layout.
    try std.testing.expectEqualStrings("label &amp; text", root.element.children.items[0].text.text);
}

test "DOM dump re-escapes decoded attribute values" {
    const allocator = std.testing.allocator;
    const html = "<div title=\"&quot;&amp;&lt;&gt;&apos;\">x</div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings(
        "\"&<>'",
        root.element.attributes.?.get("title").?,
    );

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try html_parser.writePretty(&output.writer, root, 0);
    try std.testing.expectEqualStrings(
        "<div title=\"&quot;&amp;&lt;&gt;&apos;\">\n  x\n",
        output.written(),
    );
}

test "Parse boolean attributes" {
    const allocator = std.testing.allocator;
    const html = "<input disabled required><label>Check me</label>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
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

    var root = try parser.parse();
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

    var root = try parser.parse();
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

    var root = try parser.parse();
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

    var root = try parser.parse();
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

test "Parse empty HTML as an implicit blank document" {
    const allocator = std.testing.allocator;

    var parser = try HTMLParser.init(allocator, "");
    defer parser.deinit(allocator);

    var root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("html", root.element.tag);
    try std.testing.expectEqual(@as(usize, 2), root.element.children.items.len);

    const head = root.element.children.items[0].element;
    try std.testing.expectEqualStrings("head", head.tag);
    try std.testing.expectEqual(@as(usize, 0), head.children.items.len);

    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);
    try std.testing.expectEqual(@as(usize, 0), body.children.items.len);
}

test "Parse HTML with head elements but no explicit head tag" {
    const allocator = std.testing.allocator;
    // HTML with a title but no explicit head or body tags
    const html = "<title>Test Page</title><p>Content</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    var root = try parser.parse();
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

test "document title copies the first title element text" {
    const allocator = std.testing.allocator;
    const html =
        "<html><head><title>First title</title><title>Ignored</title></head>" ++
        "<body><p>Content</p></body></html>";

    var html_parser = try HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const title = (try document_parser.collectDocumentTitle(allocator, &root)).?;
    defer allocator.free(title);
    try std.testing.expectEqualStrings("First title", title);
}

test "document title distinguishes an empty title from a missing title" {
    const allocator = std.testing.allocator;

    var empty_parser = try HTMLParser.init(allocator, "<title></title><p>Content</p>");
    defer empty_parser.deinit(allocator);
    var empty_root = try empty_parser.parse();
    defer empty_root.deinit(allocator);
    const empty_title = (try document_parser.collectDocumentTitle(allocator, &empty_root)).?;
    defer allocator.free(empty_title);
    try std.testing.expectEqual(@as(usize, 0), empty_title.len);

    var missing_parser = try HTMLParser.init(allocator, "<p>Content</p>");
    defer missing_parser.deinit(allocator);
    var missing_root = try missing_parser.parse();
    defer missing_root.deinit(allocator);
    try std.testing.expect((try document_parser.collectDocumentTitle(allocator, &missing_root)) == null);
}

test "Parse HTML with unclosed paragraph tags" {
    const allocator = std.testing.allocator;
    // HTML with an unclosed paragraph tag
    const html = "<p>First paragraph<p>Second paragraph</p>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    var root = try parser.parse();
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

    var root = try parser.parse();
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

    var root = try parser.parse();
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

    var root = try parser.parse();
    defer root.deinit(allocator);

    // Get the body element
    const body = root.element.children.items[1].element;
    try std.testing.expectEqualStrings("body", body.tag);

    try std.testing.expectEqual(@as(usize, 1), body.children.items.len);

    // Check the ul element
    const ul = body.children.items[0].element;
    try std.testing.expectEqualStrings("ul", ul.tag);

    // The outer ul has two sibling list items.
    try std.testing.expectEqual(@as(usize, 2), ul.children.items.len);

    // Check first li
    const li1 = ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", li1.tag);
    try std.testing.expectEqual(@as(usize, 2), li1.children.items.len);
    try std.testing.expectEqualStrings("First", li1.children.items[0].text.text);

    // The nested ul retains its list item.
    const nested_ul = li1.children.items[1].element;
    try std.testing.expectEqualStrings("ul", nested_ul.tag);
    try std.testing.expectEqual(@as(usize, 1), nested_ul.children.items.len);
    const nested_li = nested_ul.children.items[0].element;
    try std.testing.expectEqualStrings("li", nested_li.tag);
    try std.testing.expectEqualStrings("Nested item", nested_li.children.items[0].text.text);

    // The second li is a child of the main ul
    const li2 = ul.children.items[1].element;
    try std.testing.expectEqualStrings("li", li2.tag);
    try std.testing.expectEqual(@as(usize, 1), li2.children.items.len);
    try std.testing.expectEqualStrings("Second", li2.children.items[0].text.text);
}

test "Parse overlapping formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both</i> italic</i>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    var root = try parser.parse();
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
    const html = "<div title=\"A > B with spaces\" data-note='left > right'>Content</div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expect(root.element.attributes != null);

    const attrs = root.element.attributes.?;
    try std.testing.expectEqual(@as(usize, 2), attrs.count());

    const title_attr = attrs.get("title") orelse "";
    try std.testing.expectEqualStrings("A > B with spaces", title_attr);
    try std.testing.expectEqualStrings("left > right", attrs.get("data-note").?);
}

test "Parse nested formatting elements" {
    const allocator = std.testing.allocator;
    const html = "<b>Bold <i>both bold and italic <u>and underlined</b> still italic and underlined</i> just underlined</u>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    var root = try parser.parse();
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
    const html = "<html><body><script>if (x < y) { alert('<em>not markup</em>'); }</script></body></html>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
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
    try std.testing.expectEqualStrings("if (x < y) { alert('<em>not markup</em>'); }", script.children.items[0].text.text);
}

test "Parse script tag with implicit tags" {
    const allocator = std.testing.allocator;
    // Script tag without explicit html/body tags
    const html = "<script>var x = 10; if (x < 20) { console.log('x < 20'); }</script>";

    var parser = try HTMLParser.init(allocator, html);
    defer parser.deinit(allocator);

    var root = try parser.parse();
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

test "Parse HTML comments without emitting nodes" {
    const allocator = std.testing.allocator;
    const html = "<div>before<!-- <fake> and </fake> > -->after<span>child</span><!-- unfinished";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expectEqual(@as(usize, 3), root.element.children.items.len);
    try std.testing.expectEqualStrings("before", root.element.children.items[0].text.text);
    try std.testing.expectEqualStrings("after", root.element.children.items[1].text.text);
    try std.testing.expectEqualStrings("span", root.element.children.items[2].element.tag);
    try std.testing.expectEqualStrings("child", root.element.children.items[2].element.children.items[0].text.text);
}

test "Parse abruptly closed empty HTML comment" {
    const allocator = std.testing.allocator;
    const html = "<div><!-->visible</div>";

    var parser = try HTMLParser.init(allocator, html);
    parser.use_implicit_tags = false;
    defer parser.deinit(allocator);

    var root = try parser.parse();
    defer root.deinit(allocator);

    try std.testing.expectEqualStrings("div", root.element.tag);
    try std.testing.expectEqual(@as(usize, 1), root.element.children.items.len);
    try std.testing.expectEqualStrings("visible", root.element.children.items[0].text.text);
}

test "Apply tag and class CSS selectors" {
    const allocator = std.testing.allocator;
    const html = "<nav class=\"chapter links\">Previous | Next</nav>";
    const css = "nav.links { background-color: lightgray; } .chapter { color: blue; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    const styles = root.element.style.?;
    try std.testing.expectEqualStrings("lightgray", styles.getPtr("background-color").?.get().*);
    try std.testing.expectEqualStrings("blue", styles.getPtr("color").?.get().*);
}

test "selector sequences require every member and sum priorities" {
    const allocator = std.testing.allocator;
    const html =
        "<div>" ++
        "<span class=\"announce urgent\">Both classes</span>" ++
        "<span class=announce>One class</span>" ++
        "<div class=\"announce urgent\">Wrong tag</div>" ++
        "</div>";
    const css =
        ".announce { color: blue; }" ++
        "SPAN.announce { color: green; }" ++
        "span.announce.urgent { font-weight: bold; }" ++
        ".announce.urgent { background-color: lightgray; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 4), rules.len);
    switch (rules[1].selector) {
        .sequence => |sequence| {
            try std.testing.expectEqual(@as(usize, 2), sequence.selectors.items.len);
        },
        else => return error.TestExpectedSelectorSequence,
    }
    switch (rules[2].selector) {
        .sequence => |sequence| {
            try std.testing.expectEqual(@as(usize, 3), sequence.selectors.items.len);
        },
        else => return error.TestExpectedSelectorSequence,
    }
    try std.testing.expectEqual(@as(u32, 10), rules[0].cascadePriority());
    try std.testing.expectEqual(@as(u32, 11), rules[1].cascadePriority());
    try std.testing.expectEqual(@as(u32, 21), rules[2].cascadePriority());
    try std.testing.expectEqual(@as(u32, 20), rules[3].cascadePriority());

    try document_parser.style(allocator, &root, rules);
    const both = &root.element.children.items[0].element;
    const one = &root.element.children.items[1].element;
    const wrong_tag = &root.element.children.items[2].element;

    try std.testing.expectEqualStrings("green", both.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("bold", both.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("lightgray", both.style.?.getPtr("background-color").?.get().*);

    try std.testing.expectEqualStrings("green", one.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("normal", one.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("transparent", one.style.?.getPtr("background-color").?.get().*);

    try std.testing.expectEqualStrings("blue", wrong_tag.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("normal", wrong_tag.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("lightgray", wrong_tag.style.?.getPtr("background-color").?.get().*);

    var invalid_parser = try CSSParser.init(allocator, "span..urgent", false);
    defer invalid_parser.deinit(allocator);
    try std.testing.expectError(error.InvalidSelector, invalid_parser.selector(allocator));
}

test ":focus-visible matches the installed focus heuristic and recomputes styles" {
    const allocator = std.testing.allocator;
    const html =
        "<main><button class=widget>Outside-form button</button>" ++
        "<input value=editable></main>";
    const css =
        ".widget { color: blue; }" ++
        "button.widget:focus-visible { color: green; }" ++
        "main :focus-visible { background-color: lightgray; }" ++
        "input:focus-visible { font-weight: bold; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 4), rules.len);
    switch (rules[1].selector) {
        .sequence => |sequence| {
            try std.testing.expectEqual(@as(usize, 3), sequence.selectors.items.len);
        },
        else => return error.TestExpectedSelectorSequence,
    }
    // button (1) + .widget (10) + :focus-visible (10)
    try std.testing.expectEqual(@as(u32, 21), rules[1].cascadePriority());

    try document_parser.style(allocator, &root, rules);
    const button = &root.element.children.items[0].element;
    const input = &root.element.children.items[1].element;
    try std.testing.expectEqualStrings("blue", button.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings(
        "transparent",
        button.style.?.getPtr("background-color").?.get().*,
    );

    // Focus alone is insufficient when pointer modality suppressed the ring.
    button.is_focused = true;
    button.is_focus_visible = false;
    document_parser.dirtyStyleForElement(button);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("blue", button.style.?.getPtr("color").?.get().*);

    button.is_focus_visible = true;
    document_parser.dirtyStyleForElement(button);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("green", button.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings(
        "lightgray",
        button.style.?.getPtr("background-color").?.get().*,
    );

    button.is_focused = false;
    button.is_focus_visible = false;
    input.is_focused = true;
    input.is_focus_visible = true;
    document_parser.dirtyStyleForElement(button);
    document_parser.dirtyStyleForElement(input);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("bold", input.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings(
        "lightgray",
        input.style.?.getPtr("background-color").?.get().*,
    );

    var unsupported_parser = try CSSParser.init(allocator, "button:hover", false);
    defer unsupported_parser.deinit(allocator);
    try std.testing.expectError(error.InvalidSelector, unsupported_parser.selector(allocator));
}

test "descendant selectors are flat and match ordered ancestor chains" {
    const allocator = std.testing.allocator;
    const html =
        "<main><aside><section class=chapter><div><article>" ++
        "<span class=target>Matched</span>" ++
        "</article></div></section></aside></main>";
    const css =
        "main section.chapter article .target { color: green; }" ++
        "section main article .target { color: red; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 2), rules.len);
    switch (rules[0].selector) {
        .descendant => |descendant| {
            try std.testing.expectEqual(@as(usize, 4), descendant.selectors.items.len);
        },
        else => return error.TestExpectedDescendantSelector,
    }
    // main (1) + section.chapter (11) + article (1) + .target (10)
    try std.testing.expectEqual(@as(u32, 23), rules[0].cascadePriority());

    try document_parser.style(allocator, &root, rules);
    const target = &root.element.children.items[0]
        .element.children.items[0]
        .element.children.items[0]
        .element.children.items[0]
        .element.children.items[0].element;
    try std.testing.expectEqualStrings(
        "green",
        target.style.?.getPtr("color").?.get().*,
    );
}

test ":has selectors match strict descendants, cascade, and recompute" {
    const allocator = std.testing.allocator;
    const html =
        "<main>" ++
        "<div class=card><section><span class=badge>Matched</span></section></div>" ++
        "<div class=card><section><em class=badge>Wrong tag</em></section></div>" ++
        "</main>";
    const css =
        "main div.card:HAS(span.badge) { color: green; background-color: lightgray; }" ++
        "div.card { color: blue; }" ++
        "span.badge:has(span.badge) { font-weight: bold; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try std.testing.expectEqual(@as(usize, 3), rules.len);
    switch (rules[0].selector) {
        .descendant => |descendant| {
            try std.testing.expectEqual(@as(usize, 2), descendant.selectors.items.len);
            try std.testing.expect(descendant.selectors.items[1] == .has);
        },
        else => return error.TestExpectedDescendantSelector,
    }
    // main (1) + div.card (11) + span.badge (11)
    try std.testing.expectEqual(@as(u32, 23), rules[0].cascadePriority());

    try document_parser.style(allocator, &root, rules);
    const matching_card = &root.element.children.items[0].element;
    const other_card = &root.element.children.items[1].element;
    const badge = &matching_card.children.items[0].element.children.items[0];

    try std.testing.expectEqualStrings("green", matching_card.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("lightgray", matching_card.style.?.getPtr("background-color").?.get().*);
    try std.testing.expectEqualStrings("blue", other_card.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("transparent", other_card.style.?.getPtr("background-color").?.get().*);
    // :has examines strict descendants; the selected node cannot satisfy its
    // own relational argument.
    try std.testing.expectEqualStrings("normal", badge.element.style.?.getPtr("font-weight").?.get().*);

    // A descendant-only mutation must invalidate the ancestor's relational
    // match even when the ancestor itself was not explicitly dirtied.
    try badge.element.attributes.?.put("class", "removed");
    document_parser.dirtyStyleForElement(&badge.element);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("blue", matching_card.style.?.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("transparent", matching_card.style.?.getPtr("background-color").?.get().*);

    try badge.element.attributes.?.put("class", "badge");
    document_parser.dirtyStyleForElement(&badge.element);
    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("green", matching_card.style.?.getPtr("color").?.get().*);

    var unclosed_parser = try CSSParser.init(allocator, "div:has(span", false);
    defer unclosed_parser.deinit(allocator);
    try std.testing.expectError(error.InvalidLiteral, unclosed_parser.selector(allocator));

    var unsupported_chain_parser = try CSSParser.init(allocator, "div:has(section span)", false);
    defer unsupported_chain_parser.deinit(allocator);
    try std.testing.expectError(error.InvalidLiteral, unsupported_chain_parser.selector(allocator));
}

test "important declarations retain values, priority, and shorthand metadata" {
    const allocator = std.testing.allocator;
    var css_parser = try CSSParser.init(
        allocator,
        "color: red !IMPORTANT; color: blue; background-color: white; " ++
            "font: italic bold 125% monospace ! important; font-style: normal",
        false,
    );
    defer css_parser.deinit(allocator);
    var declarations = try css_parser.body(allocator);
    defer declarations.deinit();

    const color = declarations.get("color").?;
    try std.testing.expectEqualStrings("red", color.value);
    try std.testing.expect(color.important);
    try std.testing.expectEqual(@as(u32, 10_007), color.priority(7));

    const background = declarations.get("background-color").?;
    try std.testing.expectEqualStrings("white", background.value);
    try std.testing.expect(!background.important);
    try std.testing.expectEqual(@as(u32, 7), background.priority(7));

    try std.testing.expectEqualStrings("italic", declarations.get("font-style").?.value);
    try std.testing.expectEqualStrings("bold", declarations.get("font-weight").?.value);
    try std.testing.expectEqualStrings("125%", declarations.get("font-size").?.value);
    try std.testing.expectEqualStrings("monospace", declarations.get("font-family").?.value);
    try std.testing.expect(declarations.get("font-style").?.important);
    try std.testing.expect(declarations.get("font-weight").?.important);
    try std.testing.expect(declarations.get("font-size").?.important);
    try std.testing.expect(declarations.get("font-family").?.important);
}

test "important declarations cascade per property" {
    const allocator = std.testing.allocator;
    const html =
        "<p class=notice style=\"color: purple; background-color: orange !important\">" ++
        "Important cascade</p>";
    const css =
        ".notice { color: red !important; font-style: normal !important; " ++
        "font-weight: bold; background-color: blue !important; outline: red !important; }" ++
        "p { color: black !important; font-style: italic !important; " ++
        "font-weight: normal; background-color: white; }" ++
        ".notice { outline: blue !important; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    const styles = root.element.style.?;
    // Important class declarations beat later important tag declarations and
    // normal inline styles. Important inline declarations retain inline
    // specificity, while unrelated normal properties cascade normally.
    try std.testing.expectEqualStrings("red", styles.getPtr("color").?.get().*);
    try std.testing.expectEqualStrings("normal", styles.getPtr("font-style").?.get().*);
    try std.testing.expectEqualStrings("bold", styles.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("orange", styles.getPtr("background-color").?.get().*);
    try std.testing.expectEqualStrings("blue", styles.getPtr("outline").?.get().*);
}

test "font-family is inherited and code uses the user-agent monospace family" {
    const allocator = std.testing.allocator;
    const html =
        "<p>prose <code>inline <span style=\"font-family: inherit\">code</span></code> " ++
        "<em style=\"font-family: sans-serif\">override</em></p>";
    const browser_css = @embedFile("../browser/browser.css");

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, browser_css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);

    const paragraph = &root.element;
    try std.testing.expectEqualStrings(
        "sans-serif",
        paragraph.style.?.getPtr("font-family").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "sans-serif",
        paragraph.children.items[0].text.style.?.getPtr("font-family").?.get().*,
    );

    const code = &paragraph.children.items[1].element;
    try std.testing.expectEqualStrings(
        "monospace",
        code.style.?.getPtr("font-family").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "monospace",
        code.children.items[0].text.style.?.getPtr("font-family").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "monospace",
        code.children.items[1].element.style.?.getPtr("font-family").?.get().*,
    );

    const override = &paragraph.children.items[paragraph.children.items.len - 1].element;
    try std.testing.expectEqualStrings(
        "sans-serif",
        override.style.?.getPtr("font-family").?.get().*,
    );
}

test "font shorthand expands in declaration order" {
    const allocator = std.testing.allocator;

    var parser = try CSSParser.init(
        allocator,
        "font-weight: normal; font: Italic Bold 125% \"Courier New\", monospace; font-style: normal",
        false,
    );
    defer parser.deinit(allocator);
    var properties = try parser.body(allocator);
    defer properties.deinit();

    try std.testing.expect(properties.get("font") == null);
    try std.testing.expectEqualStrings("normal", properties.get("font-style").?.value);
    try std.testing.expectEqualStrings("bold", properties.get("font-weight").?.value);
    try std.testing.expectEqualStrings("125%", properties.get("font-size").?.value);
    try std.testing.expectEqualStrings("normal", properties.get("line-height").?.value);
    try std.testing.expectEqualStrings("\"Courier New\", monospace", properties.get("font-family").?.value);

    var reset_parser = try CSSParser.init(
        allocator,
        "font-style: italic; font-weight: bold; font: 18px sans-serif",
        false,
    );
    defer reset_parser.deinit(allocator);
    var reset_properties = try reset_parser.body(allocator);
    defer reset_properties.deinit();
    try std.testing.expectEqualStrings("normal", reset_properties.get("font-style").?.value);
    try std.testing.expectEqualStrings("normal", reset_properties.get("font-weight").?.value);
    try std.testing.expectEqualStrings("18px", reset_properties.get("font-size").?.value);
    try std.testing.expectEqualStrings("normal", reset_properties.get("line-height").?.value);
    try std.testing.expectEqualStrings("sans-serif", reset_properties.get("font-family").?.value);

    var invalid_parser = try CSSParser.init(
        allocator,
        "font: italic bold MissingSize; color: red",
        false,
    );
    defer invalid_parser.deinit(allocator);
    var invalid_properties = try invalid_parser.body(allocator);
    defer invalid_properties.deinit();
    try std.testing.expect(invalid_properties.get("font-style") == null);
    try std.testing.expect(invalid_properties.get("font-weight") == null);
    try std.testing.expect(invalid_properties.get("font-size") == null);
    try std.testing.expect(invalid_properties.get("font-family") == null);
    try std.testing.expectEqualStrings("red", invalid_properties.get("color").?.value);
}

test "font shorthand accepts full optional fields and slash line-height" {
    const allocator = std.testing.allocator;

    var css_parser = try CSSParser.init(
        allocator,
        "font: oblique small-caps 600 semi-condensed 10px/1.5 \"Verdana\", sans-serif !important",
        false,
    );
    defer css_parser.deinit(allocator);
    var declarations = try css_parser.body(allocator);
    defer declarations.deinit();

    try std.testing.expectEqualStrings("oblique", declarations.get("font-style").?.value);
    try std.testing.expectEqualStrings("small-caps", declarations.get("font-variant").?.value);
    try std.testing.expectEqualStrings("600", declarations.get("font-weight").?.value);
    try std.testing.expectEqualStrings("semi-condensed", declarations.get("font-stretch").?.value);
    try std.testing.expectEqualStrings("10px", declarations.get("font-size").?.value);
    try std.testing.expectEqualStrings("1.5", declarations.get("line-height").?.value);
    try std.testing.expectEqualStrings("\"Verdana\", sans-serif", declarations.get("font-family").?.value);
    try std.testing.expect(declarations.get("line-height").?.important);

    var spacing_parser = try CSSParser.init(
        allocator,
        "font: 10px / 1 Courier, monospace",
        false,
    );
    defer spacing_parser.deinit(allocator);
    var spacing = try spacing_parser.body(allocator);
    defer spacing.deinit();
    try std.testing.expectEqualStrings("10px", spacing.get("font-size").?.value);
    try std.testing.expectEqualStrings("1", spacing.get("line-height").?.value);
    try std.testing.expectEqualStrings("Courier, monospace", spacing.get("font-family").?.value);
}

test "box model shorthands expand into computed longhands" {
    const allocator = std.testing.allocator;

    var css_parser = try CSSParser.init(
        allocator,
        "margin: 1px 2px 3px 4px; padding: 5px 6px 7px; " ++
            "border: 2px solid red; border-left: 4px dashed blue; " ++
            "border-right-width: 3px; margin-top: 8px !important; margin: 9px",
        false,
    );
    defer css_parser.deinit(allocator);
    var declarations = try css_parser.body(allocator);
    defer declarations.deinit();

    try std.testing.expectEqualStrings("8px", declarations.get("margin-top").?.value);
    try std.testing.expect(declarations.get("margin-top").?.important);
    try std.testing.expectEqualStrings("9px", declarations.get("margin-right").?.value);
    try std.testing.expectEqualStrings("9px", declarations.get("margin-bottom").?.value);
    try std.testing.expectEqualStrings("9px", declarations.get("margin-left").?.value);

    try std.testing.expectEqualStrings("5px", declarations.get("padding-top").?.value);
    try std.testing.expectEqualStrings("6px", declarations.get("padding-right").?.value);
    try std.testing.expectEqualStrings("7px", declarations.get("padding-bottom").?.value);
    try std.testing.expectEqualStrings("6px", declarations.get("padding-left").?.value);

    try std.testing.expectEqualStrings("2px", declarations.get("border-top-width").?.value);
    try std.testing.expectEqualStrings("3px", declarations.get("border-right-width").?.value);
    try std.testing.expectEqualStrings("2px", declarations.get("border-bottom-width").?.value);
    try std.testing.expectEqualStrings("4px", declarations.get("border-left-width").?.value);
    try std.testing.expectEqualStrings("solid", declarations.get("border-top-style").?.value);
    try std.testing.expectEqualStrings("solid", declarations.get("border-right-style").?.value);
    try std.testing.expectEqualStrings("solid", declarations.get("border-bottom-style").?.value);
    try std.testing.expectEqualStrings("dashed", declarations.get("border-left-style").?.value);
    try std.testing.expectEqualStrings("red", declarations.get("border-top-color").?.value);
    try std.testing.expectEqualStrings("red", declarations.get("border-right-color").?.value);
    try std.testing.expectEqualStrings("red", declarations.get("border-bottom-color").?.value);
    try std.testing.expectEqualStrings("blue", declarations.get("border-left-color").?.value);
}

test "box model longhands survive style computation" {
    const allocator = std.testing.allocator;
    const html = "<div class=box>content</div>";
    const css = ".box { margin: 1em 2em; padding: 3px; border: 4px solid #123456; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    const styles = root.element.style.?;
    try std.testing.expectEqualStrings("1em", styles.getPtr("margin-top").?.get().*);
    try std.testing.expectEqualStrings("2em", styles.getPtr("margin-right").?.get().*);
    try std.testing.expectEqualStrings("3px", styles.getPtr("padding-bottom").?.get().*);
    try std.testing.expectEqualStrings("4px", styles.getPtr("border-left-width").?.get().*);
    try std.testing.expectEqualStrings("solid", styles.getPtr("border-right-style").?.get().*);
    try std.testing.expectEqualStrings("#123456", styles.getPtr("border-top-color").?.get().*);
}

test "float and clear survive style computation" {
    const allocator = std.testing.allocator;
    const html = "<html><body><div class=left>left</div><div class=right>right</div><p class=after>after</p></body></html>";
    const css = ".left { float: left; } .right { float: right; } .after { clear: both; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    const body = &root.element.children.items[0].element;
    const left = body.children.items[0].element.style.?;
    const right = body.children.items[1].element.style.?;
    const after = body.children.items[2].element.style.?;
    try std.testing.expectEqualStrings("left", left.getPtr("float").?.get().*);
    try std.testing.expectEqualStrings("right", right.getPtr("float").?.get().*);
    try std.testing.expectEqualStrings("both", after.getPtr("clear").?.get().*);
}

test "font shorthand produces inherited computed longhands" {
    const allocator = std.testing.allocator;
    const html = "<p class=sample>parent <span>child</span></p>";
    const css = ".sample { font: italic bold 150% \"Courier New\", monospace; }";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    const styles = root.element.style.?;
    try std.testing.expectEqualStrings("italic", styles.getPtr("font-style").?.get().*);
    try std.testing.expectEqualStrings("bold", styles.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("normal", styles.getPtr("line-height").?.get().*);
    try std.testing.expectEqualStrings("24.0px", styles.getPtr("font-size").?.get().*);
    try std.testing.expectEqualStrings(
        "\"Courier New\", monospace",
        styles.getPtr("font-family").?.get().*,
    );

    const child = &root.element.children.items[1].element;
    try std.testing.expectEqualStrings("italic", child.style.?.getPtr("font-style").?.get().*);
    try std.testing.expectEqualStrings("bold", child.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("normal", child.style.?.getPtr("line-height").?.get().*);
    try std.testing.expectEqualStrings("24.0px", child.style.?.getPtr("font-size").?.get().*);
    try std.testing.expectEqualStrings(
        "\"Courier New\", monospace",
        child.style.?.getPtr("font-family").?.get().*,
    );
}

test "font shorthand accepts em sizes and resolves them against the parent" {
    const allocator = std.testing.allocator;
    const html = "<div style='font-size: 20px'><span style='font: bold 1.5em sans-serif'>child</span></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try document_parser.style(allocator, &root, &.{});
    const child = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings("bold", child.style.?.getPtr("font-weight").?.get().*);
    try std.testing.expectEqualStrings("30.0px", child.style.?.getPtr("font-size").?.get().*);
}

test "line-height computes lengths and inherits unitless multipliers" {
    const allocator = std.testing.allocator;
    const html = "<div style='font-size: 20px; line-height: 1.5em'><span style='font-size: 10px'>child</span></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try document_parser.style(allocator, &root, &.{});
    const parent = &root.element;
    const child = &parent.children.items[0].element;
    try std.testing.expectEqualStrings("30.0px", parent.style.?.getPtr("line-height").?.get().*);
    try std.testing.expectEqualStrings("30.0px", child.style.?.getPtr("line-height").?.get().*);

    const shorthand_html = "<div style='font: 10px/1 Verdana, sans-serif'><span>child</span></div>";
    var shorthand_parser = try HTMLParser.init(allocator, shorthand_html);
    shorthand_parser.use_implicit_tags = false;
    defer shorthand_parser.deinit(allocator);
    var shorthand_root = try shorthand_parser.parse();
    defer shorthand_root.deinit(allocator);
    try document_parser.style(allocator, &shorthand_root, &.{});
    try std.testing.expectEqualStrings(
        "1",
        shorthand_root.element.style.?.getPtr("line-height").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "1",
        shorthand_root.element.children.items[0].element.style.?.getPtr("line-height").?.get().*,
    );
}

test "width and height are computed without inheriting" {
    const allocator = std.testing.allocator;
    const html = "<div style=\"width: 320px; height: 90px\"><p>child</p></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const rules = &[_]CSSParser.CSSRule{};
    try document_parser.style(allocator, &root, rules);

    try std.testing.expectEqualStrings(
        "320px",
        root.element.style.?.getPtr("width").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "90px",
        root.element.style.?.getPtr("height").?.get().*,
    );

    const child = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings("auto", child.style.?.getPtr("width").?.get().*);
    try std.testing.expectEqualStrings("auto", child.style.?.getPtr("height").?.get().*);
    try std.testing.expectEqualStrings(
        "auto",
        child.children.items[0].text.style.?.getPtr("width").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "auto",
        child.children.items[0].text.style.?.getPtr("height").?.get().*,
    );
}

test "object-fit is computed per element and defaults to fill" {
    const allocator = std.testing.allocator;
    const html = "<div style='object-fit: cover'><img id=child></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const rules = &[_]CSSParser.CSSRule{};
    try document_parser.style(allocator, &root, rules);

    try std.testing.expectEqualStrings(
        "cover",
        root.element.style.?.getPtr("object-fit").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "fill",
        root.element.children.items[0].element.style.?.getPtr("object-fit").?.get().*,
    );
}

test "aspect-ratio is computed per element and defaults to auto" {
    const allocator = std.testing.allocator;
    const html = "<div style='aspect-ratio: 4 / 3'><img id=child></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const rules = &[_]CSSParser.CSSRule{};
    try document_parser.style(allocator, &root, rules);

    try std.testing.expectEqualStrings(
        "4 / 3",
        root.element.style.?.getPtr("aspect-ratio").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "auto",
        root.element.children.items[0].element.style.?.getPtr("aspect-ratio").?.get().*,
    );
}

test "zoom is computed per element without inheriting" {
    const allocator = std.testing.allocator;
    const html = "<div style=\"zoom: 175%\"><p>child</p></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    const rules = &[_]CSSParser.CSSRule{};
    try document_parser.style(allocator, &root, rules);

    try std.testing.expectEqualStrings(
        "175%",
        root.element.style.?.getPtr("zoom").?.get().*,
    );
    const child = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings("1", child.style.?.getPtr("zoom").?.get().*);
    try std.testing.expectEqualStrings(
        "1",
        child.children.items[0].text.style.?.getPtr("zoom").?.get().*,
    );
}

test "computed animation starts typed keyframe tracks without restarting on restyle" {
    const allocator = std.testing.allocator;
    const css =
        "div { animation: 2s infinite alternate demo; width: 220px; }" ++
        "@keyframes demo {" ++
        " from { opacity: 0.2; width: 100px; background-color: red; }" ++
        " to { opacity: 0.8; width: 300px; background-color: blue; }" ++
        "}";

    var html_parser = try HTMLParser.init(allocator, "<div>animated words wrap here</div>");
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, css, false);
    defer css_parser.deinit(allocator);
    var keyframes = std.ArrayList(CSSParser.KeyframesRule).empty;
    defer {
        for (keyframes.items) |*rule| rule.deinit(allocator);
        keyframes.deinit(allocator);
    }
    const rules = try css_parser.parseWithKeyframes(allocator, &keyframes);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.styleWithKeyframes(allocator, &root, rules, keyframes.items);
    try std.testing.expectEqualStrings(
        "2s infinite alternate demo",
        root.element.style.?.getPtr("animation").?.get().*,
    );
    const state = root.element.css_animation.?;
    try std.testing.expect(state.contains("opacity"));
    try std.testing.expect(state.contains("background-color"));
    try std.testing.expect(state.contains("width"));
    try std.testing.expect(!state.contains("height"));
    try std.testing.expectApproxEqAbs(
        @as(f64, 100),
        root.element.animations.?.get("width").?.pixel.getValue(),
        0.000001,
    );

    _ = root.element.animations.?.getPtr("width").?.advance();
    const current_frame = root.element.animations.?.get("width").?.pixel.numeric.current_frame;
    document_parser.dirtyStyleForElement(&root.element);
    try document_parser.styleWithKeyframes(allocator, &root, rules, keyframes.items);
    try std.testing.expectEqual(
        current_frame,
        root.element.animations.?.get("width").?.pixel.numeric.current_frame,
    );

    document_parser.finishCssAnimationTracks(&root.element);
    document_parser.dirtyStyleForElement(&root.element);
    try document_parser.styleWithKeyframes(allocator, &root, rules, keyframes.items);
    try std.testing.expect(root.element.css_animation.?.finished);
    try std.testing.expect(root.element.animations.?.get("width") == null);
}

test "display defaults to inline and browser rules define block elements" {
    const allocator = std.testing.allocator;
    const html =
        "<div><span style=\"display: block\">promoted</span>" ++
        "<p style=\"display: inline\">demoted</p><custom>default</custom></div>";
    const browser_css = @embedFile("../browser/browser.css");

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    var css_parser = try CSSParser.init(allocator, browser_css, false);
    defer css_parser.deinit(allocator);
    const rules = try css_parser.parse(allocator);
    defer {
        for (rules) |*rule| rule.deinit(allocator);
        allocator.free(rules);
    }

    try document_parser.style(allocator, &root, rules);
    try std.testing.expectEqualStrings("block", root.element.style.?.getPtr("display").?.get().*);
    try std.testing.expectEqualStrings(
        "block",
        root.element.children.items[0].element.style.?.getPtr("display").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "inline",
        root.element.children.items[1].element.style.?.getPtr("display").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "inline",
        root.element.children.items[2].element.style.?.getPtr("display").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "inline",
        root.element.children.items[0].element.children.items[0].text.style.?.getPtr("display").?.get().*,
    );
}

test "position and z-index are computed non-inherited properties" {
    const allocator = std.testing.allocator;
    const html =
        "<div style=\"z-index: 99\">" ++
        "<span style=\"position: relative; z-index: -4\">nested</span>" ++
        "<p>default</p></div>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try document_parser.style(allocator, &root, &.{});
    const positioned = &root.element.children.items[0].element;
    const defaulted = &root.element.children.items[1].element;

    try std.testing.expectEqualStrings("static", root.element.style.?.getPtr("position").?.get().*);
    try std.testing.expectEqualStrings("99", root.element.style.?.getPtr("z-index").?.get().*);
    try std.testing.expectEqualStrings("relative", positioned.style.?.getPtr("position").?.get().*);
    try std.testing.expectEqualStrings("-4", positioned.style.?.getPtr("z-index").?.get().*);
    try std.testing.expectEqualStrings("static", defaulted.style.?.getPtr("position").?.get().*);
    try std.testing.expectEqualStrings("0", defaulted.style.?.getPtr("z-index").?.get().*);
    try std.testing.expectEqualStrings(
        "0",
        positioned.children.items[0].text.style.?.getPtr("z-index").?.get().*,
    );
}

test "scroll behavior is computed and does not inherit" {
    const allocator = std.testing.allocator;
    const html =
        "<body style=\"scroll-behavior: smooth\">" ++
        "<main><p>content</p></main></body>";

    var html_parser = try HTMLParser.init(allocator, html);
    html_parser.use_implicit_tags = false;
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);

    try document_parser.style(allocator, &root, &.{});
    const main = &root.element.children.items[0].element;
    try std.testing.expectEqualStrings(
        "smooth",
        root.element.style.?.getPtr("scroll-behavior").?.get().*,
    );
    try std.testing.expectEqualStrings(
        "auto",
        main.style.?.getPtr("scroll-behavior").?.get().*,
    );
}

test "nested button start tags implicitly close the outer button" {
    const allocator = std.testing.allocator;
    const html =
        "<button id=outer>Outer <div>descendant " ++
        "<button id=inner>Inner</button> tail</div></button>";

    var html_parser = try HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*document_parser.Node).empty;
    defer nodes.deinit(allocator);
    try document_parser.treeToList(allocator, &root, &nodes);

    var buttons = std.ArrayList(*document_parser.Node).empty;
    defer buttons.deinit(allocator);
    for (nodes.items) |node| {
        if (node.* == .element and std.ascii.eqlIgnoreCase(node.element.tag, "button")) {
            try buttons.append(allocator, node);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), buttons.items.len);
    try std.testing.expect(buttons.items[0].element.parent == buttons.items[1].element.parent);
    try std.testing.expect(buttons.items[1].element.parent != buttons.items[0]);
}

test "button keeps non-button element descendants in its DOM subtree" {
    const allocator = std.testing.allocator;
    const html =
        "<button><span>label</span><div>block</div>" ++
        "<input value=editable><a href=/target>link</a></button>";

    var html_parser = try HTMLParser.init(allocator, html);
    defer html_parser.deinit(allocator);
    var root = try html_parser.parse();
    defer root.deinit(allocator);
    document_parser.fixParentPointers(&root, null);

    var nodes = std.ArrayList(*document_parser.Node).empty;
    defer nodes.deinit(allocator);
    try document_parser.treeToList(allocator, &root, &nodes);

    var button: ?*document_parser.Node = null;
    var input: ?*document_parser.Node = null;
    var anchor: ?*document_parser.Node = null;
    for (nodes.items) |node| {
        if (node.* != .element) continue;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "button")) button = node;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "input")) input = node;
        if (std.ascii.eqlIgnoreCase(node.element.tag, "a")) anchor = node;
    }

    try std.testing.expect(button != null and input != null and anchor != null);
    try std.testing.expect(input.?.element.parent != null);
    try std.testing.expect(anchor.?.element.parent != null);
    try std.testing.expect(input.?.element.parent.? == button.?);
    try std.testing.expect(anchor.?.element.parent.? == button.?);
}
