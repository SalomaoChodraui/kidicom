# Architecture review, 2026-11-03 (end of M1)

Survey: 4,193 lines in two Swift targets plus vendored OpenJPEG. Largest file 293 lines (`JPEGLossless.swift`). No file near 600 lines, no duplicated private types, no fix-log entries yet. All decoding and import logic sits in `KidicomKit` with tests; the app target holds SwiftData, views, and orchestration.

## Volume module in KidicomKit before M3  [Worth exploring]

Files: Sources/Kidicom/Viewer/SeriesStack.swift (152 lines)
Signal: before a big feature (MPR, MIP, 3D in M3)
Problem: frames are decoded one at a time into `SeriesStack`, an app type built from a SwiftData `Series`. MPR, MIP, and volume rendering need the whole series as one buffer with spacing and orientation, and that logic must be testable without the app.
Proposal:
```swift
public struct Volume: Sendable {
    public let size: (x: Int, y: Int, z: Int)
    public let spacing: SIMD3<Double>      // mm
    public let origin: SIMD3<Double>
    public let axes: (row: SIMD3<Double>, column: SIMD3<Double>, normal: SIMD3<Double>)
    public let voxels: [Float]             // modality values, x fastest
    public static func build(from slices: [VolumeSlice]) throws -> Volume
}
```
Benefits: one place for slice spacing checks, gaps, and mixed orientations (S-020); MPR and MIP become pure functions over `Volume` with unit tests; the Metal renderer takes one buffer.
Proof of same behavior: new code only; the viewer keeps `SeriesStack` for 2D.
Plan: build it as the first commit of S-020.

## Plain series description for SeriesStack  [Speculative]

Files: Sources/Kidicom/Viewer/SeriesStack.swift
Problem: `SeriesStack.init(series:)` reads SwiftData objects directly, so it cannot be built in a unit test.
Proposal: take a plain `[SliceRef]` built by one function from `Series`.
Revisit when M4 (comparison) needs stacks from two studies.

## Top recommendation

Nothing to refactor now. Start M3 with the `Volume` module in `KidicomKit` (card 1), as part of S-020.

## Considered, not recommended

- Moving the import upsert (records to Study, Series, ImageFile) into the Kit: it is SwiftData glue, already covered by the self-test, and a Kit copy would need its own model types.
- A protocol around codecs: one implementation per syntax and no test adapter needed; reference tests cover them.
