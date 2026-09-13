# Standing Engineering Rules (Learned the Hard Way on This Codebase)

Apply these as non-negotiable defaults on every change, not just when reminded. Each one below caused a real, silent production bug before it became a rule — none of them were caught by the compiler or the test suite at the time.

---

## 1. One Derivation, One Source of Truth

Never inline a second copy of a formula/derivation that must produce an identical result somewhere else — an id/hash derivation, a sanitizer, a threshold or interval calculation meant to track a shared constant. Grep for the existing function and call it, even if the "copy" is just two lines.

### Why this rule exists
- `roomId = name + deriveRoomPadding(pin, name)` was independently inlined at three call sites (`hostRoom`, `joinRoom`, `adoptCompanionSession` in [`GameStateManager.swift`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift)). The third copy silently dropped the padding step — no compiler error, no failing test — and redirected an already-live session to the wrong Firebase storage path (and derived the wrong encryption key) the moment a background WCSession handoff re-triggered room adoption.
- The same SHA256-into-Crockford-alphabet pattern was hand-copied across Swift functions ([`deriveRoomPadding`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift), [`deriveMemberId`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift)) and three Python files.
- A word-to-value mapping ([`AppConstants.UI.pinWordMapping`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/AppConstants.swift)) existed in only one of several places that needed it; simulator copies silently diverged on any dictated PIN.
- A silent fallback default was present in only one of three otherwise-parallel sanitizers.

### Cross-language / cross-module parity is the same bug in disguise
When logic is mirrored across languages or modules (e.g. a production client's logic re-implemented in a test harness/simulator so it can interoperate), treat every such pair as one unit. Changing one side without grepping for and updating the other is not a smaller version of this problem — it's the identical problem.

Key mirrored pairs between Swift ([`RadarMap/Managers/GameStateManager.swift`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift), [`RadarMap/Managers/FirebaseSyncManager.swift`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/FirebaseSyncManager.swift)) and Python ([`notebooks/player_simulator.py`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/notebooks/player_simulator.py), [`scripts/stress_test_simulator.py`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/scripts/stress_test_simulator.py), [`notebooks/stress_test_simulator.py`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/notebooks/stress_test_simulator.py) — note that the two stress test simulator files are kept byte-identical):
- `deriveRoomId` ↔ `derive_room_id`
- `deriveRoomPadding` ↔ `derive_room_padding`
- `hashPin` ↔ `hash_pin`
- `deriveTelemetryKey` ↔ `derive_telemetry_key`
- `deriveMemberId` ↔ `derive_member_id`
- `sanitizeRoomNameInput` ↔ `sanitize_room_name`
- `sanitizePinInput` ↔ `sanitize_pin`
- `AppConstants.Timing.ConstantBandwidth.*` ↔ top-of-file simulator interval calculation constants

### How to apply
- Before writing logic that recomputes a value derivable elsewhere, search for the existing implementation first (`deriveRoomId`, `deriveRoomPadding`, `deriveTelemetryKey`, `hashPin`, `deriveMemberId`, `sanitizeRoomNameInput`, `sanitizePinInput`, `AppConstants.Timing.ConstantBandwidth.*`).
- If editing one side of a known mirrored pair, find and update the other side in the same change — don't rely on a comment saying "matches X" to make it true.

---

## 2. No Fallback-as-Design Without Explicit Permission, Per Instance

The word "fallback" itself is not banned — plenty of legitimate code has default values or scheduled retry mechanisms with no issue. What's banned is the *architectural practice*: a bolted-on "if the primary path fails, patch with X" branch, especially a new one introduced without asking first.

### Why this rule exists
A function existed only to duplicate another function's payload-building logic and run conditionally when the primary transport failed — instead of the primary path being restructured so it already produced correct behavior in both the common and failure cases. This is a smaller version of Rule 1 (a second, degraded copy of logic that has to be kept in sync with the first) plus an unreviewed architectural decision. A second incident: [`WatchConnectivityManager.publishHighSpeedFallback()`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/WatchConnectivityManager.swift) was added to route the `activeUntil` lease through `updateApplicationContext` — bundling the entire `localLS` snapshot alongside it — whenever `sendMessage` was unreachable or failed, without ever being surfaced to the user for a yes/no. It stayed indistinguishable from sanctioned design until the user caught it by directly asking what it did. It has since been removed.

### How to apply — this is a hard stop, not a judgment call
- Prefer restructuring so the primary path already handles the failure case, over adding a reactive patch invoked only on error.
- Before writing *any* new fallback/degrade-path method — in code or docs — stop and ask the user in the conversation, every single time, even if a similar one was approved earlier. Don't assume precedent extends permission, and don't infer consent from silence or from the change "seeming obviously necessary." Wait for an explicit, affirmative reply before writing the code.
- If you notice a fallback was already written without that approval having been given (by a prior session, another tool, or yourself), say so plainly the moment you notice — don't describe its behavior neutrally as if it were sanctioned design.
- Don't reflexively rename or flag every occurrence of the word "fallback" — check whether it's actually a bolted-on failure-branch (needs justification or removal) versus a legitimately-designed default value or scheduled mechanism that's merely mislabeled.
- Never let a sanitizer/parser silently substitute a placeholder for empty/invalid input unless every parallel implementation of that same logic does the same thing — an empty/invalid result should surface as empty/invalid, not get a silent default that then has to be remembered as a special case forever.

---

## 3. Simple Is Reliable — No Stubs, No Stacked Patches

When a bug traces back to two independent code paths computing overlapping information (two devices each independently resolving the same member's data, two functions each deriving the same value), the fix is to remove the second path — not to add self-healing/validation/retry logic that lets both paths keep existing while papering over their disagreements. A stack of individually-reasonable patches (a self-heal check here, a membership-validation gate there, a staleness guard somewhere else) is not resilience — it's exactly as fragile as a single fallback branch, just spread across more call sites, and it's *worse* for maintainability: nobody (including a future session) can hold the accumulated set of special cases in their head or safely change any one of them without re-auditing all the others.

### Why this rule exists
A member's callsign was constructed as a stub (`callsign: knownCallsigns[id] ?? ""`) by [`FirebaseSyncManager.updateMember(with:in:)`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/FirebaseSyncManager.swift) when telemetry for a new member arrived before this device had resolved their real data — a placeholder value with no guarantee of ever being corrected. Rather than fixing the actual cause (two devices independently connected to Firebase, each running this same stub-then-resolve dance and free to land on different answers), the proposed fixes kept escalating: self-heal the stub from a cache on every tick, then add a member-list validation gate to reject unrecognized senders, then a staleness check for late-arriving listener callbacks. Each was individually defensible. Together they would have buried the actual bug (why does a second, independent copy of this data exist at all?) under a pile of code nobody wrote deliberately as a system.

### How to apply
- Never introduce a stub/placeholder value (an empty string, a default enum case, a zeroed struct) meant to be corrected later by some other code path, unless that correction is guaranteed — not "usually," not "self-heals on the next tick" — to run before the stub is ever observed or persisted.
- If a correction can silently fail to apply (a guard condition that can legitimately not hold, a fetch that can fail, a race with another writer), that's a sign the stub itself is the wrong design — not that the correction path needs another layer of retry/validation on top.
- When you notice two independent code paths computing the same information, delete one of them and make the survivor the single source of truth — this is Rule 1 above, extended to runtime data (two devices' independently-fetched copies of the same member), not just formulas. Don't add reconciliation logic that lets both keep existing.

---

## 4. A Control-Flow Gate Must Match the Invariant Its Own Doc Comment Claims

A function's doc comment states an invariant ("runs unconditionally," "gated solely on X," "regardless of Y," "the only qualifier is X") — and a `guard`/`if` a few lines away (or in a caller) silently enforces something narrower, usually because the guard was written or widened later for an unrelated reason without re-checking what the comment above it had already promised. This type-checks cleanly and doesn't crash; it only surfaces as the system behaving differently from its documented spec under a specific runtime condition that's easy to never test (e.g. a "dimmed but still alive" device state, a rare network transition, a backgrounded-but-running process).

### Why this rule exists
[`GameStateManager.updateActiveAdvertisementTimer()`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift) was documented as "gated solely on `isWristActive`" for its own lifecycle, with a *separate*, explicit note that the actual network send one layer down should only be qualified by reachability/session-activation checks. But the loop's own guard clause stopped the entire loop — not just the send — whenever `isWristActive` went false, including during a state (watchOS Always-On screen dimmed, `isLuminanceReduced`, process still fully running) that was never supposed to count as "inactive" for this purpose. The phone read the watch's resulting lease expiration as "it went away" and triggered an unwanted ownership handoff, even though WCSession itself never disconnected.

### How to apply
- Whenever you add or widen a `guard`/`if` on a shared state flag (e.g., in [`WatchConnectivityManager.swift`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/WatchConnectivityManager.swift) or [`GameStateManager.swift`](file:///Users/cruiser/Documents/antigravity/jolly-hypatia/RadarMap/Managers/GameStateManager.swift)), re-read every adjacent doc comment on that function *and its callers* and confirm the new gate doesn't silently narrow a scope the comment promises is broader. "The flag seems related" is not sufficient — check the literal claim in the comment against the literal condition in the code.
- Check both failure directions:
  1. A gate exists that the doc comment doesn't mention or contradicts.
  2. A doc comment claims a guarantee ("always," "regardless of") that the code doesn't actually enforce.
- If a single flag is being read by multiple consumers for genuinely different purposes (e.g. `isWristActive` being conflated across process-alive, user-attention, and power-mode/cadence reduction), that's a signal the flag needs splitting into separately-named booleans — not a new special-case gate bolted onto the shared one.

---

## General Pattern Across All Four

Each bug was a **quiet divergence** between what the code was supposed to guarantee and what it actually did, introduced by a small, locally reasonable-looking edit (an inline shortcut, a defensive patch, a reused flag) that nothing mechanical caught. Before landing this kind of small addition, actively check it against:
1. The existing single source of truth.
2. The documented invariant and comments.
3. The flag's other consumers across the system.

Do not trust that "it's just two lines" or "it's obviously related" means it is safe.
