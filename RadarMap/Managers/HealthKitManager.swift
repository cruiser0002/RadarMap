import Foundation
import Combine
#if canImport(HealthKit)
import HealthKit
#endif

public final class HealthKitManager: NSObject, ObservableObject {
    @Published public var currentHeartRate: Double = AppConstants.Health.defaultRestingHeartRate
    @Published public var isSessionActive: Bool = false
    /// Share-side authorization only — HealthKit deliberately never exposes read-side grant/deny
    /// status. Workout share is requested in the same call as heart rate read, so this is the
    /// closest available proxy for "did the user allow HealthKit access." Not meaningful on iOS,
    /// where this app never touches HealthKit directly.
    #if os(watchOS)
    @Published public var authorizationStatus: HKAuthorizationStatus = .notDetermined
    #else
    @Published public var authorizationStatus: HKAuthorizationStatus = .sharingAuthorized
    #endif

    #if os(watchOS)
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    #endif

    public override init() {
        super.init()
        #if os(watchOS)
        if HKHealthStore.isHealthDataAvailable() {
            authorizationStatus = healthStore.authorizationStatus(for: HKObjectType.workoutType())
            if authorizationStatus == .sharingAuthorized {
                queryLatestHeartRateSample()
            }
        }
        #endif
    }

    public func queryLatestHeartRateSample() {
        #if os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
            let value = sample.quantity.doubleValue(for: heartRateUnit)
            if value > 0 {
                DispatchQueue.main.async {
                    self?.currentHeartRate = value
                }
            }
        }
        healthStore.execute(query)
        #endif
    }

    public func requestAuthorization(completion: @escaping (Bool) -> Void = { _ in }) {
        #if os(watchOS)
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }

        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let typesToRead: Set<HKObjectType> = [heartRateType]
        let typesToShare: Set<HKSampleType> = [
            HKObjectType.workoutType()
        ]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(success)
                    return
                }
                self.authorizationStatus = self.healthStore.authorizationStatus(for: HKObjectType.workoutType())
                if success {
                    self.queryLatestHeartRateSample()
                }
                completion(success)
            }
        }
        #else
        // Mock fallback for simulator/host tests
        DispatchQueue.main.async {
            completion(true)
        }
        #endif
    }
    
    public func startLiveHeartRateSession() {
        #if os(watchOS)
        guard HKHealthStore.isHealthDataAvailable(), workoutSession == nil else { return }
        
        let workoutConfig = HKWorkoutConfiguration()
        workoutConfig.activityType = .other
        workoutConfig.locationType = .indoor
        
        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: workoutConfig)
            workoutBuilder = workoutSession?.associatedWorkoutBuilder()
            
            workoutSession?.delegate = self
            workoutBuilder?.delegate = self
            let liveDataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: workoutConfig)
            if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                liveDataSource.enableCollection(for: heartRateType, predicate: nil)
            }
            workoutBuilder?.dataSource = liveDataSource
            
            let startDate = Date()
            workoutSession?.startActivity(with: startDate)
            
            if #available(watchOS 10.0, *) {
                workoutSession?.startMirroringToCompanionDevice { success, error in
                    if let error = error {
                        print("[HealthKitManager] Companion mirroring error: \(error.localizedDescription)")
                    } else {
                        print("[HealthKitManager] Companion mirroring active: \(success)")
                    }
                }
            }
            
            workoutBuilder?.beginCollection(withStart: startDate) { [weak self] success, error in
                DispatchQueue.main.async {
                    self?.isSessionActive = success
                }
            }
        } catch {
            print("[HealthKitManager] Error starting workout session: \(error.localizedDescription)")
        }
        #else
        isSessionActive = true
        currentHeartRate = AppConstants.Health.mockWorkoutHeartRate
        #endif
    }
    
    public func pauseLiveHeartRateSession() {
        #if os(watchOS)
        guard let session = workoutSession, session.state == .running else { return }
        session.pause()
        #else
        isSessionActive = false
        #endif
    }
    
    public func resumeLiveHeartRateSession() {
        #if os(watchOS)
        guard let session = workoutSession else {
            startLiveHeartRateSession()
            return
        }
        if session.state == .paused {
            session.resume()
        }
        #else
        isSessionActive = true
        #endif
    }
    
    public func stopLiveHeartRateSession() {
        #if os(watchOS)
        guard let session = workoutSession else { return }
        session.end()
        workoutBuilder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            self?.workoutBuilder?.finishWorkout { _, _ in
                DispatchQueue.main.async {
                    self?.workoutSession = nil
                    self?.workoutBuilder = nil
                    self?.isSessionActive = false
                }
            }
        }
        #else
        isSessionActive = false
        #endif
    }
}

#if os(watchOS)
extension HealthKitManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    public func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            self.isSessionActive = (toState == .running)
        }
    }
    
    public func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[HealthKitManager] Workout session failed: \(error.localizedDescription)")
    }
    
    public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) { }
    
    public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        guard collectedTypes.contains(heartRateType) else { return }
        
        if let statistics = workoutBuilder.statistics(for: heartRateType) {
            let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
            if let value = statistics.mostRecentQuantity()?.doubleValue(for: heartRateUnit) {
                DispatchQueue.main.async {
                    self.currentHeartRate = value
                }
            }
        }
    }
}
#endif
