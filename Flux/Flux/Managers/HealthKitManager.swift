import Foundation
import HealthKit
import SwiftUI

@Observable
final class HealthKitManager {
    private static var inFlightRecordIDs = Set<String>()
    let healthStore = HKHealthStore()
    var isAuthorized: Bool = false
    var todayActiveEnergyBurned: Double = 0.0
    var error: Error?
    private var isSyncing = false
    
    // Bug Prevention: Always check if HealthKit is available on the device (e.g., iPad might not have it in older OS)
    var isSupported: Bool {
        HKHealthStore.isHealthDataAvailable()
    }
    
    func requestAuthorization() async {
        guard isSupported else {
            print("HealthKit is not supported on this device.")
            return
        }
        
        guard let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        
        do {
            try await healthStore.requestAuthorization(toShare: [waterType], read: [energyType])
            isAuthorized = healthStore.authorizationStatus(for: waterType) == .sharingAuthorized
            await fetchTodayEnergyBurned()
        } catch {
            DispatchQueue.main.async {
                self.error = error
                print("HealthKit Authorization Failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshAuthorization() {
        guard isSupported, let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        isAuthorized = healthStore.authorizationStatus(for: waterType) == .sharingAuthorized
    }

    func syncWaterRecords(_ records: [WaterRecord]) async {
        guard !isSyncing, UserDefaults.standard.bool(forKey: "flux_health_enabled"),
              let enabledAt = UserDefaults.standard.object(forKey: "flux_health_enabled_at") as? Date,
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        refreshAuthorization()
        guard isAuthorized else { return }
        isSyncing = true
        defer { isSyncing = false }

        var synced = Set(UserDefaults.standard.stringArray(forKey: "flux_health_synced_ids") ?? [])
        for record in records where record.timestamp >= enabledAt && record.amountML > 0 {
            let id = record.id.uuidString
            guard !synced.contains(id), !Self.inFlightRecordIDs.contains(id) else { continue }
            Self.inFlightRecordIDs.insert(id)
            let sample = HKQuantitySample(
                type: waterType,
                quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: Double(record.amountML)),
                start: record.timestamp,
                end: record.timestamp,
                metadata: [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: 1]
            )
            do {
                try await healthStore.save(sample)
                synced.insert(id)
                UserDefaults.standard.set(Array(synced), forKey: "flux_health_synced_ids")
            } catch {
                self.error = error
                print("Health water sync failed: \(error.localizedDescription)")
            }
            Self.inFlightRecordIDs.remove(id)
        }
    }
    
    func fetchTodayEnergyBurned() async {
        guard isAuthorized, let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else { return }
        
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
        
        let query = HKStatisticsQuery(quantityType: energyType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
            if let error = error {
                print("Failed to fetch energy: \(error.localizedDescription)")
                return
            }
            guard let sum = result?.sumQuantity() else { return }
            let kCal = sum.doubleValue(for: HKUnit.kilocalorie())
            
            DispatchQueue.main.async {
                self.todayActiveEnergyBurned = kCal
            }
        }
        healthStore.execute(query)
    }
}
