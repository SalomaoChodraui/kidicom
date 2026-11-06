import CoreGraphics
import Foundation
import Testing
@testable import KidicomKit

@Suite("Render gate")
struct RenderGateTests {
    typealias Gate = RenderGate<Int, String>

    @Test("Requests before the flush draw once, with the newest input")
    func coalesces() {
        var gate = Gate()
        let r1 = gate.request(1, "a")
        #expect(r1)
        let r2 = gate.request(2, "b")
        #expect(!r2)
        let r3 = gate.request(3, "c")
        #expect(!r3)
        let job = gate.next()
        #expect(job?.key == 3 && job?.input == "c")
        let r4 = gate.finish(job!)
        #expect(r4)
        #expect(gate.shown == 3)
        let r5 = gate.next()
        #expect(r5 == nil)
    }

    @Test("What is on screen already draws nothing")
    func skipsRepeats() {
        var gate = Gate()
        _ = gate.request(1, "a")
        let job = gate.next()!
        let r6 = gate.finish(job)
        #expect(r6)
        let r7 = gate.request(1, "a")
        #expect(!r7)
        let r8 = gate.next()
        #expect(r8 == nil)
        // Away and back before the flush: nothing new to draw.
        let r9 = gate.request(2, "b")
        #expect(r9)
        _ = gate.request(1, "a")
        let r10 = gate.next()
        #expect(r10 == nil)
    }

    @Test("One draw at a time; the newest request follows when it ends")
    func oneAtATime() {
        var gate = Gate()
        _ = gate.request(1, "a")
        let first = gate.next()!
        let r11 = gate.request(2, "b")   // the running draw picks it up
        #expect(!r11)
        let r12 = gate.request(3, "c")
        #expect(!r12)
        let r13 = gate.next()
        #expect(r13 == nil)
        let r14 = gate.finish(first)
        #expect(r14)
        let second = gate.next()
        #expect(second?.key == 3)
        let r15 = gate.finish(second!)
        #expect(r15)
        let r16 = gate.next()
        #expect(r16 == nil)
    }

    @Test("A draw from before clear never reaches the screen")
    func clearDrops() {
        var gate = Gate()
        _ = gate.request(1, "a")
        let old = gate.next()!
        gate.clear()
        let r17 = gate.request(5, "new")   // waits for the old draw to end
        #expect(!r17)
        let r18 = gate.finish(old)
        #expect(!r18)
        #expect(gate.shown == nil)
        let fresh = gate.next()
        #expect(fresh?.key == 5)
        let r19 = gate.finish(fresh!)
        #expect(r19)
        #expect(gate.shown == 5)
    }

    @Test("Frames share storage only when they hold the same buffer")
    func storage() {
        let values: [Float] = [1, 2, 3]
        let same = Frame.grayscale(values)
        #expect(same.sharesStorage(with: Frame.grayscale(values)))
        #expect(!same.sharesStorage(with: Frame.grayscale([1, 2, 3])))
        #expect(!same.sharesStorage(with: Frame.color([1, 2, 3, 4])))
    }

    @Test("Only large frames leave the caller's thread")
    func background() {
        #expect(!Renderer.drawsInBackground(.grayscale([]), width: 1024, height: 1024))
        #expect(Renderer.drawsInBackground(.grayscale([]), width: 2048, height: 2048))
        #expect(Renderer.drawsInBackground(.color([]), width: 1024, height: 512))
        #expect(!Renderer.drawsInBackground(.color([]), width: 320, height: 240))
    }

    @Test("Images drawn in background match the ones drawn in place")
    func sameImage() async {
        let values = (0 ..< 64 * 64).map { Float($0) }
        let window = VOIWindow(center: 2000, width: 3000)
        let here = Renderer.image(.grayscale(values), width: 64, height: 64, window: window, inverted: true)
        let there = await Renderer.imageInBackground(.grayscale(values), width: 64, height: 64, window: window, inverted: true)
        #expect(here?.dataProvider?.data as Data? != nil)
        #expect(here?.dataProvider?.data as Data? == there?.dataProvider?.data as Data?)
    }

    @Test("Short buffers give no image instead of reading past the end")
    func shortBuffers() {
        #expect(Renderer.image(.grayscale([1, 2, 3]), width: 2, height: 2, window: VOIWindow(center: 0, width: 10), inverted: false) == nil)
        #expect(Renderer.image(.color([1, 2, 3]), width: 1, height: 1, window: VOIWindow(center: 128, width: 256), inverted: false) == nil)
        #expect(Renderer.color([10, 20, 30, 40, 50], window: VOIWindow(center: 128, width: 64)).count == 5)
    }

    @Test("Gray and color images keep their pixels")
    func pixels() {
        let gray = Renderer.grayImage([0, 64, 128, 255], width: 2, height: 2)
        #expect(gray?.dataProvider?.data as Data? == Data([0, 64, 128, 255]))
        let rgba: [UInt8] = [10, 128, 250, 7]
        let color = Renderer.image(.color(rgba), width: 1, height: 1, window: VOIWindow(center: 128, width: 64), inverted: false)
        #expect(color?.dataProvider?.data as Data? == Data(Renderer.color(rgba, window: VOIWindow(center: 128, width: 64))))
    }
}
