import Foundation
import HealthKit
import SwiftData
import SwiftUI

/// Pure filtering and deduplication rules shared by HealthKit export/import
/// and unit tests.
enum HealthSyncFilter {
    struct ExportCandidate: Equatable {
        let id: UUID
        let amountML: Int
        let timestamp: Date
    }

    struct ExternalSampleCandidate: Equatable {
        let uuid: UUID
        let amountML: Int
        let startDate: Date
        let sourceBundleID: String
    }

    /// Select Flux water records eligible to be written to Apple Health without
    /// duplicating previously synced or in-flight items.
    static func exportableRecords(
        _ candidates: [ExportCandidate],
        enabledAt: Date,
        syncedIDs: Set<String>,
        inFlightIDs: Set<String>
    ) -> [ExportCandidate] {
        candidates.filter { item in
            let key = item.id.uuidString
            return item.timestamp >= enabledAt
                && (1...5000).contains(item.amountML)
                && !syncedIDs.contains(key)
                && !inFlightIDs.contains(key)
        }
    }

    /// Select Apple Health dietaryWater samples written by *other* apps so Flux
    /// never re-imports its own samples or duplicates already-imported entries.
    static func importableExternalSamples(
        _ samples: [ExternalSampleCandidate],
        ownBundleID: String?,
        existingRecordIDs: Set<UUID>,
        importedIDs: Set<String>
    ) -> [ExternalSampleCandidate] {
        samples.filter { sample in
            if let ownBundleID, !ownBundleID.isEmpty, sample.sourceBundleID == ownBundleID {
                return false
            }
            let key = sample.uuid.uuidString
            guard !importedIDs.contains(key),
                  !existingRecordIDs.contains(sample.uuid),
                  (1...5000).contains(sample.amountML) else {
                return false
            }
            return true
        }
    }
}

@MainActor
@Observable
final class HealthKitManager {
    static let enabledKey = "flux_health_enabled"
    static let enabledAtKey = "flux_health_enabled_at"
    static let importEnabledKey = "flux_health_import_enabled"
    static let syncedIDsKey = "flux_health_synced_ids"
    static let importedIDsKey = "flux_health_imported_sample_ids"
    static let lastSyncKey = "flux_health_last_sync_at"

    enum AuthorizationStatus: Equatable {
        case unavailable
        case notDetermined
        case authorized
        case denied

        var label: String {
            switch self {
            case .unavailable: return "Unavailable"
            case .notDetermined: return "Not connected"
            case .authorized: return "Authorized"
            case .denied: return "Permission needed"
            }
        }
    }

    private static var inFlightRecordIDs = Set<String>()
    let healthStore = HKHealthStore()

    var authorizationStatus: AuthorizationStatus = .notDetermined
    var isAuthorized: Bool = false
    var todayActiveEnergyBurned: Double = 0.0
    var todayHealthWaterML: Int = 0
    var syncedRecordCount: Int = 0
    var lastSyncDate: Date?
    var lastErrorMessage: String?
    var error: Error?
    var isSyncing: Bool = false

    init() {
        syncedRecordCount = (UserDefaults.standard.stringArray(forKey: Self.syncedIDsKey) ?? []).count
        lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        refreshAuthorization()
    }

    // Always check HealthKit availability (e.g., unsupported simulators or older iPads).
    var isSupported: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    var isHealthSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var isExternalImportEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.importEnabledKey)
    }

    /// Ensure `enabled_at` starts from the beginning of today on first enable
    /// so today's logged drinks sync immediately without backfilling old history.
    func ensureEnabledTimestamp() {
        if UserDefaults.standard.object(forKey: Self.enabledAtKey) as? Date == nil {
            let todayStart = Calendar.current.startOfDay(for: Date())
            UserDefaults.standard.set(todayStart, forKey: Self.enabledAtKey)
        }
    }

    func requestAuthorization() async {
        guard isSupported else {
            authorizationStatus = .unavailable
            isAuthorized = false
            lastErrorMessage = "HealthKit is not available on this device."
            return
        }

        guard let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }

        lastErrorMessage = nil
        do {
            try await healthStore.requestAuthorization(toShare: [waterType], read: [energyType, waterType])
            refreshAuthorization()
            if isAuthorized {
                ensureEnabledTimestamp()
                await fetchTodayEnergyBurned()
                await fetchTodayHealthWater()
            } else if authorizationStatus == .denied {
                lastErrorMessage = "Enable Water write access in Apple Health → Sharing → Apps → Flux."
            }
        } catch {
            self.error = error
            self.lastErrorMessage = error.localizedDescription
            refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        guard isSupported else {
            authorizationStatus = .unavailable
            isAuthorized = false
            return
        }
        guard let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        switch healthStore.authorizationStatus(for: waterType) {
        case .sharingAuthorized:
            authorizationStatus = .authorized
            isAuthorized = true
        case .sharingDenied:
            authorizationStatus = .denied
            isAuthorized = false
        case .notDetermined:
            authorizationStatus = .notDetermined
            isAuthorized = false
        @unknown default:
            authorizationStatus = .notDetermined
            isAuthorized = false
        }
        syncedRecordCount = (UserDefaults.standard.stringArray(forKey: Self.syncedIDsKey) ?? []).count
    }

    /// Full bidirectional refresh: fetches active energy, exports unsynced Flux
    /// drinks, optionally imports external Health water logs, and updates today's
    /// Apple Health total.
    func refreshAll(records: [WaterRecord], modelContext: ModelContext? = nil) async {
        refreshAuthorization()
        guard isSupported, isHealthSyncEnabled else { return }
        await fetchTodayEnergyBurned()
        await syncWaterRecords(records)
        if let modelContext, isExternalImportEnabled {
            _ = await importExternalHealthWater(into: modelContext, existingRecords: records)
        }
        await fetchTodayHealthWater()
    }

    func syncWaterRecords(_ records: [WaterRecord]) async {
        guard !isSyncing, isSupported, isHealthSyncEnabled,
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        ensureEnabledTimestamp()
        guard let enabledAt = UserDefaults.standard.object(forKey: Self.enabledAtKey) as? Date else { return }
        refreshAuthorization()
        guard isAuthorized else { return }

        isSyncing = true
        defer { isSyncing = false }
        lastErrorMessage = nil

        var synced = Set(UserDefaults.standard.stringArray(forKey: Self.syncedIDsKey) ?? [])
        let candidates = records.map {
            HealthSyncFilter.ExportCandidate(id: $0.id, amountML: $0.amountML, timestamp: $0.timestamp)
        }
        let pending = HealthSyncFilter.exportableRecords(
            candidates,
            enabledAt: enabledAt,
            syncedIDs: synced,
            inFlightIDs: Self.inFlightRecordIDs
        )

        var wroteAny = false
        for item in pending {
            let id = item.id.uuidString
            Self.inFlightRecordIDs.insert(id)
            defer { Self.inFlightRecordIDs.remove(id) }

            let sample = HKQuantitySample(
                type: waterType,
                quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: Double(item.amountML)),
                start: item.timestamp,
                end: item.timestamp,
                metadata: [
                    HKMetadataKeySyncIdentifier: id,
                    HKMetadataKeySyncVersion: 1,
                    HKMetadataKeyWasUserEntered: true
                ]
            )
            do {
                try await healthStore.save(sample)
                synced.insert(id)
                wroteAny = true
                UserDefaults.standard.set(Array(synced), forKey: Self.syncedIDsKey)
            } catch {
                self.error = error
                self.lastErrorMessage = error.localizedDescription
            }
        }

        syncedRecordCount = synced.count
        if wroteAny || lastSyncDate == nil {
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        }
    }

    /// Delete the matching Apple Health dietaryWater sample when a Flux record
    /// is deleted in History or undone on Apple Watch.
    func deleteWaterRecord(id: UUID) async {
        let key = id.uuidString
        var synced = Set(UserDefaults.standard.stringArray(forKey: Self.syncedIDsKey) ?? [])
        synced.remove(key)
        UserDefaults.standard.set(Array(synced), forKey: Self.syncedIDsKey)
        syncedRecordCount = synced.count

        guard isSupported, isHealthSyncEnabled,
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return }
        refreshAuthorization()
        guard isAuthorized else { return }

        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            allowedValues: [key]
        )
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                healthStore.deleteObjects(of: waterType, predicate: predicate) { _, deletedCount, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: deletedCount)
                    }
                }
            }
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            await fetchTodayHealthWater()
        } catch {
            self.error = error
            self.lastErrorMessage = error.localizedDescription
        }
    }

    /// Read today's dietaryWater entries created by *other* apps in Apple Health
    /// and import them into Flux (deduplicated by Health sample UUID).
    @discardableResult
    func importExternalHealthWater(into context: ModelContext, existingRecords: [WaterRecord]) async -> Int {
        guard isSupported, isHealthSyncEnabled, isExternalImportEnabled,
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else { return 0 }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: waterType,
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sort]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }

        let candidates = samples.map { sample in
            let ml = Int(sample.quantity.doubleValue(for: .literUnit(with: .milli)).rounded())
            return HealthSyncFilter.ExternalSampleCandidate(
                uuid: sample.uuid,
                amountML: ml,
                startDate: sample.startDate,
                sourceBundleID: sample.sourceRevision.source.bundleIdentifier
            )
        }

        var imported = Set(UserDefaults.standard.stringArray(forKey: Self.importedIDsKey) ?? [])
        var synced = Set(UserDefaults.standard.stringArray(forKey: Self.syncedIDsKey) ?? [])
        let existingIDs = Set(existingRecords.map(\.id))

        let toImport = HealthSyncFilter.importableExternalSamples(
            candidates,
            ownBundleID: Bundle.main.bundleIdentifier,
            existingRecordIDs: existingIDs,
            importedIDs: imported
        )
        guard !toImport.isEmpty else { return 0 }

        for item in toImport {
            let record = WaterRecord(amountML: item.amountML, timestamp: item.startDate, id: item.uuid)
            context.insert(record)
            let key = item.uuid.uuidString
            imported.insert(key)
            // Mark as already synced so Flux never writes imported samples back to Apple Health.
            synced.insert(key)
        }

        do {
            try context.save()
            UserDefaults.standard.set(Array(imported), forKey: Self.importedIDsKey)
            UserDefaults.standard.set(Array(synced), forKey: Self.syncedIDsKey)
            syncedRecordCount = synced.count
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            return toImport.count
        } catch {
            self.error = error
            self.lastErrorMessage = error.localizedDescription
            return 0
        }
    }

    func fetchTodayEnergyBurned() async {
        guard isSupported, isHealthSyncEnabled,
              let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) else {
            todayActiveEnergyBurned = 0
            return
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        let kCal: Double = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: energyType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let value = result?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                continuation.resume(returning: max(0, value))
            }
            healthStore.execute(query)
        }
        todayActiveEnergyBurned = kCal
    }

    func fetchTodayHealthWater() async {
        guard isSupported, isHealthSyncEnabled,
              let waterType = HKObjectType.quantityType(forIdentifier: .dietaryWater) else {
            todayHealthWaterML = 0
            return
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        let ml: Int = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: waterType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let raw = result?.sumQuantity()?.doubleValue(for: .literUnit(with: .milli)) ?? 0
                continuation.resume(returning: max(0, Int(raw.rounded())))
            }
            healthStore.execute(query)
        }
        todayHealthWaterML = ml
    }
}
