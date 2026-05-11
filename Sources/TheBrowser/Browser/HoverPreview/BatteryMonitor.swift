import Foundation
import IOKit.ps

/// Observes the Mac's power source and Low Power Mode state, exposing a
/// single `shouldDeferBackgroundWork` flag for cheap polling. Refreshes
/// on `NSProcessInfoPowerStateDidChange` plus a manual recheck whenever
/// the prefetcher consults it (so quick AC unplug/plug events are caught
/// without needing IOKit run-loop sources).
@MainActor
final class BatteryMonitor {
    static let shared = BatteryMonitor()

    private(set) var isOnBattery: Bool
    private(set) var isLowPowerMode: Bool

    private init() {
        isOnBattery = Self.queryBatteryState()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// True when the prefetcher should sit out — battery + Low Power Mode
    /// together. Either condition alone still allows prefetching: Low
    /// Power Mode on AC is the user telling us they care about thermals,
    /// not about idle network. Battery alone is fine for a few KBs.
    var shouldDeferBackgroundWork: Bool {
        refresh()
        return isOnBattery && isLowPowerMode
    }

    /// Re-reads the power source and Low Power flag. Cheap — IOKit query
    /// returns immediately because IOPS keeps the snapshot warm in-kernel.
    private func refresh() {
        isOnBattery = Self.queryBatteryState()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private static func queryBatteryState() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return false
        }
        return providing == kIOPSBatteryPowerValue
    }
}
