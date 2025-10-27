# DOM API Implementation with Handles

This document describes the implementation of DOM API support in the Zibra browser, following the pattern from the Web Browser Engineering book's Chapter 9.

## Overview

The implementation allows JavaScript code running in the browser to interact with the DOM through a handle-based system. Handles are numeric identifiers that indirectly reference DOM nodes, allowing JavaScript to manipulate the page without direct access to Zig's internal data structures.

## Architecture

### Handle Management System

The handle system is implemented in `src/js.zig` with the following components:

1. **Handle Mappings**: Two hash maps maintain bidirectional mappings between Node pointers and numeric handles:
   - `node_to_handle`: Maps `*Node` → `u32`
   - `handle_to_node`: Maps `u32` → `*Node`

2. **Handle Allocation**: Handles are allocated sequentially starting from 0, ensuring each node gets a unique identifier.

3. **Lifecycle Management**: Handle mappings are cleared when the page changes (via `setNodes()`), ensuring handles don't outlive their corresponding nodes.

### Native Functions

Three native functions are exposed to JavaScript:

#### 1. `document.querySelectorAll(selector)`

**Native Implementation**: `querySelectorAll()` in `src/js.zig`
- Parses the CSS selector using the existing `CSSParser`
- Traverses the DOM tree to find matching nodes
- Returns an array of numeric handles

**JavaScript Wrapper**: Automatically wraps handles in `Node` objects

```javascript
var paragraphs = document.querySelectorAll("p");
// Returns: [Node(0), Node(1), Node(2), ...]
```

#### 2. `Node.prototype.getAttribute(name)`

**Native Implementation**: `__native.getAttribute(handle, name)` in `src/js.zig`
- Takes a handle and attribute name
- Looks up the node from the handle
- Returns the attribute value or null

**JavaScript Wrapper**: Calls native function with the node's handle

```javascript
var className = node.getAttribute("class");
```

#### 3. `Node.prototype.innerHTML(html)`

**Native Implementation**: `__native.innerHTML(handle, html)` in `src/js.zig`
- Takes a handle and HTML string
- Parses the HTML using the existing `HTMLParser`
- Replaces the node's children with the parsed content

**JavaScript Wrapper**: Calls native function with the node's handle

```javascript
node.innerHTML("<p>New content</p>");
```

### JavaScript Runtime Layer

The JavaScript runtime code is automatically injected when scripts are evaluated. It provides:

1. **Node Constructor**: Creates objects that wrap handles
```javascript
function Node(handle) {
  this.handle = handle;
}
```

2. **Method Wrappers**: Bridge between JavaScript method calls and native functions
```javascript
Node.prototype.getAttribute = function(name) {
  return __native.getAttribute(this.handle, name);
};
```

3. **querySelectorAll Wrapper**: Converts handle arrays to Node objects
```javascript
document.querySelectorAll = function(selector) {
  var handles = originalQuerySelectorAll.call(this, selector);
  return handles.map(function(h) { return new Node(h); });
};
```

## Integration with Browser

### Initialization

1. Browser creates the JavaScript engine during initialization (`Browser.init()`)
2. The global JS instance is set via `setGlobalInstance()` for callback access
3. The `document` object and `__native` methods are set up in `setupDocument()`

### Page Loading

When a page is loaded (`Browser.loadInTab()`):
1. HTML is parsed into a node tree
2. The JS engine is updated with the current nodes via `setNodes()`
3. Scripts are loaded and executed
4. The runtime code is injected on first script evaluation

### Script Execution

When JavaScript code is evaluated:
1. Runtime code is checked and injected if needed (only once per page)
2. User's script is parsed and executed
3. DOM API calls flow through the handle system

## Example Usage

```html
<!DOCTYPE html>
<html>
<body>
    <p class="text">First paragraph</p>
    <p class="text">Second paragraph</p>
    <div id="output"></div>

    <script>
        // Find all paragraphs
        var paragraphs = document.querySelectorAll("p");
        console.log("Found " + paragraphs.length + " paragraphs");

        // Get attributes
        for (var i = 0; i < paragraphs.length; i++) {
            var className = paragraphs[i].getAttribute("class");
            console.log("Paragraph " + i + " has class: " + className);
        }

        // Modify content
        var output = document.querySelectorAll("#output");
        if (output.length > 0) {
            output[0].innerHTML("<p>Added by JavaScript!</p>");
        }
    </script>
</body>
</html>
```

## Key Design Decisions

### 1. Handle-Based Indirection

**Why**: Prevents JavaScript from directly accessing Zig memory structures, providing a clean separation between the JS engine and browser internals.

**Trade-off**: Adds a lookup step for every DOM operation, but this is negligible compared to parsing/rendering costs.

### 2. Global Instance Pattern

**Why**: Kiesel's builtin function system doesn't provide a way to pass user data to callbacks.

**Solution**: Use a global variable to store the JS instance pointer, allowing native functions to access handle mappings.

**Limitation**: Only one JS instance can be active at a time (acceptable for a single-window browser).

### 3. Runtime Code Injection

**Why**: Provides a clean JavaScript API while keeping native functions simple.

**Benefit**: Native functions only deal with handles and primitive types, while JavaScript code handles object creation and method dispatch.

### 4. Automatic Node Wrapping

**Why**: Makes the API more ergonomic - developers work with Node objects, not raw handles.

**Implementation**: The `querySelectorAll` wrapper automatically maps handles to Node objects using the `Node` constructor.

## Differences from Python/DukPy Implementation

1. **No JSON Serialization**: Handles are passed as numbers directly, not serialized/deserialized
2. **Explicit Runtime Injection**: JavaScript wrapper code is explicitly injected rather than being part of the engine
3. **Separate Native Namespace**: Native functions live in `__native` rather than being directly callable
4. **Static Global Instance**: Uses a global variable instead of DukPy's context passing

## Testing

Test files are provided:
- `test_dom.html` / `test_dom.js`: Comprehensive test of all DOM API features
- `test_dom_simple.html` / `test_dom_simple.js`: Basic functionality test

Run with:
```bash
./zig-out/bin/zibra file://$(pwd)/test_dom_simple.html
```

## Future Enhancements

Potential improvements for the DOM API:

1. **More DOM Methods**: Add `getElementById`, `getElementsByClassName`, `createElement`, etc.
2. **Event Listeners**: Implement `addEventListener` for interactive pages
3. **Property Access**: Support reading `innerHTML` (currently write-only)
4. **Node Manipulation**: Add `appendChild`, `removeChild`, etc.
5. **Better Error Messages**: Include more context in error messages
6. **Memory Management**: Implement handle cleanup when nodes are removed from the DOM

## Files Modified

- `src/js.zig`: Core DOM API implementation with handle management
- `src/browser.zig`: Integration with page loading and JS engine initialization
- `test_dom.html`, `test_dom.js`: Comprehensive test page
- `test_dom_simple.html`, `test_dom_simple.js`: Simple test page

## Conclusion

This implementation provides a solid foundation for JavaScript-DOM interaction in the Zibra browser. The handle-based system cleanly separates JavaScript from Zig internals while providing a familiar DOM API to web developers.
