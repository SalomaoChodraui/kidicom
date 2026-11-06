import CoreGraphics
import Foundation
import Testing
import KidicomKit

/// Times window/level plus CGImage creation. Opt-in: BENCH=1, best in release.
@Suite struct RenderBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BENCH"] == "1"))
    func renderSpeed() {
        let window = VOIWindow(center: 40, width: 400)
        for side in [512, 1024, 2048] {
            let values = (0 ..< side * side).map { Float($0 % 4096) - 1024 }
            let frame = Frame.grayscale(values)
            let gray = time { _ = Renderer.image(frame, width: side, height: side, window: window, inverted: false) }
            print("BENCH gray \(side)²: \(String(format: "%.3f", gray)) ms")
            let rgba = (0 ..< side * side * 4).map { UInt8(truncatingIfNeeded: $0) }
            let color = Frame.color(rgba)
            let narrow = VOIWindow(center: 128, width: 128)
            let tinted = time { _ = Renderer.image(color, width: side, height: side, window: narrow, inverted: false) }
            print("BENCH color \(side)²: \(String(format: "%.3f", tinted)) ms")
        }
        // A round trip to another thread and back, the price of rendering off the caller.
        let queue = DispatchQueue(label: "bench.hop", qos: .userInteractive)
        let hop = time {
            let done = DispatchSemaphore(value: 0)
            queue.async { done.signal() }
            done.wait()
        }
        print("BENCH hop: \(String(format: "%.3f", hop)) ms")
    }

    /// Mean milliseconds of a run, after one warm-up.
    private func time(_ body: () -> Void) -> Double {
        body()
        let runs = 50
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< runs { body() }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1e6
    }
}
