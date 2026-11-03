import CoreGraphics
import Foundation
import KidicomKit
import SwiftUI

/// What the left mouse button does in the viewer.
enum MeasureTool: String, CaseIterable, Identifiable {
    case navigate, distance, angle

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .navigate: "VOIWindow/Level"
        case .distance: "Distance"
        case .angle: "Angle"
        }
    }

    var symbol: String {
        switch self {
        case .navigate: "circle.lefthalf.filled"
        case .distance: "ruler"
        case .angle: "angle"
        }
    }
}

/// A distance (two points) or an angle (arm, vertex, arm) on one frame,
/// in image pixel coordinates. Measurements live until the window closes.
struct Measurement: Identifiable, Equatable {
    enum Kind { case distance, angle }
    let id = UUID()
    var kind: Kind
    var points: [CGPoint]
    var slice: Int

    var isComplete: Bool { points.count == (kind == .distance ? 2 : 3) }
}

/// Measurement editing for one viewport: drawing, handles, selection.
extension Viewport {
    /// Distance in image pixels within which a click grabs a handle.
    private func grabRadius(scale: CGFloat) -> CGFloat { 8 / max(scale, 0.01) }

    func pointerDown(at p: CGPoint, scale: CGFloat) {
        // A pending angle waits for its third point.
        if var draft, draft.kind == .angle, draft.points.count == 2 {
            draft.points.append(p)
            self.draft = draft
            dragging = (draft.id, 2)
            return
        }
        // Grab a handle of a measurement on this frame.
        for measurement in measurements where measurement.slice == index {
            if let handle = measurement.points.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < grabRadius(scale: scale) }) {
                selected = measurement.id
                dragging = (measurement.id, handle)
                return
            }
        }
        selected = nil
        switch tool {
        case .navigate: return
        case .distance: draft = Measurement(kind: .distance, points: [p, p], slice: index)
        case .angle: draft = Measurement(kind: .angle, points: [p, p], slice: index)
        }
        dragging = (draft!.id, 1)
    }

    func pointerDragged(to p: CGPoint) {
        guard let (id, handle) = dragging else { return }
        if draft?.id == id {
            draft?.points[handle] = p
        } else if let i = measurements.firstIndex(where: { $0.id == id }) {
            measurements[i].points[handle] = p
        }
    }

    func pointerUp(scale: CGFloat) {
        defer { dragging = nil }
        guard let draft, dragging?.0 == draft.id else { return }
        let a = draft.points[0], b = draft.points[1]
        // A click without a drag starts nothing.
        if draft.points.count == 2 && hypot(a.x - b.x, a.y - b.y) < grabRadius(scale: scale) / 2 {
            self.draft = nil
            return
        }
        if draft.isComplete {
            measurements.append(draft)
            selected = draft.id
            self.draft = nil
        }
    }

    func deleteSelected() {
        guard let selected else { return }
        measurements.removeAll { $0.id == selected }
        self.selected = nil
    }

    func cancelDraft() {
        draft = nil
        selected = nil
    }

    var visibleMeasurements: [Measurement] {
        measurements.filter { $0.slice == index } + (draft.map { [$0] } ?? [])
    }

    func calibration(for measurement: Measurement) -> Calibration {
        Calibration.best(pixelSpacing: slice?.pixelSpacing ?? [], regions: slice?.regions ?? [], points: measurement.points)
    }

    func label(for measurement: Measurement) -> String {
        let calibration = calibration(for: measurement)
        switch measurement.kind {
        case .distance:
            let value = Measure.distance(measurement.points[0], measurement.points[1], calibration: calibration)
            if case .pixels = calibration { return String(localized: "\(Int(value.rounded())) px") }
            return value >= 10
                ? String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) mm")
                : String(localized: "\(value.formatted(.number.precision(.fractionLength(2)))) mm")
        case .angle:
            guard measurement.points.count == 3 else { return "" }
            let value = Measure.angle(measurement.points[0], vertex: measurement.points[1], measurement.points[2], calibration: calibration)
            return String(localized: "\(value.formatted(.number.precision(.fractionLength(1))))°")
        }
    }
}

/// Draws the measurements of the current frame over the image.
struct MeasurementOverlay: View {
    let viewport: Viewport

    var body: some View {
        GeometryReader { proxy in
            if let geometry = viewport.geometry(in: proxy.size) {
                ZStack(alignment: .topLeading) {
                    ForEach(viewport.visibleMeasurements) { measurement in
                        let points = measurement.points.map(geometry.toView)
                        let isSelected = viewport.selected == measurement.id
                        let color: Color = isSelected ? .cyan : .yellow
                        Path { path in
                            path.move(to: points[0])
                            for point in points.dropFirst() { path.addLine(to: point) }
                        }
                        .stroke(color, lineWidth: 1.5)  // grid: ok drawn in image coordinates
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            Circle()
                                .stroke(color, lineWidth: 1.5)  // grid: ok drawn in image coordinates
                                .frame(width: 8, height: 8)
                                .position(point)  // grid: ok drawn in image coordinates
                        }
                        Text(viewport.label(for: measurement))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                            .shadow(color: .black, radius: 1, x: 0, y: 1)
                            .fixedSize()
                            .position(labelPoint(points, kind: measurement.kind))  // grid: ok drawn in image coordinates
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The label sits up and to the right of the end point (distance) or the vertex (angle).
    private func labelPoint(_ points: [CGPoint], kind: Measurement.Kind) -> CGPoint {
        let anchor = points[kind == .angle ? 1 : points.count - 1]
        return CGPoint(x: anchor.x + Space.xxl + Space.xl, y: anchor.y - Space.md)
    }
}
