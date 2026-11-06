import CoreGraphics
import Foundation
import KidicomKit

/// Main-thread cost of a window/level drag with three synced 2048² viewports,
/// as in MPR. Opt-in: `APP_STORE=/tmp/x.store KIDICOM_RENDER_BENCH=1 Kidicom --selftest`.
enum RenderBench {
    static var requested: Bool { ProcessInfo.processInfo.environment["KIDICOM_RENDER_BENCH"] == "1" }

    static func run() async {
        let side = 2048
        let values = (0 ..< side * side).map { Float($0 % 4096) - 1024 }
        let slice = DecodedSlice(frame: .grayscale(values), width: side, height: side, inverted: false,
                                 defaultWindow: VOIWindow(center: 40, width: 400), pixelSpacing: [1, 1])
        let viewports = (0 ..< 3).map { _ in Viewport() }
        for viewport in viewports { viewport.show(SingleFrameSource(slice)) }
        viewports[0].onWindowChange = { window in
            for other in viewports.dropFirst() { other.setWindowQuietly(window) }
        }
        let ready = Date.now
        while viewports.contains(where: { $0.image == nil }) && Date.now.timeIntervalSince(ready) < 5 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let events = 200
        var blocked: UInt64 = 0, latency: UInt64 = 0
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0 ..< events {
            let before = viewports.map(\.image)
            let start = DispatchTime.now().uptimeNanoseconds
            viewports[0].adjustWindow(dx: 2, dy: 0)
            blocked += DispatchTime.now().uptimeNanoseconds - start
            while zip(viewports, before).contains(where: { $0.image === $1 }) {
                try? await Task.sleep(for: .microseconds(200))
            }
            latency += DispatchTime.now().uptimeNanoseconds - start
        }
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart
        func ms(_ ns: UInt64) -> String { String(format: "%.3f", Double(ns) / Double(events) / 1e6) }
        print("BENCH 3x2048² window event: handler \(ms(blocked)) ms, main CPU \(ms(cpu)) ms, until all three show \(ms(latency)) ms")
    }
}

/// A source with one frame, always in cache (benchmark and self-test).
final class SingleFrameSource: FrameSource {
    let id = UUID().uuidString
    let title = "Test"
    let modality = "CT"
    let count = 1
    let slice: DecodedSlice
    init(_ slice: DecodedSlice) { self.slice = slice }
    func cached(_ index: Int) -> DecodedSlice? { slice }
    func load(_ index: Int) async -> DecodedSlice? { slice }
    func prefetch(around index: Int) {}
    func location(_ index: Int) -> Double? { nil }
    func orientation(_ index: Int) -> [Double] { [] }
    func fileURL(_ index: Int) -> URL? { nil }
}
