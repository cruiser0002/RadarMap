import Foundation
import FirebaseCore
import FirebaseDatabase

/// Realtime Database event types this app subscribes to, mirroring `FirebaseDatabase.DataEventType`
/// without exposing the SDK type directly — keeps `FirebaseSyncManager` testable against a mock
/// transport that never links the SDK.
public enum RTDBEventType: Equatable {
    case value
    case childAdded
    case childChanged
    case childRemoved
}

/// A single Realtime Database node, as delivered to an `RTDBTransport.observe` handler.
public protocol RTDBSnapshot {
    /// The last path segment (e.g. a member ID or indicator ID for a child-scoped observer).
    var key: String { get }
    /// The decoded JSON-like value at this node (String/NSNumber/Dictionary/Array), or nil if absent.
    var value: Any? { get }
}

public typealias RTDBObserverHandle = UInt

/// Thin seam between `FirebaseSyncManager`'s app-level sync logic and the Realtime Database
/// transport. Production code talks to the real `FirebaseDatabase` SDK through
/// `FirebaseRTDBTransport`; tests inject an in-memory double conforming to the same protocol —
/// see `MockRTDBTransport` in RadarMapTests. Paths are plain RTDB paths (no ".json" suffix).
public protocol RTDBTransport: AnyObject {
    /// One-shot read. Delivers the decoded value, or nil if the path is empty or the read failed.
    func getValue(at path: String, completion: @escaping (Any?) -> Void)
    /// Writes `value` at `path`, replacing any existing content there.
    func setValue(_ value: Any, at path: String, completion: ((Bool) -> Void)?)
    /// Deletes the node at `path`.
    func removeValue(at path: String, completion: ((Bool) -> Void)?)
    /// Attaches a persistent listener at `path` for `eventType`. Fires once per matching event,
    /// including this device's own optimistic local echoes — callers are responsible for
    /// self-echo filtering (see FirebaseSyncManager's `localMemberId` checks).
    @discardableResult
    func observe(at path: String, eventType: RTDBEventType, handler: @escaping (RTDBSnapshot) -> Void) -> RTDBObserverHandle
    /// Detaches a previously-attached observer.
    func removeObserver(_ handle: RTDBObserverHandle)
}

// MARK: - Production Transport (FirebaseDatabase SDK)

/// `RTDBTransport` implementation backed by the real `FirebaseDatabase` SDK. All reads, writes,
/// and listeners for a given database URL are multiplexed by the SDK over one shared, persistent
/// connection (see CLOUD_DATA_MANAGEMENT.md §5.B/§5.C) — this class does not manage its own
/// networking, it only translates plain-path calls into `DatabaseReference` operations.
public final class FirebaseRTDBTransport: RTDBTransport {
    private let databaseURLProvider: () -> String
    private let lock = NSLock()
    private var observedRefsByHandle: [RTDBObserverHandle: DatabaseReference] = [:]

    public init(databaseURLProvider: @escaping () -> String) {
        self.databaseURLProvider = databaseURLProvider
    }

    private func reference(for path: String) -> DatabaseReference {
        Database.database(url: databaseURLProvider()).reference(withPath: path)
    }

    public func getValue(at path: String, completion: @escaping (Any?) -> Void) {
        reference(for: path).getData { error, snapshot in
            if error != nil {
                completion(nil)
                return
            }
            guard let snapshot = snapshot, snapshot.exists() else {
                completion(nil)
                return
            }
            completion(snapshot.value)
        }
    }

    public func setValue(_ value: Any, at path: String, completion: ((Bool) -> Void)?) {
        reference(for: path).setValue(value) { error, _ in
            completion?(error == nil)
        }
    }

    public func removeValue(at path: String, completion: ((Bool) -> Void)?) {
        reference(for: path).removeValue { error, _ in
            completion?(error == nil)
        }
    }

    @discardableResult
    public func observe(at path: String, eventType: RTDBEventType, handler: @escaping (RTDBSnapshot) -> Void) -> RTDBObserverHandle {
        let ref = reference(for: path)
        let handle = ref.observe(eventType.firebaseDataEventType) { snapshot in
            handler(FirebaseSnapshotWrapper(snapshot))
        }
        lock.lock()
        observedRefsByHandle[handle] = ref
        lock.unlock()
        return handle
    }

    public func removeObserver(_ handle: RTDBObserverHandle) {
        lock.lock()
        let ref = observedRefsByHandle.removeValue(forKey: handle)
        lock.unlock()
        ref?.removeObserver(withHandle: handle)
    }
}

private extension RTDBEventType {
    var firebaseDataEventType: DataEventType {
        switch self {
        case .value: return .value
        case .childAdded: return .childAdded
        case .childChanged: return .childChanged
        case .childRemoved: return .childRemoved
        }
    }
}

private struct FirebaseSnapshotWrapper: RTDBSnapshot {
    private let snapshot: DataSnapshot
    init(_ snapshot: DataSnapshot) { self.snapshot = snapshot }
    var key: String { snapshot.key }
    var value: Any? { snapshot.exists() ? snapshot.value : nil }
}
