# Room ID Hardening & Schema Cleanup — Implementation Spec

Supersedes the earlier draft of this file (random-salt room ids). Final design below.

---

## ⚡ Key Room ID & Schema Constants

The following centralized constants from [`AppConstants.swift`](RadarMap/AppConstants.swift) (`AppConstants.UI`, `AppConstants.Subscription`, `AppConstants.Timing`, and `AppConstants.Network`) govern room security, schema lengths, and caps:

| Section & Domain | Constant / Property | Value | Architectural Scope & Enforcement |
| :--- | :--- | :--- | :--- |
| **§1-2 Room Name Entry**| `minRoomNameEntryLength` | `4` characters | Minimum allowed squad name input length (`UI`) |
| **§1-2 Room Name Entry**| `maxRoomNameEntryLength` | `12` characters | Maximum user-typed squad name length (`UI`) |
| **§1-2 PIN Validation** | `minPinLength` / `maxPinLength` | `4` min / `16` max | Mandatory squad PIN digit bounds (`UI`) |
| **§1-2 Room ID Suffix** | PIN-Derived Suffix Padding | `4` characters | Deterministic SHA-256 Crockford Base32 hash suffix |
| **§1-2 Full Room Key**  | `maxRoomNameLength` | `16` characters | Total Firebase path key length ($12 + 4$) (`database.rules.json`) |
| **§3 Member Roles**    | `MemberRole` | `"leader"`, `"player"` | Short wire field `rol` replacing boolean `isHost` |
| **§4 Short Identifiers**| ID Length & Alphabet | `8` chars, Crockford Base32 | 40-bit random entropy for member and indicator IDs |
| **§5 Short Segments**  | Root Paths & Sub-branches | `/r`, `/p`, `/t`, `/m`, `/o`, `/i` | Compressed wire paths (`Network.Endpoints`) |
| **§6 Tactical Quota**   | `freeTierMaxTacticalIndicators`| `0` markers | Free tier cannot drop tactical indicators |
| **§6 Tactical Quota**   | `proTierMaxTacticalIndicators` | `20` markers | Shared room cap on enemy & environmental markers (`mti`) |
| **§6 Indicator Timers**| `enemyIndicatorFadeDurationSeconds`| `300.0s` (5 min) | Linear fade duration for enemy markers |
| **§6 Indicator Timers**| `tacticalIndicatorAckTimeoutSeconds`| `10.0s` | Host network timeout for indicator placement ACK |
| **§6 Indicator Timers**| `indicatorHoldToDeleteDurationSeconds`| `1.2s` | Long-press gesture duration to delete placed markers |
| **§8 Room TTL**        | `idleCutoffHours` | `12.0` hours (43,200s) | Inactivity expiration watermark (`Timing.Inactivity`) |
| **§8 Host Refresh**    | Host Expiry Refresh Rate | `3600.0s` (hourly) | Host heartbeat interval extending `exp` timestamps |

---

## Motivation

`database.rules.json` grants `.read: true` on every `rooms/$roomId` node with no rate
limiting. Today a room id is just the user-typed squad name, uppercased and trimmed, used
directly as the RTDB path key. Names are short, human-chosen, and not secret — dictionary-
guessable — so anyone who guesses a room name can read its full contents (member list, host
id, `pinHash`) without ever knowing the join PIN, since the PIN currently only gates *joining*,
not *reading*.

While fixing that, several adjacent schema issues were found and folded into this same pass:
a redundant per-member `isHost` flag, several dead/unused fields (`hasPin`,
`lastActivityTimestamp`, `createdAt`, tactical `meta`/`updatedAt`), a full-UUID id still in use
for tactical indicators, an unbounded tactical-indicator growth path, and REST-style polling
left over from before the app moved to the Firebase SDK's real-time listeners.

## Final schema

```
r/                                          (was "rooms")
  {roomId}/                                 16 chars total: 4-12 char name + PIN-derived padding filling the remainder
    id: "ALPHA1XQ7K3M4N"                    full-length, kept human-readable
    hst: "A3F9K2QZ"                         was hostId
    cap: 12                                 was maxCapacity (free tier stays 4)
    mti: 20                                 was maxEnemyIndicatorsCount; now covers enemy+environment (0 free / 20 pro)
    pin: "c59c62cd..."                      was pinHash — non-optional (PIN is mandatory), hasPin removed
    exp: 1789141367.378                     was expireAt — refreshed hourly by host
    m/                                      was "members"
      {memberId}/                           8 chars, Crockford alphabet (23456789ABCDEFGHJKLMNPQRSTUVWXYZ)
        mid: "A3F9K2QZ"                     was id
        csn: "VIPER-1"                      was callsign
        rol: "leader"                       was isHost: true — MemberRole (player/leader, expandable)
    # createdAt, lastActivityTimestamp, hasPin: REMOVED (dead/redundant)
    # indicators: REMOVED from the room's own Codable representation (was always an empty,
    # meaningless mirror — real indicator data lives under t/{roomId})

p/                                          (was "telemetry")
  {roomId}/
    exp: 1789141367.378                     refreshed hourly alongside r/ and t/
    {memberId}: [lat, lng, hr, ts]           4-element compact array — unchanged, out of scope

t/                                          (was "tactical")
  {roomId}/
    exp: 1789141367.378                     was expireAt — refreshed hourly
    o/                                      "orders" branch — squadOrder category only
      {indicatorId}: [type_code, lat, lng, ts, memberId]   self-pruning (1 per type per member), no numeric cap
    i/                                      was "indicators" — enemy + environment only
      {indicatorId}: [type_code, lat, lng, ts, memberId]   shares the room's `mti` cap
    # meta/ wrapper, flat legacy mirror, uts (updatedAt): REMOVED entirely (see below)
```

`database.rules.json` must mirror this: top-level `rooms`→`r`, `telemetry`→`p`, `tactical`→`t`;
nested `members`→`m`, `indicators`→`i`, new `o` sibling with the same shape as `i`; `meta` rule
removed entirely; `.indexOn` list removed entirely (confirmed unused — no query anywhere in the
app orders/filters by any indexed field).

**No backwards-compatibility shims anywhere in this pass** — an app build on the old schema and
one on the new schema cannot interoperate (different Firebase locations entirely, not just a
formatting mismatch). Accepted for this project's scale; all clients (phone app, watch
companion, Python simulator) must ship together.

## 1. Room ID: PIN-derived padding

**`roomId` = 4-12 char user-entered name + padding derived from the PIN, filling the remainder
to a fixed 16 chars total** (e.g. a 4-char name gets 12 chars of padding; a 12-char name gets
4), matching the existing `$roomId.length <= 16` rule (kept unchanged — extending it costs wire
bytes on every packet and requires a rules migration).

This replaces an earlier random-salt design. PIN-derived padding means a joiner's client can
recompute the exact room id locally from the same (name, PIN) they already type — nobody has
to relay or manually type extra characters. This requires the PIN to be **mandatory, 4-16
characters** (see §2) — a PIN-less room would have nothing to derive padding from.

```swift
// FirebaseSyncManager.swift, next to hashPin
public static func deriveRoomPadding(pin: String, name: String, length: Int = 4) -> String {
    let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    let combined = "roompad:\(name):\(pin)"
    let digest = Array(SHA256.hash(data: Data(combined.utf8)))
    return String(digest.prefix(length).map { alphabet[Int($0) % alphabet.count] })
}
```

- **Domain-separated** from `hashPin`'s own combined-string format (`"\(salt):\(trimmed)"`) via
  the `"roompad:"` prefix, so this derivation and the PIN-verification hash never share
  identical input even though both hash the same PIN.
- **Alphabet: plain Crockford Base32 (32 symbols), the same alphabet used everywhere else in
  the app** for member ids and indicator ids (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` — excludes
  `0`/`O`, `1`/`I`/`L` for readability). An earlier draft of this section used an extended
  41-symbol alphabet (32-symbol Crockford plus 9 extra characters) to maximize entropy per
  character. Reverted: once the padding became PIN-derived rather than randomly generated, the
  real entropy ceiling is set by the PIN's own low entropy (a 4-digit minimum PIN yields only
  ~13.3 bits, see below) — a larger mapping alphabet doesn't meaningfully improve security
  against that ceiling, so it wasn't worth introducing a second, bespoke character set (with
  its own RTDB-safety/JSON-escaping/visual-confusability exclusion list) alongside the one
  already used for every other id in the app. Standardize on Crockford Base32 everywhere.
- Every character is uppercase-only, because the room id is `.uppercased()` at every call
  site — a mixed-case alphabet would silently collapse and waste entropy.
- **Collision handling:** no change needed. `FirebaseSyncManager.createRoom` already reads
  before writing and fails with `.roomAlreadyExists` if the computed id is taken — two hosts
  landing on the same derived id (same name + PIN) get a normal rejection, not a silent
  overwrite.
- **Accepted entropy tradeoff:** the PIN field is numeric-only, so a 4-digit minimum PIN
  yields only 10,000 possible derivations (~13.3 bits) — weaker than a dedicated random salt
  would have been. Deliberate, accepted tradeoff for the UX win of not relaying extra
  characters. Revisit only if allowing alphanumeric PINs becomes desirable.
- **Versioning caveat:** manual join (no QR) requires the joiner's app to run the *same*
  derivation algorithm as the host's. If this function ever changes, differing app versions
  compute different ids for the same (name, PIN) and fail to find each other. QR-based join is
  unaffected — it carries the final id directly, not the ingredients.

### `hostRoom` / `joinRoom` changes

- `hostRoom`: `let squadId = cleanedName + FirebaseSyncManager.deriveRoomPadding(pin: cleanedPin!, name: cleanedName)`. `passHash = FirebaseSyncManager.hashPin(cleanedPin!, salt: squadId)` unchanged (already uses the final `squadId`). `savedRoomName` stays the plain typed name — do NOT set it to the full `squadId` (see UI note below).
- `joinRoom`: the `id` parameter is now the plain (≤12-char) name, not the full room id — truncate/uppercase to `maxRoomNameEntryLength` (12), not `maxRoomNameLength` (16). Compute `cleanId = truncatedName + deriveRoomPadding(pin: cleanedPin!, name: truncatedName)` and pass that to `firebaseManager.joinRoom`. `savedRoomName` stays the plain typed name.
- **UI note:** `savedRoomName` deliberately stays unsalted. `SquadLobbyView`'s `Text(room.id)` and both `JoinQRBox` call sites already read from `activeRoom?.id` directly (not `savedRoomName`), so they show the correct full id automatically with no plumbing changes. Setting `savedRoomName` to the 16-char id would actually get corrupted: `CreateRoomView`'s `onChange(of: gameState.savedRoomName)` mirrors it into a local field, which re-triggers its own truncate-to-12 `onChange`, silently mangling it back to 12 characters.
- **QR join stays as-is** — `QRJoinPayload` continues to carry whatever `activeRoom?.id` is (the full derived id), sidestepping the versioning caveat for that path.
- **A wrong PIN now looks like `roomNotFound`, not `incorrectPin`** — since the derived id itself is wrong if the PIN is wrong, the room simply isn't found. This is a UX-visible behavior change from today (worth a note in the join-error copy if it's confusing in testing).

## 2. Validation: mandatory PIN, name/PIN length ranges, button-gating not error states

- **Room name: 4-12 characters required** (today only a max of 12 is enforced).
- **PIN: 4-16 characters required, mandatory** (today optional, no minimum).

No new `FirebaseSyncError` cases, no error-flag plumbing for these ranges. Instead:
- **Disable the Host/Join button** until both fields are in range.
- **Red-highlight the out-of-range field** in real time (the moment it's out of range, not
  just on submit) — reusing `SettingsView`'s existing `.foregroundColor(invalid ? .red : ...)`
  + `.listRowBackground(invalid ? Color.red.opacity(0.18) : nil)` treatment, but driven by
  local computed properties (`nameLengthValid`, `pinLengthValid`), not the shared
  `gameState.squadNameError`/`pinError` flags (those stay reserved for server-round-trip
  failures — duplicate name, wrong pin, room-already-exists — reusing them here would conflate
  "too short while typing" with "the server rejected this").
- Don't redden an untouched empty field — only once the user has typed something out of range.
- `hostRoom`/`joinRoom` keep their existing empty-string guards as a defensive backstop for
  non-UI callers (QR import, companion adoption) but gain no new length-check error branches —
  button-gating is the actual enforcement point.
- Placeholders become brief and inclusive of the limits: `"Squad Name (4-12)"`,
  `"PIN (4-16)"` — replacing `"Squad Name"` / `"Squad PIN (up to 16 digits, optional)"` in both
  `CreateRoomView` and `RoomDiscoveryView`.

## 3. `isHost` → `role`

`SquadMember.isHost: Bool` is redundant with the room-level `hostId` (never reassigned) —
evidenced by `GameStateManager` having to `OR` the two together (`room.hostId == memberId ||
member.isHost == true`) as a defensive fallback. Replace with a real persisted per-member
`role: MemberRole` field (not computed/derived), for future role expansion beyond host/not-host:

```swift
public enum MemberRole: String, Codable {
    case player
    case leader
}
```

- The host assigns himself `.leader` at creation time (same moment `isHost: true` is set
  today); no reassignment UI exists yet.
- Mechanical rename: every `isHost: true`/`false` literal → `role: .leader`/`.player`; every
  `member.isHost` read → `member.role == .leader`; every raw-dictionary spot (`"isHost":
  member.isHost`, `memberData["isHost"] as? Bool`) → the `role` equivalent
  (`member.role.rawValue`, `MemberRole(rawValue: ...) ?? .player`).
- **Not part of this rename:** `FirebaseSyncManager.leaveRoom(isHost: Bool, ...)` — that
  parameter tells `leaveRoom` whether *this departure* should disband the room, unrelated to
  the `SquadMember` model field. Leave it named as-is.
- The defensive-OR in `GameStateManager` keeps the same shape, just on the new field:
  `room.hostId == memberId || (room.members[memberId]?.role == .leader)`.
- ~25 test occurrences in `RadarMapTests.swift` need the same mechanical rename (compiler
  errors will catch most, since the property no longer exists).

### Map annotation icon selection

The only live icon-selection-by-host-status code (`MemberAnnotationView`) is an
`if member.isHost { SquadLeaderShape } else { SquadPlayerShape }` block. Replace with a
`switch member.role`, with `default:` falling back to the player-style marker — so an
unhandled future role renders correctly (not a compile error, not a mis-render) until someone
adds a dedicated `case` + shape for it:

```swift
@ViewBuilder
private var roleMarker: some View {
    let markers = AppConstants.UI.MapMarkers.self
    switch member.role {
    case .leader:
        // ...SquadLeaderShape, unchanged from today's isHost-true branch...
    default: // .player, and any future role without a dedicated icon yet
        // ...SquadPlayerShape, unchanged from today's isHost-false branch...
    }
}
```

(`SquadTacticalIcons.swift`'s `leaderSprite`/`playerSprite` functions are confirmed unused dead
code today — not called from any map view. Out of scope, but would need the same
switch-with-default treatment if ever wired up.)

## 4. Short IDs everywhere, not just member IDs

Audited every place a fresh id gets generated or defaulted:

- **`TacticalIndicator.init`'s default `id: String = UUID().uuidString` — real gap.** Every
  placed waypoint/callout gets a 36-char id via this default (`placeTacticalIndicator`
  constructs every indicator without passing `id:`), used directly as the RTDB path key.
  Tactical indicators are placed repeatedly during live gameplay — a hotter path than the one
  `generateShortMemberId` was built for. Fix: `id: String =
  GameStateManager.generateShortMemberId()` — a Model referencing a Manager's static func is a
  minor layering wrinkle, not worth a new shared-utility type for a single-project codebase.
- **`SquadMember.init`'s default `id: String = UUID().uuidString` — latent footgun, currently
  unused** (every real call site already passes an explicit `id:`). Same fix, for consistency.
- **Correctness gap, found while auditing the decode paths (unrelated to length):**
  `SquadRoom`'s custom decoder already self-heals a mismatched member id (rebuilds any member
  whose decoded `.id` disagrees with its own dictionary key). But
  `FirebaseSyncManager`'s per-member fetch-and-merge path (`fetchSingleMemberIfNeeded` or
  similar) decodes a standalone `SquadMember` via `JSONDecoder().decode(SquadMember.self,
  from:)` and stores it under `cleanMemberId` with **no equivalent correction**. Fix: extract
  the correction logic once (e.g. `SquadMember.correctingId(to:)`, returning a copy with `id`
  replaced only when it differs — `id` is a `let`, so this must reconstruct, not mutate) and
  use it at both call sites.

## 5. Shortened RTDB path segments and leaf field aliases

Every network call already funnels through the path-builder functions in
`FirebaseSyncManager.swift` (~line 1605), so the rename is a single-point-of-change:

| Segment | New | Notes |
|---|---|---|
| `rooms` (top-level) | `r` | |
| `telemetry` (top-level) | `p` | |
| `tactical` (top-level) | `t` | |
| `members` (under `r/{roomId}`) | `m` | must match `roomMemberPath`'s own segment |
| `indicators` (under `t/{roomId}`) | `i` | now enemy+environment only, see §6 |
| *(new)* | `o` | squad orders, split out of `indicators`, see §6 |
| `meta` (under `t/{roomId}`) | *(removed)* | see §7 |

**Leaf field aliases** — reuse `AppConstants.MetadataKeys`, a complete short-key scheme already
drafted in the codebase but never wired in anywhere (confirmed zero uses outside its own
declaration): `memberId="mid"`, `callsign="csn"`, `maxCapacity="cap"`, `pinHash="pin"`,
`expireAt="exp"`. (`isHost="hst"` is repurposed — see below. `createdAt`/`updatedAt`/
`lastActivity` aliases become moot since those fields are deleted, §7.)

**`SquadMember.swift` final `CodingKeys`** (only `id`/`callsign`/`role` are ever actually
written — the roster `encode(to:)` deliberately excludes telemetry fields):
```swift
private enum CodingKeys: String, CodingKey {
    case id = "mid"
    case callsign = "csn"
    case role = "rol"
    case latitude, longitude, altitude, heading, heartRate, batteryLevel, lastUpdatedTimestamp, sequenceNumber, status, colorHex
}
```

**`SquadRoom.swift` final `CodingKeys`:**
```swift
private enum CodingKeys: String, CodingKey {
    case id, members
    case hostId = "hst"
    case maxCapacity = "cap"
    case maxTacticalIndicators = "mti"
    case pinHash = "pin"
    case expireAt = "exp"
}
```
- `id` stays full-length (worth keeping human-readable for console debugging).
- `hostId` → `"hst"` — **not** left full-length as might seem natural: `functions/index.js`'s
  `cleanupEmptyRoom` already reads `roomVal.hst || roomVal.hostId`, i.e. it already expects
  `hst` to mean `hostId`. Since `isHost`/`role` doesn't need `hst` anymore, reassign it here to
  match what the Cloud Function already independently expects.
- `members` → must be `"m"` (not left full-length) — it has to match `roomMemberPath`'s own
  segment name, or a full-room fetch and an individual member-path write disagree about where
  the members subtree lives.
- **`indicators` is dropped from `SquadRoom`'s `Codable` representation entirely** (keep the
  Swift property, exclude it from `CodingKeys`/`encode`). It's always empty at room-creation
  time, so encoding it today writes a redundant, meaningless key under `r/{roomId}` that has
  nothing to do with the real indicator data at `t/{roomId}/o` and `t/{roomId}/i`. The
  in-memory field is populated separately by `applyTacticalSnapshot` merging the tactical
  fetch — a client-model convenience, not something that should round-trip through the room's
  own wire representation.
- `hasPin`, `createdAt`, `lastActivityTimestamp`: removed entirely, see §7.

## 6. Tactical indicators: two-tier cap, structural split (not code-filtering)

`TacticalIndicatorCategory` has three cases: `squadOrder`, `enemyIndicator`, `environment`.

1. **Squad orders — self-pruning, no shared count.** `placeTacticalIndicator` already removes
   any existing indicator of the same type placed by the same member before placing a new one
   — each member has at most one `goHere`, one `flag`, etc. Leave this logic exactly as-is.
2. **Everything else (enemy + environment) — one shared numeric cap** (`mti`: 0 free / 20 pro,
   computed at room creation the same way `maxCapacity` already is).

Storage is split into two sibling branches so which tier something belongs to is which branch
it's written under, not something a reader has to compute by inspecting type codes:
- `t/{roomId}/o` — squad orders, never touched by the cap-enforcement Cloud Function.
- `t/{roomId}/i` — enemy + environment, shares the `mti` cap.

### Bug in the current design, motivating this move to a Cloud Function

`enforceHostTacticalIndicatorMaintenance` (the only thing that prunes expired/overflow
indicators today) is gated on `guard isHosting`, called from exactly one place: right after the
*host's own* `placeTacticalIndicator` call. If a non-host member places the marker that pushes
the room over the cap, nothing prunes it until the host happens to place a marker of their own
— if the host never does that session, overflow/expired markers accumulate indefinitely.

### New Cloud Function — trivial once the branches are split, no type-code filtering needed

```javascript
exports.pruneExcessTacticalIndicators = functions.database
  .ref("/t/{roomId}/i/{indicatorId}")
  .onWrite(async (change, context) => {
    if (!change.after.exists()) return null;  // ignore deletes
    const roomId = context.params.roomId;

    // Adjustable cap, stored per-room (same pattern as maxCapacity), not hardcoded/global.
    const roomSnap = await db.ref(`/r/${roomId}`).once("value");
    const roomVal = roomSnap.val() || {};
    const MAX_TACTICAL = roomVal.mti !== undefined ? Number(roomVal.mti) : 20;

    const snap = await db.ref(`/t/${roomId}/i`).once("value");
    if (!snap.exists() || snap.numChildren() <= MAX_TACTICAL) return null;

    const entries = [];
    snap.forEach((child) => {
      const arr = child.val(); // [type_code, lat, lon, ts, placedByMemberId]
      const ts = Array.isArray(arr) ? arr[3] : arr["3"];
      entries.push({ id: child.key, ts: Number(ts) });
    });

    entries.sort((a, b) => a.ts - b.ts);
    const overflow = entries.slice(0, entries.length - MAX_TACTICAL);
    const updates = {};
    overflow.forEach((e) => { updates[`/t/${roomId}/i/${e.id}`] = null; });
    await db.ref().update(updates);
    logger.info(`Pruned ${overflow.length} excess tactical indicator(s) in room ${roomId}.`);
    return null;
  });
```

No type-code set to maintain — every child under `i` counts, full stop. A new enemy or
environment type added later needs zero Cloud Function change; only a brand-new *category* that
shouldn't share this cap would need attention here.

### Swift-side changes to produce the split

- `tacticalIndicatorPath(roomId:indicatorId:)` becomes two builders: `tacticalOrderPath` (→
  `t/{roomId}/o/{id}`) and `tacticalCappedIndicatorPath` (→ `t/{roomId}/i/{id}`).
- `publishIndicatorToFirebase` picks the path based on `indicator.type.category == .squadOrder`.
- `deleteIndicatorFromFirebase` only has an id at the call site, not a category — issue the
  delete against **both** `o` and `i` paths unconditionally (deleting a path that doesn't have
  that id is a harmless no-op), rather than adding a lookup step purely to route a delete.
- `applyTacticalSnapshot` reads **both** `json["o"]` and `json["i"]`, merging into the same
  `decodedIndicators` dictionary. The Swift-side model (`SquadRoom.indicators`) stays a single
  unified dictionary — the branch split is a wire-organization detail, not a client-model
  change.
- **Bonus dead-code bug found while touching this area:** the member-departure cleanup (in
  `FirebaseSyncManager`, removes a departing member's own squad-order markers) expects each
  indicator as a `[String: Any]` dictionary with `"placedByMemberId"`/`"type"`/`"category"`
  keys — but real indicators are the compact array format everywhere else, so this guard
  silently fails for every real indicator today. Fix while touching this area: read `t/{roomId}/o`
  directly, filter entries where `arr[4] == memberId`, delete matches — no dictionary-shaped
  guard, no category/type string matching needed.
- `database.rules.json`'s `tactical.$roomId.indicators` rule needs a sibling `o` rule, same
  shape.
- The existing `tacticalLegacyIndicatorPath`/`$legacyIndicatorId` flat-format fallback (predates
  the `indicators` subtree entirely) doesn't map onto a two-branch split — drop it rather than
  extending it to a third format.
- `enforceHostTacticalIndicatorMaintenance` simplifies: drop the `isHosting`-gated
  remote-deletion logic for both the expiry sweep and the tier-2 cap eviction (the Cloud
  Function's job now); leave the squad-order self-pruning untouched; keep only the immediate
  local removal from `localIndicators` for instant UI feedback (filter on "not squadOrder"
  instead of "is enemyIndicator").

### New constants

`AppConstants.Subscription.freeTierMaxTacticalIndicators = 0`,
`proTierMaxTacticalIndicators = 20`. Free tier getting `0` isn't a new restriction —
`placeTacticalIndicator` already gates *all* indicator placement (every category) behind
`hasUnlimitedSquadUnlock`; a free-tier host can't place any tactical marker today regardless.

## 7. Room payload field removals

- **`hasPin` — deleted entirely.** `hasPin == (pinHash != nil)` always, by construction
  (nothing ever sets them independently). Now that the PIN is mandatory (§2), `hasPin` would
  become a compile-time constant `true`. `pinHash` becomes non-optional (`String`, not
  `String?`). `if room.hasPin { ... }` call sites (PIN verification, `SquadLobbyView` display)
  run unconditionally.
- **`lastActivityTimestamp` — fully dead code, not just unused.** `SquadRoom.isIdle(...)` is
  the only thing that reads it meaningfully, and `isIdle` is never called anywhere.
  `FirebaseSyncManager.touchRoomActivity(roomId:)`, the one thing that would keep it fresh, is
  also never called. It's written once at creation (copying `createdAt`) and never touched
  again. Delete the field, `isIdle()`, `touchRoomActivity()`, and `roomLastActivityPath()` —
  superseded by §8's TTL refresh design.
- **`createdAt` — removed from the wire entirely**, not just aliased. Its only real consumer
  was seeding `expireAt`'s initial default at creation time; nothing else reads it (no `Views/`
  hits, no `GameStateManager` hits). `database.rules.json`'s `.indexOn` list (which includes
  `createdAt`) is confirmed entirely unused — no `queryOrdered`/`orderByChild` call exists
  anywhere in the app. Compute the initial `expireAt` inline at both construction sites
  (`Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds`) instead
  of round-tripping through a stored field.
- **`maxCapacity` pro-tier cap: 999 → 12.** Free tier stays 4. (The 8-char/40-bit member id was
  explicitly sized for the old 999-member birthday-bound case; confirmed this session that 8
  chars stays as the chosen length even with the real cap now 12 — not revisiting further.)

### Test impact

`testSevenDayIdleRoomDetectionAndSchema` exercises exactly the dead code being removed here
(`isIdle()`, `lastActivityTimestamp` encode/decode) — delete it, replace with coverage of the
new hourly-refresh `expireAt` behavior (§8). A test asserting `expireAt` defaults to
`createdAt + 7 days` needs updating for both the idle-cutoff change (7 days → 12h) and
`createdAt`'s removal.

## 8. TTL refresh: 12-hour idle cutoff, hourly host refresh

**Idle cutoff: 7 days → 12 hours.**
```swift
public enum Inactivity {
    public static let idleCutoffHours: Double = 12.0
    public static let secondsPerHour: Double = 3600.0
    public static let ttlDurationSeconds: TimeInterval = idleCutoffHours * secondsPerHour
}
```

**Refresh: host writes a fresh `exp` to all three top-level trees, at most once per hour.**
```swift
public func refreshRoomExpiry(roomId: String) {
    let newExpireAt = Date().timeIntervalSince1970 + AppConstants.Timing.Inactivity.ttlDurationSeconds
    transport.setValue(newExpireAt, at: roomExpireAtPath(roomId: roomId), completion: nil)
    transport.setValue(newExpireAt, at: telemetryExpireAtPath(roomId: roomId), completion: nil)
    transport.setValue(newExpireAt, at: tacticalExpPath(roomId: roomId), completion: nil)
}
```
- Not server-enforced — `database.rules.json`'s write rule doesn't distinguish host from any
  other member (matching how other host-only actions already rely on client-side
  `isCurrentMemberHost` gating, not a rules-level restriction). Gate the call on
  `isCurrentMemberHost` client-side; integrate the once-per-hour cadence into whatever periodic
  mechanism already runs on the host during an active session — exact integration point is an
  implementation-time decision.
- Room-creation's TTL payload collapses to a single write per tree: `transport.setValue(["exp":
  initialExpireAt], at: tacticalPath(roomId: cleanId))` for the tactical side (was two writes,
  to `tacticalMetaPath` and `tacticalPath` both).
- An idle/abandoned room now dies within 12h. An **actively hosted** room can be kept alive
  indefinitely via hourly refresh — exposure time for an active room is unbounded, which is why
  the room-id entropy (§1) was sized conservatively rather than against the 12h figure alone.

### `meta`/`updatedAt` removed entirely — not just relocated

`meta/` (and the flat legacy mirror alongside it) existed only because indicators used to live
flat, sharing the same namespace as metadata fields (`updatedAt`/`expireAt`), requiring a
`metadataKeys` exclusion set to tell them apart when iterating. Once indicators move into their
own `o`/`i` branches (§6), that collision is structurally impossible — nothing at the top level
of `t/{roomId}` is ever an indicator, so metadata lives flat with no wrapper needed. Delete
`tacticalMetaPath`, `tacticalMetaUpdatedAtPath`, `tacticalLegacyUpdatedAtPath`,
`tacticalLegacyIndicatorPath`, and the `metadataKeys` exclusion sets at both call sites
(`applyTacticalSnapshot`, the member-departure cleanup).

`uts` (`updatedAt`) itself is also removed, not just relocated to a flat key — see §9.

## 9. Remove redundant REST-style polling — trust the SDK's real-time listeners

The app already relies on the Firebase SDK's persistent `.observe()` listeners
(`attachRealtimeListeners`), which fire immediately on attachment with the current state, then
again on every subsequent change, and auto-resync after reconnect — a core SDK guarantee, not
something requiring a defensive re-check. Several manual REST-style fetches sitting alongside
these listeners are leftovers from before the SDK migration (confirmed by the code's own doc
comment: `startTelemetryPolling`'s persistent listeners "replace the old REST polling timer").

- **`uts` (`updatedAt`) removed entirely.** Its only consumer, `fetchTacticalIndicatorsIfChanged`,
  compared it to `lastKnownTacticalUpdatedAt` to decide whether to do a full re-fetch — a
  poll-and-compare optimization the always-attached `.observe(.value)` listener already makes
  unnecessary (it gets the full snapshot pushed in real time regardless). The telemetry fetch
  right next to this one in the same function does an unconditional fetch with no equivalent
  check, so the optimization wasn't even applied consistently. Delete `uts`,
  `lastKnownTacticalUpdatedAt`, `touchTacticalUpdatedAt`; make `fetchTacticalIndicatorsIfChanged`
  an unconditional fetch (rename to drop the now-inaccurate "IfChanged" if desired).
- **Delete the 5-second throttled tactical poll inside `fetchRemoteTelemetry`** — redundant
  with the always-attached listeners once a session is active.
- **Delete the "instant initial fetch" calls in `startTelemetryPolling`** —
  `attachRealtimeListeners`'s own first callback firing already delivers the same initial state.
- **`triggerWakeBurst()` drops its `fetchRemoteTelemetry(roomId:)` call.** `handleAppSuspend`
  never detaches the listeners, so the phone's locally-held state is already current via the
  SDK regardless of what the watch is doing; re-fetching from Firebase just to relay to the
  watch is a redundant round-trip through data the phone already has in memory. Keep
  `setWristActive(true)` — that's a state flag, not a poll.
- **Check `WatchConnectivityManager` during implementation:** if the watch needs an explicit
  "send me current state now" nudge independent of Firebase freshness, that belongs as a direct
  relay call using the phone's already-current local state, not a Firebase re-fetch — verify
  such a call exists or needs adding so the watch doesn't lose its wake-nudge behavior.
  **Hard constraint: do not touch `WatchConnectivityManager`'s independent "Convergence &
  Rolling sync_ts" phone↔watch state-reconciliation protocol.** Any watch-relay fix must work
  *within* that existing mechanism, not modify, bypass, or replace it.

## 10. Cloud Functions (`functions/index.js`) — must move in lockstep

- **`cleanExpiredRooms`** (hourly) — already queries `orderByChild("exp")` first with a legacy
  `orderByChild("expireAt")` fallback scan; no logic change needed once the client writes `exp`
  as primary. **But hardcodes `/rooms`, `/tactical`, `/telemetry`** — must become `/r`, `/t`,
  `/p`, or this function silently stops finding/deleting anything.
- **`cleanupEmptyRoom`** — triggered on `/rooms/{roomId}/members` writes (→
  `/r/{roomId}/m`); also hardcodes the old top-level paths. Already reads `roomVal.hst ||
  roomVal.hostId` — this is *why* `hostId` is aliased to `hst` in §5, not left full-length.
- **`scheduledDailyCleanup`** — a separate daily 7-day-idle sweep reading
  `ats`/`lastActivityTimestamp`/`cts`/`createdAt`. Once those fields are deleted from the wire
  (§7), every read returns `undefined` and this function silently stops catching idle-but-
  non-empty rooms. **Delete this function entirely** — `cleanExpiredRooms` (hourly, `exp`-based)
  fully supersedes it once the 12-hour-cutoff/hourly-refresh design (§8) is live.
- **New: `pruneExcessTacticalIndicators`** — see §6.

## 11. `notebooks/player_simulator.py` — must move in lockstep

Independent REST-API test client (~1133 lines) that writes the same schema by hand. Every
change above needs a mirror here:
- Top-level paths (`"rooms/{room_name}/..."` etc.) → `/r`, `/t`, `/p`.
- Member/indicator ids already 8 chars (`sim_{uuid4().hex[:8]}`) — right length, different
  alphabet (hex vs. Crockford); not a compatibility problem, optional to match exactly.
- `"isHost": True/False` → `"role": "leader"/"player"`.
- Stop writing `hasPin`, `createdAt`, `lastActivityTimestamp`; PIN becomes a mandatory,
  always-supplied argument (min 4 chars), `pinHash` write becomes unconditional.
- Room hosting needs the same name + PIN-derived-padding-to-16-chars scheme
  (`deriveRoomPadding`'s SHA256 logic), or the simulator can't interoperate with rooms the real
  app creates and vice versa.
- `PRO_TIER_MAX_CAPACITY = 999` → `12`.
- The `lastActivityTimestamp`-touch call (mirrors the dead `touchRoomActivity`) → replace with
  the new hourly `refreshRoomExpiry`-equivalent, writing a fresh `exp` to all relevant
  locations, so the simulator can keep a long-running room alive under the new 12h cutoff.
- `metadata_keys` filter set → drop the deleted long names, add the new short forms.
- Check `notebooks/player_simulation.ipynb` for any schema literals of its own (likely just
  calls into the `.py` module's classes).

## Implementation order (suggested)

1. `SquadMember`/`SquadRoom` model changes (§3, §5, §7) — `role`, `CodingKeys`/field removals,
   `maxTacticalIndicators`.
2. `deriveRoomPadding` + `hostRoom`/`joinRoom` changes (§1).
3. Path-builder renames in `FirebaseSyncManager` (§5, §6, §8) — segment renames, `o`/`i` split,
   `meta`/`uts` removal, TTL refresh method.
4. `database.rules.json` update (must ship together with step 3 — no dual-schema window).
5. UI validation (§2) in `CreateRoomView`/`RoomDiscoveryView`.
6. Map icon switch (§3).
7. Remove redundant polling (§9).
8. `functions/index.js` changes (§10) — deploy alongside the schema changes.
9. `notebooks/player_simulator.py` changes (§11).
10. Test suite updates throughout (`RadarMapTests.swift`).

## Verification

- Build and run the app. Host a room with a 4+ digit PIN; confirm hosting with no PIN or a
  <4-digit PIN leaves the Host button disabled and the PIN field red.
- Confirm the hosted room's id is always 16 characters: the typed name followed by enough
  Crockford Base32 padding characters to fill the remainder (e.g. 12 padding chars for a 4-char
  name, 4 for a 12-char name).
- From a second device/simulator, join using only the plain name + the same PIN (no full id
  needed) and confirm it locates and joins the correct room.
- Scan the host's QR code from a second device and confirm it still joins correctly.
- Confirm an incorrect PIN with the correct name fails as `roomNotFound` (not `incorrectPin` —
  a deliberate, subtle behavior change from today).
- Place more than 20 enemy/environment indicators in a pro-tier room; confirm the oldest are
  pruned via the new Cloud Function (may take a moment for the function to fire).
- Confirm squad orders (e.g. `goHere`) still self-prune to one per member per type, unaffected
  by the tactical cap.
- Run `RadarMapTests` and confirm updated/added tests pass.
- Deploy `functions/index.js` and `database.rules.json` together with the app change — verify
  `cleanExpiredRooms` and `pruneExcessTacticalIndicators` fire correctly against the new paths.
