//! Generation-scoped document lifecycle and lifecycle-event eligibility.
//!
//! A Frame or document loader owns one `Lifecycle` value for its currently
//! installed document. The value contains no DOM, JavaScript, task-runner, or
//! Browser pointers, so queued work can carry a `Dispatch` by value and check
//! it again immediately before delivering an event.

const std = @import("std");

/// Opaque identity supplied by the frame/tab generation owner. Zero is never
/// a live document generation.
pub const Generation = u64;
pub const invalid_generation: Generation = 0;

/// The monotonic lifecycle of one installed document.
///
/// `complete` means that the load event is eligible to be dispatched; it does
/// not mean that a queued load event has already run. A retired generation
/// suppresses both lifecycle events permanently.
pub const Phase = enum {
    loading,
    interactive,
    complete,
    discarded,
};

/// Lifecycle events whose delivery is controlled by this owner.
pub const Event = enum {
    dom_content_loaded,
    load,
};

/// State of one lifecycle event within its document generation.
pub const EventState = enum {
    /// The prerequisite lifecycle transition has not occurred yet.
    blocked,
    /// The event may be queued by the document owner.
    eligible,
    /// A queue owns the only outstanding delivery claim.
    claimed,
    /// The event was delivered and cannot be delivered again.
    dispatched,
};

/// A generation-stamped claim to dispatch one lifecycle event.
///
/// The scheduler that receives this value must either call `finishDispatch`
/// after attempting delivery or `releaseDispatch` if it could not queue the
/// work. Both operations are harmless after navigation retired the generation.
pub const Dispatch = struct {
    generation: Generation,
    event: Event,
};

pub const ResetError = error{
    InvalidGeneration,
    ReusedGeneration,
};

/// Owns lifecycle phase and exact-once lifecycle-event eligibility for one
/// document generation.
///
/// Callers provide globally fresh, nonzero generation values. `resetForGeneration`
/// may replace a live generation, which invalidates its queued `Dispatch`
/// values. A generation cannot be reused immediately after retirement because
/// doing so would make an old queued dispatch appear current again.
pub const Lifecycle = struct {
    /// The current generation, or the most recently retired one. Retaining a
    /// retired value lets `resetForGeneration` reject accidental reuse.
    generation: Generation = invalid_generation,
    phase: Phase = .discarded,
    dom_content_loaded: EventState = .blocked,
    load: EventState = .blocked,
    load_eligible: bool = false,

    pub fn init() Lifecycle {
        return .{};
    }

    /// Start a fresh loading lifecycle, discarding any prior live generation.
    ///
    /// `generation` must be a newly allocated nonzero identity. Replacing a
    /// lifecycle does not itself join work; the caller remains responsible for
    /// quiescing workers before any document-owned storage is reclaimed.
    pub fn resetForGeneration(self: *Lifecycle, generation: Generation) ResetError!void {
        if (generation == invalid_generation) return error.InvalidGeneration;
        if (generation == self.generation) return error.ReusedGeneration;
        self.* = .{
            .generation = generation,
            .phase = .loading,
        };
    }

    /// Return the installed generation, or null after it has been retired.
    pub fn currentGeneration(self: *const Lifecycle) ?Generation {
        return if (self.phase == .discarded) null else self.generation;
    }

    /// Whether `generation` still names this live document.
    pub fn isCurrent(self: *const Lifecycle, generation: Generation) bool {
        return generation != invalid_generation and
            self.phase != .discarded and
            self.generation == generation;
    }

    /// Advance a current document from loading to interactive.
    ///
    /// The caller invokes this only after parsing and every
    /// DOMContentLoaded-blocking script have completed. It makes
    /// DOMContentLoaded eligible exactly once. Repeated, stale, or retired
    /// notifications leave the state unchanged and return false.
    pub fn enterInteractive(self: *Lifecycle, generation: Generation) bool {
        if (!self.isCurrent(generation) or self.phase != .loading) return false;
        self.phase = .interactive;
        self.dom_content_loaded = .eligible;
        return true;
    }

    /// Record that all load-event blockers have completed for this generation.
    ///
    /// This may happen before the document becomes interactive; in that case
    /// the fact is retained but the load event still waits for
    /// DOMContentLoaded's dispatch. It is intentionally one-way: callers must
    /// not report final load eligibility until no later blocker can be added.
    pub fn markLoadEligible(self: *Lifecycle, generation: Generation) bool {
        if (!self.isCurrent(generation) or self.load_eligible) return false;
        self.load_eligible = true;
        self.promoteCompleteIfReady();
        return true;
    }

    /// Claim the next lifecycle event eligible for this generation.
    ///
    /// DOMContentLoaded always precedes load, including when all load blockers
    /// finished before parsing. A claim prevents duplicate queueing until it is
    /// released or finished.
    pub fn claimNextDispatch(self: *Lifecycle, generation: Generation) ?Dispatch {
        if (!self.isCurrent(generation)) return null;

        if (self.dom_content_loaded == .eligible) {
            self.dom_content_loaded = .claimed;
            return .{ .generation = generation, .event = .dom_content_loaded };
        }
        if (self.dom_content_loaded != .dispatched) return null;
        if (self.phase != .complete or self.load != .eligible) return null;

        self.load = .claimed;
        return .{ .generation = generation, .event = .load };
    }

    /// Release an unqueued dispatch claim so another scheduling attempt may
    /// claim it. Returns false for stale, retired, finished, or mismatched work.
    pub fn releaseDispatch(self: *Lifecycle, dispatch: Dispatch) bool {
        if (!self.isCurrent(dispatch.generation)) return false;
        const state = self.stateForEvent(dispatch.event);
        if (state.* != .claimed) return false;
        state.* = .eligible;
        return true;
    }

    /// Mark a claimed event as dispatched exactly once.
    ///
    /// Call this after attempting synchronous delivery even if a listener
    /// throws: an exception in a listener does not make the browser redeliver
    /// the same DOM lifecycle event.
    pub fn finishDispatch(self: *Lifecycle, dispatch: Dispatch) bool {
        if (!self.isCurrent(dispatch.generation)) return false;
        const state = self.stateForEvent(dispatch.event);
        if (state.* != .claimed) return false;
        state.* = .dispatched;
        if (dispatch.event == .dom_content_loaded) self.promoteCompleteIfReady();
        return true;
    }

    /// Return an event's state only if `generation` is still installed.
    pub fn eventState(self: *const Lifecycle, generation: Generation, event: Event) ?EventState {
        if (!self.isCurrent(generation)) return null;
        return switch (event) {
            .dom_content_loaded => self.dom_content_loaded,
            .load => self.load,
        };
    }

    /// Retire the current document generation and suppress all pending events.
    /// Retaining the generation value ensures accidentally reusing it is
    /// rejected by `resetForGeneration`.
    pub fn retire(self: *Lifecycle, generation: Generation) bool {
        if (!self.isCurrent(generation)) return false;
        self.phase = .discarded;
        self.dom_content_loaded = .blocked;
        self.load = .blocked;
        self.load_eligible = false;
        return true;
    }

    fn promoteCompleteIfReady(self: *Lifecycle) void {
        if (self.phase != .interactive or
            self.dom_content_loaded != .dispatched or
            !self.load_eligible) return;

        self.phase = .complete;
        self.load = .eligible;
    }

    fn stateForEvent(self: *Lifecycle, event: Event) *EventState {
        return switch (event) {
            .dom_content_loaded => &self.dom_content_loaded,
            .load => &self.load,
        };
    }
};

test "lifecycle dispatches DOMContentLoaded then load exactly once" {
    var lifecycle = Lifecycle.init();
    try lifecycle.resetForGeneration(41);

    try std.testing.expectEqual(Phase.loading, lifecycle.phase);
    try std.testing.expect(lifecycle.isCurrent(41));
    try std.testing.expect(lifecycle.claimNextDispatch(41) == null);

    try std.testing.expect(lifecycle.enterInteractive(41));
    try std.testing.expectEqual(EventState.eligible, lifecycle.dom_content_loaded);
    try std.testing.expectEqual(Phase.interactive, lifecycle.phase);

    const dom_content_loaded = lifecycle.claimNextDispatch(41) orelse unreachable;
    try std.testing.expectEqual(Event.dom_content_loaded, dom_content_loaded.event);
    try std.testing.expect(lifecycle.claimNextDispatch(41) == null);
    try std.testing.expect(lifecycle.finishDispatch(dom_content_loaded));
    try std.testing.expectEqual(EventState.dispatched, lifecycle.dom_content_loaded);

    try std.testing.expect(lifecycle.markLoadEligible(41));
    try std.testing.expectEqual(Phase.complete, lifecycle.phase);
    const load = lifecycle.claimNextDispatch(41) orelse unreachable;
    try std.testing.expectEqual(Event.load, load.event);
    try std.testing.expect(lifecycle.finishDispatch(load));
    try std.testing.expectEqual(EventState.dispatched, lifecycle.load);
    try std.testing.expect(lifecycle.claimNextDispatch(41) == null);
    try std.testing.expect(!lifecycle.finishDispatch(load));
}

test "lifecycle holds load until DOMContentLoaded dispatches" {
    var lifecycle = Lifecycle.init();
    try lifecycle.resetForGeneration(7);

    try std.testing.expect(lifecycle.markLoadEligible(7));
    try std.testing.expectEqual(Phase.loading, lifecycle.phase);
    try std.testing.expect(lifecycle.enterInteractive(7));
    try std.testing.expectEqual(Phase.interactive, lifecycle.phase);

    const dom_content_loaded = lifecycle.claimNextDispatch(7) orelse unreachable;
    try std.testing.expectEqual(Event.dom_content_loaded, dom_content_loaded.event);
    try std.testing.expect(lifecycle.finishDispatch(dom_content_loaded));
    try std.testing.expectEqual(Phase.complete, lifecycle.phase);

    const load = lifecycle.claimNextDispatch(7) orelse unreachable;
    try std.testing.expectEqual(Event.load, load.event);
}

test "released lifecycle dispatch claims can be retried" {
    var lifecycle = Lifecycle.init();
    try lifecycle.resetForGeneration(12);
    try std.testing.expect(lifecycle.enterInteractive(12));

    const first = lifecycle.claimNextDispatch(12) orelse unreachable;
    try std.testing.expect(lifecycle.releaseDispatch(first));
    try std.testing.expectEqual(EventState.eligible, lifecycle.dom_content_loaded);

    const retry = lifecycle.claimNextDispatch(12) orelse unreachable;
    try std.testing.expectEqual(first, retry);
    try std.testing.expect(lifecycle.finishDispatch(retry));
}

test "generation reset and retirement reject stale lifecycle work" {
    var lifecycle = Lifecycle.init();
    try lifecycle.resetForGeneration(21);
    try std.testing.expect(lifecycle.enterInteractive(21));
    const stale = lifecycle.claimNextDispatch(21) orelse unreachable;

    try lifecycle.resetForGeneration(22);
    try std.testing.expect(!lifecycle.finishDispatch(stale));
    try std.testing.expect(!lifecycle.releaseDispatch(stale));
    try std.testing.expect(!lifecycle.retire(21));
    try std.testing.expect(lifecycle.enterInteractive(22));

    try std.testing.expect(lifecycle.retire(22));
    try std.testing.expectEqual(Phase.discarded, lifecycle.phase);
    try std.testing.expect(lifecycle.currentGeneration() == null);
    try std.testing.expect(lifecycle.claimNextDispatch(22) == null);
    try std.testing.expectError(error.ReusedGeneration, lifecycle.resetForGeneration(22));
    try std.testing.expectError(error.InvalidGeneration, lifecycle.resetForGeneration(0));
}
