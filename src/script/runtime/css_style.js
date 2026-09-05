// Realm-local live inline-style view. The DOM attribute remains authoritative;
// all mutations use the wrapper's attribute setter/invalidation boundary.
function cssPropertyName(name) {
  name = String(name);
  return name.slice(0, 2) === '--' ? name : name.toLowerCase();
}

function inlineStyleDeclarations(source) {
  var declarations = [], start = 0, colon = -1, bang = -1, depth = 0, quote = '', comment = false;
  function push(end) {
    if (colon >= start) {
      var name = source.slice(start, colon).replace(/\/\*[\s\S]*?\*\//g, ' ').trim();
      var value = source.slice(colon + 1, end).trim();
      var important = bang > colon && /^!\s*important\s*$/i.test(source.slice(bang, end));
      if (important) value = source.slice(colon + 1, bang).trim();
      if (name) declarations.push({ name: cssPropertyName(name), value: value, priority: important ? 'important' : '' });
    }
    start = end + 1; colon = -1; bang = -1;
  }
  for (var i = 0; i < source.length; i++) {
    var c = source.charAt(i), next = source.charAt(i + 1);
    if (comment) { if (c === '*' && next === '/') { comment = false; i++; } continue; }
    if (c === '\\') { i++; continue; }
    if (quote) { if (c === quote) quote = ''; continue; }
    if (c === '/' && next === '*') { comment = true; i++; continue; }
    if (c === '"' || c === "'") { quote = c; continue; }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth = Math.max(0, depth - 1);
    else if (depth === 0 && c === ':' && colon < 0) colon = i;
    else if (depth === 0 && c === '!') bang = i;
    else if (depth === 0 && c === ';') push(i);
  }
  push(source.length);
  return declarations;
}

function createInlineStyleDeclaration(owner) {
  var style = {};
  function declarations() { return inlineStyleDeclarations(owner.getAttribute('style') || ''); }
  function selected(name) {
    name = cssPropertyName(name);
    var all = declarations(), result = null;
    for (var i = 0; i < all.length; i++) {
      if (all[i].name === name && (!result || result.priority !== 'important' || all[i].priority === 'important')) result = all[i];
    }
    return result;
  }
  function write(all) {
    var source = '';
    for (var i = 0; i < all.length; i++) source += all[i].name + ': ' + all[i].value + (all[i].priority ? ' !important' : '') + '; ';
    owner.setAttribute('style', source.trim());
  }
  Object.defineProperty(style, 'cssText', {
    get: function() { return owner.getAttribute('style') || ''; },
    set: function(value) { owner.setAttribute('style', value == null ? '' : String(value)); },
    enumerable: true
  });
  Object.defineProperty(style, 'length', { get: function() { return declarations().length; } });
  style.item = function(index) { var entry = declarations()[index]; return entry ? entry.name : ''; };
  style.getPropertyValue = function(name) { var entry = selected(name); return entry ? entry.value : ''; };
  style.getPropertyPriority = function(name) { var entry = selected(name); return entry ? entry.priority : ''; };
  style.removeProperty = function(name) {
    name = cssPropertyName(name);
    var previous = style.getPropertyValue(name), all = declarations();
    write(all.filter(function(entry) { return entry.name !== name; }));
    return previous;
  };
  style.setProperty = function(name, value, priority) {
    name = cssPropertyName(name);
    value = value == null ? '' : String(value);
    priority = priority == null ? '' : String(priority).toLowerCase();
    if (!name || /[\s:;]/.test(name)) return;
    if (value === '') { style.removeProperty(name); return; }
    if (priority !== '' && priority !== 'important') return;
    var all = declarations().filter(function(entry) { return entry.name !== name; });
    all.push({ name: name, value: value, priority: priority });
    write(all);
  };
  var properties = ['color', 'backgroundColor', 'background', 'display', 'font', 'fontSize', 'fontFamily',
    'fontWeight', 'fontStyle', 'lineHeight', 'width', 'height', 'minWidth', 'maxWidth', 'minHeight', 'maxHeight',
    'margin', 'marginTop', 'marginRight', 'marginBottom', 'marginLeft', 'padding', 'paddingTop', 'paddingRight',
    'paddingBottom', 'paddingLeft', 'border', 'boxSizing', 'position', 'top', 'right', 'bottom', 'left',
    'opacity', 'visibility', 'overflow', 'transform', 'flex', 'flexBasis', 'flexGrow', 'flexShrink',
    'flexDirection', 'flexWrap', 'gap', 'rowGap', 'columnGap', 'alignItems', 'justifyContent',
    'gridTemplateColumns', 'gridTemplateRows', 'cssFloat'];
  for (var i = 0; i < properties.length; i++) {
    (function(property) {
      var name = property === 'cssFloat' ? 'float' : property.replace(/[A-Z]/g, function(c) { return '-' + c.toLowerCase(); });
      Object.defineProperty(style, property, {
        get: function() { return style.getPropertyValue(name); },
        set: function(value) { style.setProperty(name, value); }, enumerable: true
      });
    })(properties[i]);
  }
  return style;
}
