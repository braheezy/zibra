//! Process-wide Kiesel collector initialization and native-thread registrations.
//! A registration belongs to the calling OS thread, not a Js host or callback:
//! returned Values can remain live on its stack after a host lock is released.
//! The pthread destructor retires owned registrations before that thread exits.

const std = @import("std");
const kiesel = @import("kiesel");
const bdwgc = @import("bdwgc");

// bdwgc-zig translates gc.h without GC_THREADS, omitting these declarations
// even though its linked collector has thread support. Reuse its stack-base
// type and collector; do not link a second GC or change dependency options.
extern fn GC_allow_register_threads() void;
extern fn GC_thread_is_registered() c_int;
extern fn GC_register_my_thread(*const bdwgc.c.struct_GC_stack_base) c_int;
extern fn GC_unregister_my_thread() c_int;

var initialization_mutex: std.Io.Mutex = .init;
var initialized = false;
var registration_key: std.c.pthread_key_t = undefined;
threadlocal var registered = false;

/// Call before allocating or accessing Kiesel values on a native thread.
/// Registration lasts until OS-thread exit, including for the thread that
/// first initializes GC. Foreign registrations are borrowed, never retired.
/// As with collector initialization itself, failure to establish safe tracing
/// is fatal; continuing would expose live values to reclamation.
pub fn ensureCurrentThread(io: std.Io) void {
    if (!kiesel.build_options.enable_libgc or registered) return;

    initialization_mutex.lockUncancelable(io);
    if (!initialized) {
        if (std.c.pthread_key_create(&registration_key, retireThread) != .SUCCESS)
            @panic("Unable to create collector thread-lifetime key");
        const owns_initial_thread = !bdwgc.isInitCalled();
        kiesel.gc.init();
        GC_allow_register_threads();
        // GC implicitly registers its initializing thread, even when that is
        // a short-lived tab worker rather than the process's main thread.
        if (owns_initial_thread) ownRegistration();
        initialized = true;
    }
    initialization_mutex.unlock(io);

    if (registered) return;
    if (GC_thread_is_registered() != 0) {
        registered = true;
        return;
    }
    var stack_base: bdwgc.c.struct_GC_stack_base = undefined;
    if (bdwgc.c.GC_get_stack_base(&stack_base) != bdwgc.c.GC_SUCCESS)
        @panic("Unable to discover collector thread stack");
    switch (GC_register_my_thread(&stack_base)) {
        bdwgc.c.GC_SUCCESS => ownRegistration(),
        bdwgc.c.GC_DUPLICATE => registered = true,
        else => @panic("Unable to register collector thread"),
    }
}

fn ownRegistration() void {
    if (std.c.pthread_setspecific(registration_key, &registration_key) != 0)
        @panic("Unable to retain collector thread registration");
    registered = true;
}

fn retireThread(_: *anyopaque) callconv(.c) void {
    // No Js/Agent pointers or allocations are needed here. pthread clears the
    // key before calling us; an actual later GC entry can register anew.
    registered = false;
    if (GC_unregister_my_thread() != bdwgc.c.GC_SUCCESS)
        @panic("Unable to retire collector thread registration");
}
