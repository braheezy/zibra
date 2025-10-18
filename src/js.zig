const std = @import("std");

const kiesel = @import("kiesel");
const Agent = kiesel.execution.Agent;
const Script = kiesel.language.Script;
const Realm = kiesel.execution.Realm;
const Value = kiesel.types.Value;

const Js = @This();

platform: Agent.Platform,
agent: Agent,
realm: *Realm,

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

    // Set up console.log
    try self.setupConsole();

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
    self.platform.deinit();
    self.agent.deinit();
    allocator.destroy(self);
}

pub fn evaluate(self: *Js, code: []const u8) !Value {
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
