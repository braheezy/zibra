const std = @import("std");

const kiesel = @import("kiesel");
const Agent = kiesel.execution.Agent;
const Script = kiesel.language.Script;
const Realm = kiesel.execution.Realm;
const Value = kiesel.types.Value;
const parser = @import("parser.zig");
const Node = parser.Node;
const CSSParser = @import("cssParser.zig").CSSParser;
const Selector = @import("selector.zig").Selector;

const Js = @This();

platform: Agent.Platform,
agent: Agent,
realm: *Realm,
allocator: std.mem.Allocator,
// Handle management for DOM nodes
node_to_handle: std.AutoHashMap(*Node, u32),
handle_to_node: std.AutoHashMap(u32, *Node),
next_handle: u32,
// Reference to the current tab's nodes (borrowed, not owned)
current_nodes: ?*Node,

pub fn init(allocator: std.mem.Allocator) !*Js {
    const self = try allocator.create(Js);
    errdefer allocator.destroy(self);

    // Initialize platform first
    self.platform = Agent.Platform.default();

    // Then initialize agent with a pointer to the platform that's now in the struct
    self.agent = try Agent.init(&self.platform, .{});
    errdefer self.agent.deinit();

    // Initialize the realm
    try Realm.initializeHostDefinedRealm(&self.agent, .{});

    // Get the current realm
    self.realm = self.agent.currentRealm();

    // Initialize handle management
    self.allocator = allocator;
    self.node_to_handle = std.AutoHashMap(*Node, u32).init(allocator);
    self.handle_to_node = std.AutoHashMap(u32, *Node).init(allocator);
    self.next_handle = 0;
    self.current_nodes = null;

    // Set up console.log
    try self.setupConsole();

    // Set up document object with DOM API
    try self.setupDocument();

    return self;
}

/// Set up the console object with log function
fn setupConsole(self: *Js) !void {
    const builtins = kiesel.builtins;
    const PropertyKey = kiesel.types.PropertyKey;

    // Create console object
    const console_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Add log function to console
    try console_obj.defineBuiltinFunction(
        &self.agent,
        "log",
        consoleLog,
        1,
        self.realm,
    );

    // Add console to global object
    try self.realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("console"),
        .{
            .value_or_accessor = .{ .value = Value.from(console_obj) },
            .attributes = .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            },
        },
    );
}

/// console.log implementation
fn consoleLog(agent: *Agent, _: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    _ = agent;

    // Print each argument
    var i: usize = 0;
    while (i < arguments.count()) : (i += 1) {
        const arg = arguments.get(i);

        // Format the value to a buffer
        var buf: [4096]u8 = undefined;
        const formatted = formatValue(arg, &buf) catch |err| {
            // If formatting fails, print an error message
            std.debug.print("(error formatting value: {})", .{err});
            if (i < arguments.count() - 1) {
                std.debug.print(" ", .{});
            }
            continue;
        };

        // Print to stdout
        std.debug.print("{s}", .{formatted});

        // Add space between arguments
        if (i < arguments.count() - 1) {
            std.debug.print(" ", .{});
        }
    }
    std.debug.print("\n", .{});

    return .undefined;
}

pub fn deinit(self: *Js, allocator: std.mem.Allocator) void {
    self.node_to_handle.deinit();
    self.handle_to_node.deinit();
    self.platform.deinit();
    self.agent.deinit();
    allocator.destroy(self);
}

pub fn evaluate(self: *Js, code: []const u8) !Value {
    // Inject runtime code to wrap handles in Node objects
    const runtime_code =
        \\// Node constructor that wraps a handle
        \\function Node(handle) {
        \\  this.handle = handle;
        \\}
        \\
        \\// Add getAttribute method to Node prototype
        \\Node.prototype.getAttribute = function(name) {
        \\  return __native.getAttribute(this.handle, name);
        \\};
        \\
        \\// Add innerHTML method to Node prototype
        \\Node.prototype.innerHTML = function(html) {
        \\  return __native.innerHTML(this.handle, html);
        \\};
        \\
        \\// Wrap document.querySelectorAll to return Node objects
        \\(function() {
        \\  var originalQuerySelectorAll = document.querySelectorAll;
        \\  document.querySelectorAll = function(selector) {
        \\    var handles = originalQuerySelectorAll.call(this, selector);
        \\    return handles.map(function(h) { return new Node(h); });
        \\  };
        \\})();
    ;

    // First evaluate the runtime code if this is the first evaluation
    // We check if Node is already defined to avoid re-injecting
    const check_script = try Script.parse(
        "typeof Node !== 'undefined'",
        self.realm,
        null,
        .{},
    );
    const is_defined = try check_script.evaluate();

    if (!is_defined.toBoolean()) {
        const runtime_script = try Script.parse(
            runtime_code,
            self.realm,
            null,
            .{},
        );
        _ = try runtime_script.evaluate();
    }

    // Now evaluate the user's code
    const script = try Script.parse(
        code,
        self.realm,
        null,
        .{},
    );
    const result = try script.evaluate();
    return result;
}

/// Format a JavaScript value to a string buffer
/// Returns a slice of the provided buffer containing the formatted value
pub fn formatValue(value: Value, buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const w: *std.Io.Writer = &writer;

    try value.format(w);

    return buf[0..writer.end];
}

/// Set the current nodes for DOM operations
pub fn setNodes(self: *Js, nodes: ?*Node) void {
    self.current_nodes = nodes;
    // Clear handle mappings when nodes change
    self.node_to_handle.clearRetainingCapacity();
    self.handle_to_node.clearRetainingCapacity();
    self.next_handle = 0;
}

/// Get or create a handle for a node
fn getHandle(self: *Js, node: *Node) !u32 {
    if (self.node_to_handle.get(node)) |handle| {
        return handle;
    }

    const handle = self.next_handle;
    self.next_handle += 1;

    try self.node_to_handle.put(node, handle);
    try self.handle_to_node.put(handle, node);

    return handle;
}

/// Get a node from a handle
fn getNode(self: *Js, handle: u32) ?*Node {
    return self.handle_to_node.get(handle);
}

/// Set up the document object with DOM API
fn setupDocument(self: *Js) !void {
    const builtins = kiesel.builtins;
    const PropertyKey = kiesel.types.PropertyKey;
    const SafePointer = kiesel.types.SafePointer;

    // Store self pointer in a SafePointer for passing to builtin functions
    const self_ptr = SafePointer.make(*Js, self);

    // Create document object
    const document_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Create querySelectorAll function with self pointer
    const query_selector_all_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = querySelectorAll },
        1,
        "querySelectorAll",
        .{
            .realm = self.realm,
            .additional_fields = self_ptr,
        },
    );

    // Add querySelectorAll to document
    try document_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("querySelectorAll"),
        .{
            .value_or_accessor = .{ .value = Value.from(query_selector_all_fn) },
            .attributes = .builtin_default,
        },
    );

    // Add document to global object
    try self.realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("document"),
        .{
            .value_or_accessor = .{ .value = Value.from(document_obj) },
            .attributes = .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            },
        },
    );

    // Create __native object to hold native DOM methods
    const native_obj = try builtins.ordinaryObjectCreate(&self.agent, null);

    // Create getAttribute function with self pointer
    const get_attribute_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = getAttribute },
        2,
        "getAttribute",
        .{
            .realm = self.realm,
            .additional_fields = self_ptr,
        },
    );

    // Add getAttribute to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("getAttribute"),
        .{
            .value_or_accessor = .{ .value = Value.from(get_attribute_fn) },
            .attributes = .builtin_default,
        },
    );

    // Create innerHTML function with self pointer
    const inner_html_fn = try kiesel.builtins.createBuiltinFunction(
        &self.agent,
        .{ .function = innerHTML },
        2,
        "innerHTML",
        .{
            .realm = self.realm,
            .additional_fields = self_ptr,
        },
    );

    // Add innerHTML to __native
    try native_obj.definePropertyDirect(
        &self.agent,
        PropertyKey.from("innerHTML"),
        .{
            .value_or_accessor = .{ .value = Value.from(inner_html_fn) },
            .attributes = .builtin_default,
        },
    );

    // Add __native to global
    try self.realm.global_object.definePropertyDirect(
        &self.agent,
        PropertyKey.from("__native"),
        .{
            .value_or_accessor = .{ .value = Value.from(native_obj) },
            .attributes = .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        },
    );
}

/// document.querySelectorAll implementation
fn querySelectorAll(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    std.log.info("querySelectorAll called", .{});

    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    std.log.info("Got function object", .{});

    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    std.log.info("Cast to builtin function", .{});

    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);
    std.log.info("Got JS instance", .{});

    _ = this_value;

    // Get the selector string argument
    std.log.info("Getting selector argument", .{});
    const selector_arg = arguments.get(0);
    std.log.info("Got selector argument", .{});

    if (!selector_arg.isString()) {
        return agent.throwException(
            .type_error,
            "querySelectorAll requires a string argument",
            .{},
        );
    }
    std.log.info("Selector is a string", .{});

    // Convert the selector to a Zig string
    std.log.info("Converting selector to UTF-8", .{});
    const selector_str = try selector_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(selector_str);
    std.log.info("Selector string: {s}", .{selector_str});

    // Parse the selector
    std.log.info("Initializing CSS parser", .{});
    var css_parser = CSSParser.init(js_instance.allocator, selector_str) catch |err| {
        std.log.err("Failed to init CSS parser: {}", .{err});
        return agent.throwException(
            .syntax_error,
            "Invalid selector",
            .{},
        );
    };
    defer css_parser.deinit(js_instance.allocator);
    std.log.info("CSS parser initialized", .{});

    std.log.info("Parsing selector", .{});
    var selector = css_parser.selector(js_instance.allocator) catch |err| {
        std.log.err("Failed to parse selector: {}", .{err});
        return agent.throwException(
            .syntax_error,
            "Invalid selector",
            .{},
        );
    };
    std.log.info("Selector parsed", .{});

    // Get all nodes from the current tree
    std.log.info("Checking for current_nodes", .{});
    if (js_instance.current_nodes == null) {
        std.log.info("No current nodes, returning empty array", .{});
        // Return empty array if no nodes
        const empty_array = try kiesel.builtins.arrayCreate(agent, 0, null);
        return Value.from(empty_array);
    }
    std.log.info("Have current nodes", .{});

    std.log.info("Creating node list", .{});
    var node_list = std.ArrayList(*Node).empty;
    defer node_list.deinit(js_instance.allocator);
    try parser.treeToList(js_instance.allocator, js_instance.current_nodes.?, &node_list);

    // Find matching nodes
    var matching_handles = std.ArrayList(u32).empty;
    defer matching_handles.deinit(js_instance.allocator);

    for (node_list.items) |node| {
        // Build ancestor chain for this node
        var ancestors = std.ArrayList(*Node).empty;

        var current = node;
        while (true) {
            const parent = switch (current.*) {
                .element => |e| e.parent,
                .text => |t| t.parent,
            };
            if (parent) |p| {
                try ancestors.append(js_instance.allocator, p);
                current = p;
            } else {
                break;
            }
        }

        // Check if this node matches the selector
        const matches = selector.matches(node, ancestors.items);
        if (matches) {
            const handle = try js_instance.getHandle(node);
            try matching_handles.append(js_instance.allocator, handle);
        }

        ancestors.deinit(js_instance.allocator);
    }

    // Clean up selector
    selector.deinit(js_instance.allocator);

    // Create a JavaScript array with the handles
    const result_array = try kiesel.builtins.arrayCreate(agent, @intCast(matching_handles.items.len), null);

    for (matching_handles.items, 0..) |handle, i| {
        const handle_value = Value.from(@as(f64, @floatFromInt(handle)));
        try result_array.createDataPropertyDirect(
            agent,
            kiesel.types.PropertyKey.from(@as(kiesel.types.PropertyKey.IntegerIndex, @intCast(i))),
            handle_value,
        );
    }

    return Value.from(result_array);
}

/// __native.getAttribute implementation
fn getAttribute(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);

    _ = this_value;

    // Get the handle from the first argument
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "getAttribute requires a numeric handle as first argument",
            .{},
        );
    }

    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    // Get the node from the handle
    const node = js_instance.getNode(handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    // Get the attribute name argument (second argument)
    const attr_name_arg = arguments.get(1);
    if (!attr_name_arg.isString()) {
        return agent.throwException(
            .type_error,
            "getAttribute requires a string as second argument",
            .{},
        );
    }

    const attr_name = try attr_name_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(attr_name);

    // Get the attribute value from the node
    switch (node.*) {
        .element => |e| {
            if (e.attributes) |attrs| {
                if (attrs.get(attr_name)) |value| {
                    // Convert the attribute value to a JavaScript string
                    const js_string = try kiesel.types.String.fromUtf8(agent, value);
                    return Value.from(js_string);
                }
            }
            // Return null if attribute not found
            return .null;
        },
        .text => {
            // Text nodes don't have attributes
            return .null;
        },
    }
}

/// __native.innerHTML implementation (setter only)
fn innerHTML(agent: *Agent, this_value: Value, arguments: kiesel.types.Arguments) Agent.Error!Value {
    // Get the Js instance from the function's additional_fields
    const function_obj = agent.activeFunctionObject();
    const builtin_fn = function_obj.as(kiesel.builtins.BuiltinFunction);
    const js_instance = builtin_fn.fields.additional_fields.cast(*Js);

    _ = this_value;

    // Get the handle from the first argument
    const handle_arg = arguments.get(0);
    if (!handle_arg.isNumber()) {
        return agent.throwException(
            .type_error,
            "innerHTML requires a numeric handle as first argument",
            .{},
        );
    }

    const handle: u32 = @intFromFloat(handle_arg.asNumber().asFloat());

    // Get the node from the handle
    const node = js_instance.getNode(handle) orelse return agent.throwException(
        .internal_error,
        "Invalid node handle",
        .{},
    );

    // Get the HTML string argument (second argument)
    const html_arg = arguments.get(1);
    if (!html_arg.isString()) {
        return agent.throwException(
            .type_error,
            "innerHTML requires a string as second argument",
            .{},
        );
    }

    const html_str = try html_arg.asString().toUtf8(js_instance.allocator);
    defer js_instance.allocator.free(html_str);

    // Parse the HTML and replace the node's children
    switch (node.*) {
        .element => |*e| {
            // Clear existing children
            for (e.children.items) |*child| {
                child.deinit(js_instance.allocator);
            }
            e.children.clearRetainingCapacity();

            // Parse the new HTML
            var html_parser = parser.HTMLParser.init(js_instance.allocator, html_str) catch |err| {
                std.log.err("Failed to init HTML parser: {}", .{err});
                return agent.throwException(
                    .syntax_error,
                    "Invalid HTML",
                    .{},
                );
            };
            defer html_parser.deinit(js_instance.allocator);

            const new_node = html_parser.parse() catch |err| {
                std.log.err("Failed to parse HTML: {}", .{err});
                return agent.throwException(
                    .syntax_error,
                    "Invalid HTML",
                    .{},
                );
            };

            // Add the parsed content as children
            switch (new_node) {
                .element => |new_elem| {
                    for (new_elem.children.items) |child| {
                        try e.children.append(js_instance.allocator, child);
                    }
                },
                .text => |new_text| {
                    try e.children.append(js_instance.allocator, Node{ .text = new_text });
                },
            }

            return .undefined;
        },
        .text => {
            // Text nodes can't have innerHTML
            return agent.throwException(
                .type_error,
                "Text nodes do not support innerHTML",
                .{},
            );
        },
    }
}
