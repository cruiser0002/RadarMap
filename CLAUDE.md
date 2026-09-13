# RadarMap — Project Notes for Claude Code

## 1. Derivation logic: one function, one source of truth

This codebase has repeatedly broken the same way: a small formula (a hash, an id
derivation, a sanitizer, an interval/threshold calculation) gets **inlined at a second
call site** instead of calling the existing function, and the copy silently drifts —
no compiler error, no test failure, just two clients that quietly stop agreeing.

Concrete incidents (see `docs/CLOUD_DATA_MANAGEMENT.md` §7.A history and git log):
- `roomId = name + deriveRoomPadding(pin, name)` was inlined independently in `hostRoom`,
  `joinRoom`, and `adoptCompanionSession` (`GameStateManager.swift`). The third copy dropped
  the padding step entirely, which redirected an already-hosted room to an empty/wrong
  Firebase path — and a wrong encryption key along with it — the moment a companion
  device's WCSession context exchange reflexively re-triggered room adoption.
- The same SHA256-into-Crockford-alphabet pattern was hand-copied in two Swift functions
  (`deriveRoomPadding`, `deriveMemberId`) and three Python files.
- `sanitize_pin`'s spoken-word-to-digit mapping (`AppConstants.UI.pinWordMapping`) existed
  only in Swift; all three Python simulator copies silently diverged on any dictated PIN.
- `stress_test_simulator.py` grew a silent fallback default (`cleaned[:12] or "STRESS"`)
  that neither the Swift app nor `player_simulator.py` has.

**Rule:** before adding a second place that needs a value already computed elsewhere —
especially anything keyed off `(name, pin)`, `(callsign)`, or a threshold/interval formula
that's supposed to match `AppConstants` — grep for the existing function first
(`deriveRoomId`, `deriveRoomPadding`, `deriveTelemetryKey`, `hashPin`, `deriveMemberId`,
`sanitizeRoomNameInput`, `sanitizePinInput`, `AppConstants.Timing.ConstantBandwidth.*`) and
call it. Do not re-derive the formula inline, even if it's "just two lines" — that's
exactly how the room-id bug happened.

**Cross-language parity is a second, easy-to-miss axis of the same problem.** Several
Swift functions have a required Python mirror for the simulators to interoperate with the
real app (`RadarMap/Managers/GameStateManager.swift` / `FirebaseSyncManager.swift` ↔
`notebooks/player_simulator.py`, `scripts/stress_test_simulator.py`,
`notebooks/stress_test_simulator.py` — the latter two are kept byte-identical copies of one
file, so an edit to one must be copied to the other, not reimplemented). When you change
one side of a Swift/Python pair, grep the other language for the same formula and update it
in the same commit — don't rely on a docstring saying "matches X" to make it true. The
pairs to check: `deriveRoomId`/`derive_room_id`, `deriveRoomPadding`/`derive_room_padding`,
`hashPin`/`hash_pin`, `deriveTelemetryKey`/`derive_telemetry_key`,
`deriveMemberId`/`derive_member_id`, `sanitizeRoomNameInput`/`sanitize_room_name`,
`sanitizePinInput`/`sanitize_pin`, `AppConstants.Timing.ConstantBandwidth`/the
`solve_update_interval`-adjacent constants at the top of the simulator scripts.

## 2. No fallback-as-design without explicit permission, per instance

The word "fallback" itself is not banned — plenty of legitimate code has default values or
scheduled retry mechanisms with no issue. What's banned is the *architectural practice*: a
bolted-on "if the primary path fails, patch with X" branch, especially a new one introduced
without asking first.

**Why this rule exists:** A function existed only to duplicate another function's
payload-building logic and run conditionally when the primary transport failed — instead of
the primary path being restructured so it already produced correct behavior in both the
common and failure cases. This is a smaller version of Rule 1 (a second, degraded copy of
logic that has to be kept in sync with the first) plus an unreviewed architectural decision.
A second incident: `WatchConnectivityManager.publishHighSpeedFallback()` was added (commit
`555dea3`) to route the `activeUntil` lease through `updateApplicationContext` — bundling the
*entire* `localLS` snapshot alongside it — whenever `sendMessage` was unreachable or failed.
It was written and merged without ever being surfaced to the user for a yes/no, and remained
indistinguishable from "how the system works" until the user caught it by directly asking what
a debug log line describing it meant. It has since been removed; `advertise*HighSpeed` is
`sendMessage`-only again, self-healing via the next 1Hz tick or the TTL backstop.

**How to apply — this is a hard stop, not a judgment call:**
- Prefer restructuring so the primary path already handles the failure case, over adding a
  reactive patch invoked only on error.
- Before writing *any* new fallback/degrade-path method — in code or docs — stop and ask the
  user in the conversation, every single time, even if a similar one was approved earlier.
  Don't assume precedent extends permission, and don't infer consent from silence, from the
  absence of an objection, or from the change "seeming obviously necessary" to unblock other
  work. Wait for an explicit, affirmative reply before writing the code. If you notice one was
  already written (by a prior session, another tool, or yourself) without that approval having
  been given, say so plainly the moment you notice — don't describe its behavior neutrally as
  if it were sanctioned design.
- Don't reflexively rename or flag every occurrence of the word "fallback" — check whether
  it's actually a bolted-on failure-branch (needs justification or removal) versus a
  legitimately-designed default value or scheduled mechanism that's merely mislabeled.
- Never let a sanitizer/parser silently substitute a placeholder for empty/invalid input
  unless every parallel implementation of that same logic does the same thing — an
  empty/invalid result should surface as empty/invalid, not get a silent default that then
  has to be remembered as a special case forever.


## 3. Simple is reliable — no stubs, no stacked patches

When a bug traces back to two independent code paths computing overlapping information (two
devices each independently resolving the same member's data, two functions each deriving the
same value), the fix is to remove the second path — not to add self-healing/validation/retry
logic that lets both paths keep existing while papering over their disagreements. A stack of
individually-reasonable patches (a self-heal check here, a membership-validation gate there, a
staleness guard somewhere else) is not resilience — it's exactly as fragile as a single
fallback branch, just spread across more call sites, and it's *worse* for maintainability:
nobody (including a future session) can hold the accumulated set of special cases in their head
or safely change any one of them without re-auditing all the others.

**Concrete incident:** a member's callsign was constructed as a stub (`callsign:
knownCallsigns[id] ?? ""`) by `FirebaseSyncManager.updateMember(with:in:)` when telemetry for a
new member arrived before this device had resolved their real data — a placeholder value with
no guarantee of ever being corrected. Rather than fixing the actual cause (two devices
independently connected to Firebase, each running this same stub-then-resolve dance and free to
land on different answers), the proposed fixes kept escalating: self-heal the stub from a cache
on every tick, then add a member-list validation gate to reject unrecognized senders, then a
staleness check for late-arriving listener callbacks. Each was individually defensible. Together
they would have buried the actual bug (why does a second, independent copy of this data exist at
all?) under a pile of code nobody wrote deliberately as a system.

**Rule:** never introduce a stub/placeholder value (an empty string, a default enum case, a
zeroed struct) that is meant to be corrected later by some other code path, unless that
correction is guaranteed — not "usually," not "self-heals on the next tick" — to actually run
before the stub is ever observed or persisted. If a correction can silently fail to apply (a
guard condition that can legitimately not hold, a fetch that can fail, a race with another
writer), that is a sign the stub itself is the wrong design, not that the correction path needs
another layer of retry/validation on top. When you notice two independent code paths computing
the same information, the fix is almost always to delete one of them and have the survivor be
the single source of truth — this is Rule 1 above, extended to runtime data (two devices'
independently-fetched copies of the same member) and not just formulas — not to add
reconciliation logic that lets both keep existing.

## 4. Control-flow gates must match the invariant the doc comment claims

A function's doc comment states an invariant ("runs unconditionally," "gated solely on
X," "regardless of Y," "never throttled by Z") — and then a `guard` a few lines down
enforces something narrower, because the guard was written (or widened) for an unrelated
reason without re-checking what the comment above it had already promised. Nothing
catches this: it type-checks, it doesn't crash, and it only shows up as a real device
behaving differently from its stated spec under a specific runtime condition nobody
thought to test (e.g. a screen-dimmed-but-alive state that never comes up in the
simulator unless you specifically trigger it).

Concrete incident: `GameStateManager.updateActiveAdvertisementTimer()`'s doc comment said
the WCSession lease-advertisement loop is "gated solely on `isWristActive`" and separately
said the *send* should only be qualified by `isReachable`/session activation (already true
one layer down, inside `advertiseWatchHighSpeed`/`advertisePhoneHighSpeed`). But the timer
itself carried `guard isWristActive else { cancel the timer }` — so when watchOS
Always-On dimmed the screen (`isLuminanceReduced → isWristActive == false`), the *entire
1Hz loop* stopped, not just gained an extra network qualifier. The watch's `w2p_hs.activeUntil`
lease then expired, which the phone read as "watch went away" and used to trigger an
unwanted uplink/listener handoff — even though WCSession itself never detached and
`isReachable`/`isActivated` were the only qualifiers actually asked for. The loop was
supposed to always tick; only the send-vs-fallback decision was supposed to branch.

**Rule:** when a `guard`/`if` sits inside (or wraps the caller of) a function whose doc
comment makes a claim like "always," "unconditional," "regardless of," "deliberately NOT
gated on X," or "the only qualifier is X" — the code must be checked against that claim
before trusting either one. Two failure directions, both worth grepping for:
- A gate exists that the doc comment doesn't mention or contradicts (this incident).
- A doc comment claims a gate that the code doesn't actually enforce.
When you add or widen a `guard` on a flag like `isWristActive`/`isReachable`/`isActive`
inside `WatchConnectivityManager.swift` or `GameStateManager.swift`, re-read every
adjacent `///` comment on that function (and on its callers) and confirm the new gate
doesn't silently narrow a scope the comment promises is broader — don't just check that
the flag "seems related." If a flag is being reused for a new gate that its existing
consumers don't share (e.g. `isWristActive` already means three different things across
`updateActiveAdvertisementTimer`, `evaluateListenerGate`, and
`locationHeadingManager.enterLowPowerMode`/`exitLowPowerMode` — process-alive, user-attention,
and power-mode respectively), that's a signal the flag needs splitting, not a new gate
bolted onto the shared one.

---

**General pattern across all three:** each bug was a *quiet divergence* between what the
code was supposed to guarantee and what it actually did, introduced by a small, locally
reasonable-looking edit (an inline shortcut, a defensive patch, a reused flag) that nothing
mechanical caught. Before landing this kind of small addition, actively check it against the
existing single source of truth / the documented invariant / the flag's other consumers —
don't trust that "it's just two lines" or "it's obviously related" means it's safe.

