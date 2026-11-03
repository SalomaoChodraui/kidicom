import Foundation

/// Anything a viewport can scroll through: a series of files, or a plane
/// reformatted from a volume.
protocol FrameSource: AnyObject {
    var id: String { get }
    var title: String { get }
    var modality: String { get }
    var count: Int { get }
    func cached(_ index: Int) -> DecodedSlice?
    func load(_ index: Int) async -> DecodedSlice?
    func prefetch(around index: Int)
    /// Position along the plane normal, in mm.
    func location(_ index: Int) -> Double?
    /// Row and column direction cosines of the frame.
    func orientation(_ index: Int) -> [Double]
    /// The file behind the frame, for the tag inspector; nil for reformats.
    func fileURL(_ index: Int) -> URL?
}

extension SeriesStack: FrameSource {
    func location(_ index: Int) -> Double? { slices.indices.contains(index) ? slices[index].location : nil }
    func orientation(_ index: Int) -> [Double] { slices.indices.contains(index) ? slices[index].orientation : [] }
    func fileURL(_ index: Int) -> URL? { slices.indices.contains(index) ? slices[index].url : nil }
}
