import Foundation
import HealthKit
import SwiftUI

@Observable
final class HealthKitManager {
    let healthStore = HKHealthStore()
    var isAuthorized: Bool = false
    var todayActiveEnergyBurned: Double = 0.0
    var error: Error?
    
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
            DispatchQueue.main.async {
                self.isAuthorized = true
            }
            await fetchTodayEnergyBurned()
        } catch {
            DispatchQueue.main.async {
                self.error = error
                print("HealthKit Authorization Failed: \(error.localizedDescription)")
            }
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
