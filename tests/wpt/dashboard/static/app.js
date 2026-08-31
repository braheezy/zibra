// The dashboard keeps its client state small: the server owns reports, while
// this module renders the selected report and the local history.
const state = {
  runs: [], selected: null, selectedId: null, status: "ALL",
  pathQuery: "", testQuery: "",
};
const $ = (id) => document.getElementById(id);
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[char]));
const summary = (run) => run?.summary || {};
const semanticTotal = (value) => (value.pass || 0) + (value.fail || 0) +
  (value.error || 0) + (value.timeout || 0);
const passRate = (value) => {
  const total = semanticTotal(value);
  return total ? Math.round((value.pass || 0) * 100 / total) : null;
};
function dateText(value) {
  if (!value) return "unknown time";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString([], {
    dateStyle: "medium", timeStyle: "short",
  });
}
function shortDate(value) {
  if (!value) return "—";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value).slice(0, 10) :
    date.toLocaleDateString([], { month: "short", year: "numeric" });
}
function scoreClass(passed, total) {
  return !total ? "empty" : passed === total ? "pass" : passed ? "partial" : "fail";
}
function score(passed, total) {
  return `<span class="score ${scoreClass(passed, total)}">${passed}/${total}</span>`;
}
function currentRun() {
  return state.runs.find((run) => run.id === state.selectedId) || state.runs[0] || null;
}
function renderRunSelect() {
  const select = $("run-select");
  select.innerHTML = state.runs.length ? state.runs.map((run) => {
    const label = `${dateText(run.finished_at)} · ${run.browser_revision || "working-tree"}`;
    return `<option value="${esc(run.id)}">${esc(label)}</option>`;
  }).join("") : '<option value="">No reports</option>';
  if (state.selectedId) select.value = state.selectedId;
}
function renderChart() {
  const runs = state.runs.slice(0, 24).reverse();
  const line = $("history-line");
  const points = $("history-points");
  const dates = $("history-dates");
  const empty = $("chart-empty");
  if (!runs.length) {
    line.setAttribute("points", ""); points.innerHTML = ""; dates.innerHTML = "";
    empty.hidden = false; return;
  }
  empty.hidden = true;
  const left = 65, right = 865;
  const step = runs.length === 1 ? 0 : (right - left) / (runs.length - 1);
  const plotted = runs.map((run, index) => {
    const rate = passRate(summary(run));
    const x = runs.length === 1 ? (left + right) / 2 : left + step * index;
    return { run, x, y: rate == null ? 265 : 265 - rate * 2.4, rate };
  });
  line.setAttribute("points", plotted.map(({ x, y }) => `${x},${y}`).join(" "));
  points.innerHTML = plotted.map(({ run, x, y, rate }) => `<circle cx="${x}" cy="${y}" r="4" tabindex="0" data-run="${esc(run.id)}" aria-label="${esc(run.run_id || run.id)}: ${rate == null ? "no semantic results" : `${rate}% passing`}"></circle>`).join("");
  dates.innerHTML = plotted.map(({ run, x }) => `<text x="${x}" y="283">${esc(shortDate(run.finished_at))}</text>`).join("");
  points.querySelectorAll("[data-run]").forEach((point) => {
    point.addEventListener("click", () => showDetails(point.dataset.run));
    point.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") showDetails(point.dataset.run);
    });
  });
}
function pathGroup(path) {
  return String(path || "").split("/").filter(Boolean)[0] || "unknown";
}
function reportTests(report) {
  return Array.isArray(report?.tests) ? report.tests : [];
}
function renderCoverage(report) {
  const tests = reportTests(report), query = state.pathQuery.trim().toLowerCase();
  const groups = new Map();
  tests.forEach((test) => {
    const path = String(test.path || "");
    if (query && !path.toLowerCase().includes(query)) return;
    const group = pathGroup(path);
    if (!groups.has(group)) groups.set(group, { tests: [], passed: 0 });
    const item = groups.get(group);
    item.tests.push(test); item.passed += test.status === "PASS" ? 1 : 0;
  });
  const revision = report?.browser_revision || currentRun()?.browser_revision || "working-tree";
  $("browser-column").innerHTML = `<span class="browser-head">Zibra</span><span class="browser-sha">${esc(revision.slice(0, 12))}</span><span class="browser-date">${esc(dateText(report?.finished_at || currentRun()?.finished_at))}</span>`;
  const entries = [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));
  if (!entries.length) {
    $("coverage-table").innerHTML = `<tr><td colspan="2" class="empty">${tests.length ? "No test paths match the search." : "No test records in this run."}</td></tr>`;
    return;
  }
  const rows = [];
  entries.forEach(([group, item]) => {
    rows.push(`<tr class="path-group"><td>${esc(group)}/<span class="path-meta">${item.tests.length} test${item.tests.length === 1 ? "" : "s"}</span></td><td>${score(item.passed, item.tests.length)}</td></tr>`);
    item.tests.sort((a, b) => String(a.path).localeCompare(String(b.path))).forEach((test) => {
      const path = String(test.path || ""), relative = path.startsWith(`${group}/`) ? path.slice(group.length + 1) : path;
      const subtests = Array.isArray(test.tests) ? test.tests : [], passed = subtests.filter((item) => item.status === "PASS").length;
      rows.push(`<tr class="path-test"><td><a href="#details" data-test-path="${esc(path)}">${esc(relative)}</a></td><td>${score(test.status === "PASS" ? 1 : 0, 1)}${subtests.length ? `<span class="path-meta">${passed}/${subtests.length} subtests</span>` : ""}</td></tr>`);
    });
  });
  $("coverage-table").innerHTML = rows.join("");
  $("coverage-table").querySelectorAll("[data-test-path]").forEach((link) => link.addEventListener("click", () => {
    state.testQuery = link.dataset.testPath; $("test-search").value = state.testQuery;
    renderTests(report); $("details-panel")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }));
}
function diagnosticDetails(test) {
  const pieces = [];
  if (test.message) pieces.push(`Message\n${test.message}`);
  if (test.infrastructure_error) pieces.push(`Infrastructure\n${test.infrastructure_error}`);
  if (test.exception) pieces.push(`Exception\n${JSON.stringify(test.exception, null, 2)}`);
  if (test.stderr) pieces.push(`stderr\n${test.stderr}`);
  if (test.stdout) pieces.push(`stdout\n${test.stdout}`);
  if (test.console?.length) pieces.push(`Console\n${JSON.stringify(test.console, null, 2)}`);
  return pieces.length ? `<details><summary>Show diagnostics</summary><pre>${esc(pieces.join("\n\n"))}</pre></details>` : "";
}
function renderTests(report) {
  const tests = reportTests(report), query = state.testQuery.trim().toLowerCase();
  const rows = tests.filter((test) => {
    const status = String(test.status || "").toUpperCase();
    return (state.status === "ALL" || status === state.status) && (!query || `${test.path} ${test.message || ""} ${test.infrastructure_error || ""}`.toLowerCase().includes(query));
  });
  $("test-table").innerHTML = rows.length ? rows.map((test) => {
    const subtests = Array.isArray(test.tests) ? test.tests : [], passed = subtests.filter((item) => item.status === "PASS").length;
    const status = String(test.status || "UNKNOWN").toUpperCase();
    return `<tr class="result-${esc(status.toLowerCase())}"><td>${esc(test.path)}${diagnosticDetails(test)}</td><td><span class="status status-${esc(status)}">${esc(status)}</span></td><td>${esc(test.expected || "—")}</td><td>${subtests.length ? `<span class="subtests"><strong>${passed}/${subtests.length}</strong> passed</span>` : "—"}</td><td>${test.duration_ms == null ? "—" : `${esc(test.duration_ms)} ms`}</td></tr>`;
  }).join("") : `<tr><td colspan="5" class="empty">${tests.length ? "No tests match these filters." : "No run selected."}</td></tr>`;
}
function renderDetails(report) {
  const run = currentRun(), tests = reportTests(report);
  const subtests = tests.reduce((total, test) => total + (Array.isArray(test.tests) ? test.tests.length : 0), 0);
  const revision = report?.browser_revision || run?.browser_revision || "working-tree";
  const runLabel = run?.id === state.runs[0]?.id ? "latest local test run" : "selected local test run";
  $("last-update").textContent = revision.slice(0, 12);
  $("results-description").textContent = run ? `Showing ${tests.length} ${tests.length === 1 ? "test" : "tests"} (${subtests} ${subtests === 1 ? "subtest" : "subtests"}) from the ${runLabel} for zibra[${revision}]` : "No results selected.";
  $("details-title").textContent = run ? `${tests.length} ${tests.length === 1 ? "test" : "tests"} in this run` : "Test details";
  $("details-note").textContent = run ? `${dateText(report?.finished_at || run.finished_at)} · ${run.mode || "unknown mode"} · revision ${revision}` : "Select a path above to inspect its test cases.";
  renderCoverage(report); renderTests(report);
}
async function showDetails(id) {
  if (!id) return;
  const response = await fetch(`/api/runs/${encodeURIComponent(id)}.json`, { cache: "no-store" });
  if (!response.ok) return;
  state.selectedId = id; state.selected = await response.json();
  renderRunSelect(); renderDetails(state.selected);
}
async function load() {
  try {
    const [runsResponse, infoResponse] = await Promise.all([fetch("/api/runs", { cache: "no-store" }), fetch("/api/info", { cache: "no-store" })]);
    if (!runsResponse.ok || !infoResponse.ok) throw new Error("dashboard API unavailable");
    const runs = await runsResponse.json(), info = await infoResponse.json();
    state.runs = Array.isArray(runs.runs) ? runs.runs : [];
    $("health").textContent = `${info.run_count || 0} local report${info.run_count === 1 ? "" : "s"}`;
    renderRunSelect(); renderChart();
    const selected = state.selectedId && state.runs.some((run) => run.id === state.selectedId) ? state.selectedId : state.runs[0]?.id;
    if (selected) await showDetails(selected); else renderDetails(null);
  } catch (error) {
    $("health").textContent = "Unable to load"; $("results-description").textContent = error.message;
    $("coverage-table").innerHTML = `<tr><td colspan="2" class="empty">${esc(error.message)}</td></tr>`;
  }
}
$("run-select").addEventListener("change", (event) => showDetails(event.target.value));
$("status-filter").addEventListener("change", (event) => { state.status = event.target.value; if (state.selected) renderTests(state.selected); });
$("test-search").addEventListener("input", (event) => { state.testQuery = event.target.value; if (state.selected) renderTests(state.selected); });
$("path-search").addEventListener("input", (event) => { state.pathQuery = event.target.value; if (state.selected) renderCoverage(state.selected); });
$("refresh").addEventListener("click", load);
$("about-link").addEventListener("click", () => document.querySelector(".side-help")?.scrollIntoView({ behavior: "smooth", block: "center" }));
load();
