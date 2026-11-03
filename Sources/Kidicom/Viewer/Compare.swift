import Foundation
import KidicomKit

/// A prior study opened in the viewer to compare (S-030).
struct PriorStudy: Identifiable {
    let id: UUID
    let date: Date?
    let description: String
    let stacks: [SeriesStack]
}

extension ViewerModel {
    // MARK: Priors (S-030)

    /// Opens a prior study beside the current images, on the series most
    /// like the active one: same modality and plane, closest image count.
    func openPrior(_ study: Study) {
        let prior = loadPrior(study)
        expandedPriors.insert(study.uid)
        guard let match = bestMatch(in: prior.stacks, for: active?.stack) else { return }
        compare(match)
    }

    /// Reads a prior study's series for the strip, once.
    @discardableResult
    func loadPrior(_ study: Study) -> PriorStudy {
        if let loaded = priors.first(where: { $0.id == study.uid }) { return loaded }
        let stacks = study.series.sorted { ($0.number, $0.seriesDescription) < ($1.number, $1.seriesDescription) }
            .map(SeriesStack.init(series:))
            .filter { $0.count > 0 }
        let prior = PriorStudy(id: study.uid, date: study.studyDate, description: study.studyDescription, stacks: stacks)
        priors.append(prior)
        for stack in stacks { Task { await stack.makeThumbnail() } }
        return prior
    }

    /// Strip timeline: a date row expands or collapses that study's series.
    func togglePrior(_ study: Study) {
        if expandedPriors.contains(study.uid) {
            expandedPriors.remove(study.uid)
        } else {
            loadPrior(study)
            expandedPriors.insert(study.uid)
        }
    }

    func bestMatch(in stacks: [SeriesStack], for reference: SeriesStack?) -> SeriesStack? {
        guard let reference else { return stacks.max { $0.count < $1.count } }
        let plane = PatientPlane(orientation: reference.orientation(0))
        func score(_ s: SeriesStack) -> Double {
            var value = 0.0
            if s.modality == reference.modality { value += 1000 }
            if PatientPlane(orientation: s.orientation(0)) == plane { value += 500 }
            if s.title == reference.title { value += 200 }
            value -= abs(Double(s.count - reference.count)) / Double(max(reference.count, 1)) * 100
            return value
        }
        return stacks.max { score($0) < score($1) }
    }

    // MARK: Scroll and window sync (S-031)

    /// Wires every viewport to the sync rules. Called once per viewer.
    func connectSync() {
        for viewport in viewports {
            viewport.onScroll = { [weak self] v in self?.follow(v) }
            viewport.onAdjust = { [weak self] v in self?.realign(v) }
        }
    }

    /// The other visible viewports that scroll with `leader`: series of
    /// files in a parallel plane, while sync is on and MPR is off.
    private func followers(of leader: Viewport) -> [Viewport] {
        guard syncScroll, mpr == nil, let plane = plane(of: leader) else { return [] }
        return visible.filter { $0 !== leader && $0.stack != nil && self.plane(of: $0) == plane }
    }

    private func plane(of viewport: Viewport) -> PatientPlane? {
        guard let source = viewport.source, viewport.location != nil else { return nil }
        let plane = PatientPlane(orientation: source.orientation(viewport.index))
        return plane == .oblique ? nil : plane
    }

    /// Moves followers to the slice nearest the leader's position plus offsets.
    func follow(_ leader: Viewport) {
        guard let location = leader.location else { return }
        let target = location + leader.syncOffset
        for viewport in followers(of: leader) {
            guard let stack = viewport.stack else { continue }
            var best = viewport.index, distance = Double.infinity
            for i in 0 ..< stack.count {
                if let l = stack.location(i) {
                    let d = abs(l + viewport.syncOffset - target)
                    if d < distance { distance = d; best = i }
                }
            }
            viewport.go(to: best)
        }
    }

    /// After a Shift-scroll, keeps this viewport where the person put it.
    func realign(_ moved: Viewport) {
        guard let location = moved.location,
              let reference = visible.first(where: { $0 !== moved && plane(of: $0) == plane(of: moved) && $0.stack != nil }),
              let referenceLocation = reference.location else { return }
        moved.syncOffset = referenceLocation + reference.syncOffset - location
    }

    /// Lines up a newly shown series with the others: by absolute position
    /// in the same frame of reference, else by relative position in the stack.
    func alignNewViewport(_ viewport: Viewport) {
        guard let stack = viewport.stack, let location = viewport.location,
              let reference = visible.first(where: { $0 !== viewport && plane(of: $0) == plane(of: viewport) && $0.stack != nil }),
              let referenceStack = reference.stack, let referenceLocation = reference.location else {
            viewport.syncOffset = 0
            return
        }
        if !stack.frameOfReferenceUID.isEmpty && stack.frameOfReferenceUID == referenceStack.frameOfReferenceUID {
            viewport.syncOffset = reference.syncOffset
            follow(reference)
        } else {
            let fraction = Double(reference.index) / Double(max(1, referenceStack.count - 1))
            viewport.go(to: Int((fraction * Double(max(1, stack.count - 1))).rounded()))
            if let aligned = viewport.location {
                viewport.syncOffset = referenceLocation + reference.syncOffset - aligned
            } else {
                viewport.syncOffset = referenceLocation + reference.syncOffset - location
            }
        }
    }

    /// W/L follows across visible viewports when Sync Window is on.
    func connectWindowSync() {
        for viewport in viewports where mpr == nil {
            viewport.onWindowChange = syncWindowLevel ? { [weak self, weak viewport] window in
                guard let self, let viewport else { return }
                for other in self.visible where other !== viewport && (other.slice?.isColor ?? false) == (viewport.slice?.isColor ?? false) {
                    other.setWindowQuietly(window)
                }
            } : nil
        }
    }
}
