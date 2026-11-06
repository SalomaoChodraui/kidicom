import Testing
@testable import KidicomKit

@Test("Quickselect finds the same value as a full sort")
func quickselectMatchesSort() {
    var generator = SystemRandomNumberGenerator()
    for count in [1, 2, 3, 10, 101, 5_000] {
        for _ in 0 ..< 20 {
            // Few distinct values exercise duplicates; the range exercises negatives.
            let values = (0 ..< count).map { _ in Float(Int.random(in: -50 ... 50, using: &generator)) }
            let sorted = values.sorted()
            for k in Set([0, count / 2, Int(Double(count - 1) * 0.95), count - 1]) {
                var copy = values
                #expect(Selection.nthSmallest(&copy, k) == sorted[k])
            }
        }
    }
    var ascending = (0 ..< 10_000).map(Float.init)
    #expect(Selection.nthSmallest(&ascending, 9_500) == 9_500)
}

@Test("The automatic 3D window comes from the 95th percentile")
func automaticWindow() throws {
    let slices = (0 ..< 4).map { k in
        VolumeSlice(values: (0 ..< 100).map { Float($0) }, width: 10, height: 10,
                    position: [0, 0, Double(k)], orientation: [1, 0, 0, 0, 1, 0], pixelSpacing: [1, 1])
    }
    let volume = try Volume.build(slices)
    let samples = volume.voxels.map(Float.init).sorted()
    let high = Double(samples[Int(Double(samples.count - 1) * 0.95)])
    #expect(volume.automaticWindow() == VOIWindow(center: high * 0.55, width: max(2, high * 0.7)))
}
