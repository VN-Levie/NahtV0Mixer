import AppKit
import AudioRouting

/// Explicit developer fixture: generates a quiet tone; captures only its own afplay child.
/// Never entered from normal app launch or --diagnose.
@MainActor enum AudioCheck {
    static func run() -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NahtV0Mixer-audio-check-\(UUID().uuidString)")
        let player = Process()
        var route: ProcessAudioRoute?
        defer {
            route?.stop()
            if player.isRunning { player.terminate(); player.waitUntilExit() }
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("generated-tone.wav")
            try toneWave().write(to: file)
            let output = try AudioCatalog.defaultOutputID()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [file.path]
            try player.run()
            var sources: [UInt32] = []
            let discoveryDeadline = Date().addingTimeInterval(3)
            repeat {
                pump(0.1)
                sources = try AudioCatalog.processObjectIDs(forPID: player.processIdentifier)
            } while sources.isEmpty && Date() < discoveryDeadline
            guard !sources.isEmpty else { throw CheckFailure.message("The generated tone did not register an audio source.") }
            print("Starting a private route for the generated test tone; macOS may request audio access.")
            fflush(stdout)
            route = try ProcessAudioRoute(processObjectIDs: sources, outputDeviceID: output, gain: 1)
            guard let route else { throw CheckFailure.message("Route creation failed.") }
            let captureDeadline = Date().addingTimeInterval(20)
            while route.inputPeak < 0.00001 && !route.hasRenderFailure && Date() < captureDeadline { pump(0.1) }
            guard !route.hasRenderFailure, route.processedFrameCount > 0, route.inputPeak > 0.00001 else {
                throw CheckFailure.message("No valid test-tone audio arrived. Check the system audio permission and output format.")
            }
            pump(0.5)
            let unity = route.peak, input = route.inputPeak
            route.setGain(0.25); pump(0.6)
            let quarter = route.peak, quarterInput = route.inputPeak
            route.setGain(0); pump(0.6)
            let muted = route.peak, frames = route.processedFrameCount
            guard unity > 0.00001, abs(unity / input - 1) < 0.05,
                  quarterInput > 0.00001, abs(quarter / quarterInput - 0.25) < 0.03,
                  muted < 0.000001, !route.hasRenderFailure else {
                throw CheckFailure.message("The live gain/mute measurements did not match the test tone.")
            }
            route.stop()
            guard try AudioCatalog.defaultOutputID() == output else {
                throw CheckFailure.message("The output device changed during the fixture.")
            }
            let result: [String: Any] = ["passed": true, "source": "generated afplay child only", "outputDeviceUnchanged": true,
                                        "inputPeak": input, "unityPeak": unity, "quarterPeak": quarter,
                                        "mutePeak": muted, "processedFrames": frames]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            fputs("Audio fixture failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
    private static func pump(_ duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }
    private static func toneWave() -> Data {
        let rate = 48_000, frames = rate * 30
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + frames * 4)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(2)); word(UInt32(rate)); word(UInt32(rate * 4))
        word(UInt16(4)); word(UInt16(16)); ascii("data"); word(UInt32(frames * 4))
        for frame in 0..<frames {
            let envelope = min(1, Double(frame) / 2400)
            let value = Int16(sin(2 * .pi * 440 * Double(frame) / Double(rate)) * 650 * envelope)
            word(value); word(value)
        }
        return data
    }
    private enum CheckFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
