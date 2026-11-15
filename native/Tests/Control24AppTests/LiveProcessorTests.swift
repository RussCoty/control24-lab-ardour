import Foundation
import Testing
@testable import Control24Lab

@Suite @MainActor
struct LiveProcessorTests {
    // Run explicitly against a disposable session with the FX Test track in slot 1.
    @Test(.enabled(if: ["ardour", "mixbus"].contains(ProcessInfo.processInfo.environment["C24_LIVE_FX"] ?? "")))
    func processorRoundTrip() async throws {
        let target = try #require(ProcessInfo.processInfo.environment["C24_LIVE_FX"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("C24-FX-\(UUID())")
        let store = try LabStore(directory: url)
        defer {
            store.stopFeedback()
            try? FileManager.default.removeItem(at: url)
        }
        store.switchProfile(target)
        store.connectDAW(feedbackPort: 39282)
        try await waitUntil { store.dawStatus.hasPrefix("Receiving") }
        store.toggleOutput()

        for (note, processor, parameter) in target == "mixbus"
            ? [(2, "32C EQ", "Hi Gain"), (2, "9kJ EQ", "Hi Gain"), (2, "ACE EQ", "Gain"),
               (3, "Comp", "Threshold"), (3, "Gate", "Threshold"),
               (3, "SSL Comp", "Threshold"), (3, "SSL Gate", "Threshold"),
               (3, "ACE Compressor", "Threshold"), (3, "ACE Expander", "Threshold")]
            : [(2, "ACE EQ", "Gain"), (3, "ACE Compressor", "Threshold"), (3, "ACE Expander", "Threshold")] {
            store.input("button:0:\(note)", 1)
            store.input("button:0:\(note)", 0)
            try await waitUntil { store.processorStatus?.contains("· \(processor) ·") == true }
            let index = try #require(store.processorControls.firstIndex { $0.label.localizedCaseInsensitiveContains(parameter) })
            let control = store.processorControls[index]
            let delta = control.position > 0.8 ? -8.0 : 8.0
            let expected = control.adjusted(by: delta)
            store.input("encoder:\(index)", delta)
            try await waitUntil {
                store.processorControls.indices.contains(index) &&
                    abs(store.processorControls[index].value - expected) < 0.001
            }
            let observed = store.processorControls[index].value
            #expect(abs(observed - expected) < 0.001)
            #expect(abs(observed - control.value) > 0.001)
            print("LIVE \(target) \(processor) \(control.label) \(control.value) -> \(observed)")
        }
        store.closeProcessorMode()
        #expect(store.processorControls.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() {return}
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(condition(), "Timed out waiting for the DAW's processor feedback")
    }
}
