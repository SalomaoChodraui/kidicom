import AppKit
import Foundation

/// Which studies are offline, kept in memory so lists and the viewer do not
/// touch the disk while they draw. A study is checked once when it first
/// shows; after that the disk is checked off the main thread when a volume
/// mounts or unmounts, when the app comes forward, every 30 seconds, and
/// after the Library moves.
@Observable
final class Availability {
    static let shared = Availability()

    /// What a check needs from a study, read once on the main thread.
    nonisolated struct Probe: Sendable {
        /// Any image copied into the Library.
        var hasCopied: Bool
        /// The first image kept in place, for a study that has one.
        var inPlacePath: String?

        @MainActor init(_ study: Study) {
            let images = study.series.lazy.flatMap(\.images)
            // A copied study with images has only copied ones; no need to walk them.
            hasCopied = study.isCopied && study.imageCount > 0 ? true : images.contains(where: \.isCopied)
            inPlacePath = study.isCopied ? nil : images.first(where: { !$0.isCopied })?.fileURL.path
        }

        /// Same rule as `Study.isOffline`.
        func isOffline(libraryAvailable: Bool) -> Bool {
            if !libraryAvailable, hasCopied { return true }
            guard let inPlacePath else { return false }
            return !FileManager.default.fileExists(atPath: inPlacePath)
        }
    }

    @ObservationIgnored private var probes: [UUID: Probe] = [:]
    @ObservationIgnored private var offline: [UUID: Bool] = [:]
    @ObservationIgnored private var libraryAvailable: Bool?
    /// Bumped when a refresh changes something, so views that asked redraw.
    private var revision = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { _ = Availability.shared.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Availability.shared.refresh() }
        })
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refresh()
            }
        }
    }

    /// A Keep in Place study whose files moved or were removed, or a copied
    /// study while a picked Library is missing. Safe to call from a view body.
    func isOffline(_ study: Study) -> Bool {
        _ = revision
        if let known = offline[study.uid] { return known }
        let probe = Probe(study)
        let available = libraryAvailable ?? Library.isAvailable
        libraryAvailable = available
        let value = probe.isOffline(libraryAvailable: available)
        probes[study.uid] = probe
        offline[study.uid] = value
        return value
    }

    /// Drops what is known about studies whose images changed (an import).
    func forget(_ uids: [UUID]) {
        guard !uids.isEmpty else { return }
        for uid in uids {
            probes[uid] = nil
            offline[uid] = nil
        }
        revision += 1
    }

    /// Checks the disk again for every study seen so far, off the main thread.
    /// A refresh asked during another one runs after it, so it sees the disk as it is now.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let previous = refreshing
        let task = Task {
            await previous?.value
            let (available, result) = await Self.check(probes)
            libraryAvailable = available
            var changed = false
            for (uid, value) in result where self.probes[uid] != nil && offline[uid] != value {
                offline[uid] = value
                changed = true
            }
            if changed { revision += 1 }
        }
        refreshing = task
        return task
    }

    @concurrent
    nonisolated private static func check(_ probes: [UUID: Probe]) async -> (Bool, [UUID: Bool]) {
        let available = Library.isAvailable
        return (available, probes.mapValues { $0.isOffline(libraryAvailable: available) })
    }
}
