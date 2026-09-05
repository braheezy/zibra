// Local protocol fixture, not an upstream harness replacement or WPT pass.
var fixtureStart, fixtureResult;
function add_completion_callback(callback) {}
function add_start_callback(callback) { fixtureStart = callback; }
function add_result_callback(callback) { fixtureResult = callback; }
