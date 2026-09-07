import Foundation
@testable import RadarMap

/// Test double for `RTDBTransport`, replacing the old `MockURLProtocol`-based REST interception
/// now that `FirebaseSyncManager` talks to the `FirebaseDatabase` SDK instead of `URLSession`
/// (the SDK never routes through `URLSession`, so that interception point no longer exists).
///
/// Storage is a real path tree (not a flat path->value map), so a `getValue`/`.value` read at an
/// ancestor path correctly returns the merged subtree of everything written at descendant paths —
/// mirroring how Realtime Database actually behaves, and matching how the production code reads
/// whole nodes (e.g. `t/{roomId}`) after writes to their children
/// (e.g. `t/{roomId}/i/{id}`).
final class MockRTDBTransport: RTDBTransport {
    // MARK: - Storage

    private var root: [String: Any] = [:]

    /// Paths where get/set/remove should simulate failure (nil / false completion), e.g. to
    /// simulate a permission-denied or offline write.
    var failingPaths: Set<String> = []

    private(set) var recordedGets: [String] = []
    private(set) var recordedSets: [(path: String, value: Any)] = []
    private(set) var recordedRemoves: [String] = []

    private struct Observer {
        let path: String
        let eventType: RTDBEventType
        let handler: (RTDBSnapshot) -> Void
    }
    private var observers: [RTDBObserverHandle: Observer] = [:]
    private(set) var recordedObservedPaths: [(path: String, eventType: RTDBEventType)] = []
    private var nextHandle: RTDBObserverHandle = 1

    /// Count of currently-attached observers (attach/detach aware, unlike the append-only
    /// `recordedObservedPaths` log) — used by tests asserting Listener-gate attach/detach state.
    var activeObserverCount: Int { observers.count }

    func reset() {
        root.removeAll()
        failingPaths.removeAll()
        recordedGets.removeAll()
        recordedSets.removeAll()
        recordedRemoves.removeAll()
        recordedObservedPaths.removeAll()
        observers.removeAll()
        nextHandle = 1
    }

    /// Seeds a value directly into storage without going through `setValue` (no completion, no
    /// observer notification) — useful for arranging a test's starting server state.
    func seed(_ value: Any, at path: String) {
        setNode(value, at: path)
    }

    // MARK: - Tree storage helpers

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func node(at path: String) -> Any? {
        var current: Any? = root
        for segment in Self.segments(path) {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[segment]
        }
        return current
    }

    private func setNode(_ value: Any, at path: String) {
        let segs = Self.segments(path)
        guard !segs.isEmpty else {
            if let dict = value as? [String: Any] { root = dict }
            return
        }
        root = Self.settingValue(value, in: root, segments: segs)
    }

    private static func settingValue(_ value: Any, in dict: [String: Any], segments: [String]) -> [String: Any] {
        var dict = dict
        guard let first = segments.first else { return dict }
        if segments.count == 1 {
            dict[first] = value
            return dict
        }
        let childDict = (dict[first] as? [String: Any]) ?? [:]
        dict[first] = settingValue(value, in: childDict, segments: Array(segments.dropFirst()))
        return dict
    }

    private func removeNode(at path: String) {
        let segs = Self.segments(path)
        guard !segs.isEmpty else { root = [:]; return }
        root = Self.removingValue(in: root, segments: segs)
    }

    private static func removingValue(in dict: [String: Any], segments: [String]) -> [String: Any] {
        var dict = dict
        guard let first = segments.first else { return dict }
        if segments.count == 1 {
            dict.removeValue(forKey: first)
            return dict
        }
        guard let childDict = dict[first] as? [String: Any] else { return dict }
        dict[first] = removingValue(in: childDict, segments: Array(segments.dropFirst()))
        return dict
    }

    // MARK: - RTDBTransport

    func getValue(at path: String, completion: @escaping (Any?) -> Void) {
        recordedGets.append(path)
        if failingPaths.contains(path) {
            completion(nil)
            return
        }
        completion(node(at: path))
    }

    func setValue(_ value: Any, at path: String, completion: ((Bool) -> Void)?) {
        recordedSets.append((path, value))
        if failingPaths.contains(path) {
            completion?(false)
            return
        }
        setNode(value, at: path)
        completion?(true)
        notifyObservers(changedPath: path)
    }

    func removeValue(at path: String, completion: ((Bool) -> Void)?) {
        recordedRemoves.append(path)
        if failingPaths.contains(path) {
            completion?(false)
            return
        }
        removeNode(at: path)
        completion?(true)
        notifyObservers(changedPath: path, removed: true)
    }

    @discardableResult
    func observe(at path: String, eventType: RTDBEventType, handler: @escaping (RTDBSnapshot) -> Void) -> RTDBObserverHandle {
        let handle = nextHandle
        nextHandle += 1
        observers[handle] = Observer(path: path, eventType: eventType, handler: handler)
        recordedObservedPaths.append((path, eventType))
        if eventType == .value {
            handler(MockSnapshot(key: Self.segments(path).last ?? path, value: node(at: path)))
        }
        return handle
    }

    func removeObserver(_ handle: RTDBObserverHandle) {
        observers.removeValue(forKey: handle)
    }

    /// Manually delivers an observer event, independent of a real setValue/removeValue call on
    /// this mock — for tests simulating a remote peer's write (or this device's own optimistic
    /// self-echo) arriving via a listener.
    func simulateEvent(at path: String, eventType: RTDBEventType, key: String, value: Any?) {
        for observer in observers.values where observer.path == path && observer.eventType == eventType {
            observer.handler(MockSnapshot(key: key, value: value))
        }
    }

    private func notifyObservers(changedPath: String, removed: Bool = false) {
        let changedSegments = Self.segments(changedPath)
        for observer in observers.values {
            let observerSegments = Self.segments(observer.path)

            if observer.path == changedPath {
                if observer.eventType == .value {
                    observer.handler(MockSnapshot(key: observerSegments.last ?? observer.path, value: node(at: observer.path)))
                }
                continue
            }

            guard changedSegments.count > observerSegments.count,
                  Array(changedSegments.prefix(observerSegments.count)) == observerSegments else { continue }

            switch observer.eventType {
            case .value:
                observer.handler(MockSnapshot(key: observerSegments.last ?? observer.path, value: node(at: observer.path)))
            case .childAdded, .childChanged:
                guard !removed else { continue }
                let childKey = changedSegments[observerSegments.count]
                let childPath = (observerSegments + [childKey]).joined(separator: "/")
                observer.handler(MockSnapshot(key: childKey, value: node(at: childPath)))
            case .childRemoved:
                guard removed else { continue }
                let childKey = changedSegments[observerSegments.count]
                let childPath = (observerSegments + [childKey]).joined(separator: "/")
                // Only fire once the whole child subtree is actually gone (handles both a direct
                // removal of the child itself, and removal of some deeper descendant leaving the
                // child empty).
                if node(at: childPath) == nil {
                    observer.handler(MockSnapshot(key: childKey, value: nil))
                }
            }
        }
    }

    private struct MockSnapshot: RTDBSnapshot {
        let key: String
        let value: Any?
    }
}
