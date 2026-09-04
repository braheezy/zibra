// The dashboard keeps its client state small: the server owns reports, while
// this module renders the selected report and the local history.
const state = {
  runs: [], selected: null, selectedId: null, pathQuery: "",
};
const $ = (id) => document.getElementById(id);
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[char]));
const summary = (run) => run?.summary || {};
const semanticTotal = (value) => value.subtests_total != null ? value.subtests_total :
  (value.pass || 0) + (value.fail || 0) + (value.error || 0) + (value.timeout || 0);
const passRate = (value) => {
  const total = semanticTotal(value);
  const passed = value.subtests_total != null ? (value.subtests_pass || 0) : (value.pass || 0);
  return total ? Math.round(passed * 100 / total) : null;
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
  // Keep the timeline comparable: focused runs may contain a tiny or
  // intentionally curated subset and would make a percentage score jump to
  // 100% without representing suite-wide progress.
  const runs = state.runs.filter((run) => run.full_suite && run.complete !== false).slice(0, 24).reverse();
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
    point.addEventListener("click", () => selectRun(point.dataset.run));
    point.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") selectRun(point.dataset.run);
    });
  });
}
function renderCoverage(report) {
  const directories = Array.isArray(report?.directories) ? report.directories : [];
  const query = state.pathQuery.trim().toLowerCase();
  const groups = directories.filter((directory) =>
    !query || String(directory.path || "").toLowerCase().includes(query)
  );
  const revision = report?.browser_revision || currentRun()?.browser_revision || "working-tree";
  $("browser-column").innerHTML = `<span class="browser-head">Zibra</span><span class="browser-sha">${esc(revision.slice(0, 12))}</span><span class="browser-date">${esc(dateText(report?.finished_at || currentRun()?.finished_at))}</span>`;
  const entries = groups.sort((a, b) => String(a.path || "").localeCompare(String(b.path || "")));
  if (!entries.length) {
    $("coverage-table").innerHTML = `<tr><td colspan="2" class="empty">${directories.length ? "No directories match the search." : "No directory scores in this run."}</td></tr>`;
    return;
  }
  const rows = [];
  entries.forEach((item) => {
    const label = String(item.path || "(root)");
    const checks = item.total === 1 ? "1 check" : `${item.total} checks`;
    rows.push(`<tr><td>${esc(label)}<span class="path-meta">${checks}</span></td><td>${score(item.passed || 0, item.total || 0)}</td></tr>`);
  });
  $("coverage-table").innerHTML = rows.join("");
}
function renderRun(report) {
  const run = currentRun();
  const directories = Array.isArray(report?.directories) ? report.directories : [];
  const checks = directories.reduce((result, directory) => {
    result.passed += Number(directory.passed || 0); result.total += Number(directory.total || 0);
    return result;
  }, { passed: 0, total: 0 });
  const revision = report?.browser_revision || run?.browser_revision || "working-tree";
  const runLabel = run?.id === state.runs[0]?.id ? "latest local test run" : "selected local test run";
  $("results-score").textContent = run ? `${checks.passed}/${checks.total}` : "—";
  $("results-description").textContent = run ? `Showing ${directories.length} directory scores from the ${runLabel} for zibra[${revision}]` : "No results selected.";
  renderCoverage(report);
}
function selectRun(id) {
  const run = state.runs.find((candidate) => candidate.id === id);
  if (!run) return;
  state.selectedId = id; state.selected = run;
  renderRunSelect(); renderRun(state.selected);
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
    if (selected) selectRun(selected); else renderRun(null);
  } catch (error) {
    $("health").textContent = "Unable to load"; $("results-description").textContent = error.message;
    $("coverage-table").innerHTML = `<tr><td colspan="2" class="empty">${esc(error.message)}</td></tr>`;
  }
}
$("run-select").addEventListener("change", (event) => selectRun(event.target.value));
$("path-search").addEventListener("input", (event) => { state.pathQuery = event.target.value; if (state.selected) renderCoverage(state.selected); });
$("refresh").addEventListener("click", load);
load();
