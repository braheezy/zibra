//! Installs Kiesel objects and native functions for one JavaScript realm.
//!
//! Binding declarations are comptime data. Every installed function retains
//! the caller-provided synchronous host context as Kiesel additional fields;
//! this module neither owns nor dereferences that context.

const kiesel = @import("kiesel");

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Realm = kiesel.execution.Realm;
const Value = kiesel.types.Value;

pub const Function = *const fn (*Agent, Value, Arguments) Agent.Error!Value;

pub const Binding = struct {
    name: []const u8,
    length: u32,
    function: Function,
};

/// Install the public `document` object and private `__native` host object,
/// returning the latter so cohesive binding domains can append functions with
/// their own narrower host interfaces. Every host context must outlive the
/// functions created for `realm`.
pub fn install(
    agent: *Agent,
    realm: *Realm,
    host_context: *anyopaque,
    comptime document_bindings: []const Binding,
    comptime native_bindings: []const Binding,
) !*kiesel.types.Object {
    const document = try kiesel.builtins.ordinaryObjectCreate(agent, null);
    try installFunctions(agent, realm, document, host_context, document_bindings);
    try realm.global_object.definePropertyDirect(
        agent,
        kiesel.types.PropertyKey.from("document"),
        .{
            .value_or_accessor = .{ .value = Value.from(document) },
            .attributes = .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            },
        },
    );

    const native = try kiesel.builtins.ordinaryObjectCreate(agent, null);
    try installFunctions(agent, realm, native, host_context, native_bindings);
    try realm.global_object.definePropertyDirect(
        agent,
        kiesel.types.PropertyKey.from("__native"),
        .{
            .value_or_accessor = .{ .value = Value.from(native) },
            .attributes = .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        },
    );
    return native;
}

/// Add one comptime binding table to an existing object. The context is a
/// synchronous borrowed interface stored verbatim in Kiesel's function data.
pub fn installFunctions(
    agent: *Agent,
    realm: *Realm,
    object: *kiesel.types.Object,
    host_context: *anyopaque,
    comptime bindings: []const Binding,
) !void {
    inline for (bindings) |binding| {
        const function = try kiesel.builtins.createBuiltinFunction(
            agent,
            .{ .function = binding.function },
            binding.length,
            binding.name,
            .{
                .realm = realm,
                .additional_fields = host_context,
            },
        );
        try object.definePropertyDirect(
            agent,
            kiesel.types.PropertyKey.from(binding.name),
            .{
                .value_or_accessor = .{ .value = Value.from(&function.object) },
                .attributes = .builtin_default,
            },
        );
    }
}
