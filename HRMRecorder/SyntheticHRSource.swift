#if DEBUG
import Foundation

/// DEBUG-only fake heart-rate source. Installs a synthetic "Simulator Strap"
/// into `HeartRateManager.devices` and feeds plausible BPM + R-R interval
/// samples at ~1 Hz so the live UI, recording flow, and CSV export can be
/// exercised in the iOS Simulator (where CoreBluetooth does nothing).
///
/// Enabled by adding `-HRMUseFakeSensor` to the scheme's launch arguments
/// (Edit Scheme → Run → Arguments → Arguments Passed On Launch). The entire
/// type is `#if DEBUG`-gated so it cannot ship in Release builds.
///
/// AIDEV-NOTE: only used for marketing screenshots / Simulator exercising —
/// never on a real device with a real strap. Generated BPM walks softly
/// around a baseline so screenshots look like calm rest data; for jumpier
/// data, raise `walkAmplitude` or call `setBaselineBPM(_:)`.
final class SyntheticHRSource {

    private weak var manager: HeartRateManager?
    private let strapID = UUID()
    private let strapName = "Simulator Strap"

    private var timer: Timer?
    private var baselineBPM: Double = 68
    private var currentBPM: Double = 68
    private let walkAmplitude: Double = 2.5      // ± per second
    private let bpmFloor: Double = 42
    private let bpmCeiling: Double = 178

    init(manager: HeartRateManager) {
        self.manager = manager
    }

    func start() {
        guard timer == nil else { return }
        manager?.installSyntheticStrap(id: strapID, name: strapName,
                                       manufacturer: "Simulator",
                                       model: "Synthetic HR",
                                       firmware: "1.0",
                                       bodyLocation: "Chest",
                                       batteryPercent: 87)
        // ~1 Hz, matching the real strap's notification cadence.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Fire one sample immediately so the UI is non-zero from the start.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setBaselineBPM(_ bpm: Int) {
        baselineBPM = Double(bpm)
        currentBPM = Double(bpm)
    }

    private func tick() {
        // Random walk with a soft pull toward the baseline so it doesn't
        // drift forever in one direction.
        let drift = Double.random(in: -walkAmplitude...walkAmplitude)
        let pullToBaseline = (baselineBPM - currentBPM) * 0.05
        currentBPM = max(bpmFloor, min(bpmCeiling, currentBPM + drift + pullToBaseline))
        let bpm = Int(currentBPM.rounded())

        // Derive R-R intervals from current BPM with realistic jitter.
        // 1–3 R-R values per packet matches what real straps emit.
        let baseRR = max(200, 60_000 / max(30, bpm))
        let count = Int.random(in: 1...3)
        let rr: [Int] = (0..<count).map { _ in
            let jitter = Int.random(in: -28...28)
            return max(250, baseRR + jitter)
        }

        manager?.injectSyntheticSample(strapID: strapID, bpm: bpm, rr: rr)
    }
}
#endif
