import Foundation
import KidicomKit
import SwiftData

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp imports the
/// synthetic sample studies (a chest CT with a prior, an ultrasound cine, a
/// radiograph) through the real importer, so seeded studies are ones a
/// person could import.
enum SeedData {
    static func insertIfRequested(into model: AppModel) async {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        let context = model.container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<Study>())) ?? 0) == 0 else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Kidicom-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? SampleStudies.write(to: folder)) != nil,
              let scan = try? ImportScanner.scan([folder], temporaryRoot: Library.temporary) else { return }
        await model.importer.run(scan, copy: true)
        model.importer.dismissMessage()
        model.selection = nil
        model.sidebar = .all
    }
}
