// Exercise the shipped frontend and its event handlers without an HTTP server.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "static/app.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "static/index.html"), "utf8");

function frontend() {
  const elements = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      innerHTML: "", listeners: {}, classList: { toggle() {} },
      addEventListener(type, listener) { this.listeners[type] = listener; },
    });
    return elements.get(id);
  }
  const context = vm.createContext({
    document: { getElementById: element },
    // Keep the initial network load pending; tests supply reports directly.
    // An unresolved promise has no timer or process to clean up.
    fetch: () => new Promise(() => {}),
  });
  vm.runInContext(source, context);
  const app = vm.runInContext("({ state, sortDirectories, selectRun })", context);
  return { ...app, element };
}

const directories = [
  { path: "console/", passed: 9, total: 9 },
  { path: "dom/", passed: 2, total: 12000 },
  { path: "svg/", passed: 100, total: 100 },
  { path: "css/", passed: 0, total: 100 },
  { path: "empty/", passed: 0, total: 0 },
];

test("count sorting is numeric, deterministic, and leaves report order intact", () => {
  const app = frontend();
  const input = directories.map((entry) => Object.freeze({ ...entry, total: String(entry.total) }));
  input.push(Object.freeze({ path: "missing/" }));
  Object.freeze(input);
  for (const [order, expected] of [
    ["total-desc", ["dom/", "css/", "svg/", "console/", "empty/", "missing/"]],
    ["total-asc", ["empty/", "missing/", "console/", "css/", "svg/", "dom/"]],
  ]) {
    app.state.directorySort = order;
    assert.deepEqual(Array.from(app.sortDirectories(input), (entry) => entry.path), expected);
  }
  assert.equal(input[0].path, "console/");
  assert.deepEqual(Array.from(app.sortDirectories([])), []);
});

test("existing default, percentage, and path sorts are preserved", () => {
  const app = frontend();
  assert.equal(app.state.directorySort, "pass-desc");
  for (const [order, expected] of [
    ["pass-desc", ["console/", "svg/", "dom/", "css/", "empty/"]],
    ["pass-asc", ["empty/", "css/", "dom/", "console/", "svg/"]],
    ["path", ["console/", "css/", "dom/", "empty/", "svg/"]],
  ]) {
    app.state.directorySort = order;
    assert.deepEqual(Array.from(app.sortDirectories(directories), (entry) => entry.path), expected);
  }
});

test("sort menu rerenders rows and keeps count sorting across searches and run changes", () => {
  for (const order of ["total-desc", "total-asc"]) {
    assert.ok(html.includes(`<option value="${order}">Assertion count`));
  }
  const app = frontend();
  app.state.runs = [
    { id: "first", directories },
    { id: "second", directories: [
      { path: "console/", passed: 0, total: 15000 },
      { path: "dom/", passed: 0, total: 5000 },
    ] },
  ];
  const rows = () => Array.from(
    app.element("coverage-table").innerHTML.matchAll(/<tr><td>([^<]+)/g),
    (match) => match[1],
  );
  app.selectRun("first");
  app.element("directory-sort").listeners.change({ target: { value: "total-desc" } });
  assert.deepEqual(rows(), ["dom/", "css/", "svg/", "console/", "empty/"]);
  app.element("path-search").listeners.input({ target: { value: "  O  " } });
  assert.deepEqual(rows(), ["dom/", "console/"]);
  app.element("run-select").listeners.change({ target: { value: "second" } });
  assert.deepEqual(rows(), ["console/", "dom/"]);
  app.element("directory-sort").listeners.change({ target: { value: "total-asc" } });
  assert.deepEqual(rows(), ["dom/", "console/"]);
  app.element("path-search").listeners.input({ target: { value: "no matching suite" } });
  assert.match(app.element("coverage-table").innerHTML, /No directories match/);
});
