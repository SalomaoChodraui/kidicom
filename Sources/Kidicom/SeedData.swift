import Foundation
import SwiftData

/// Sample data for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an empty
/// store with realistic studies (short and long names, several modalities).
/// Replace these with your app's own types. Seed only what a person can
/// create in the app, or the snapshots show features no one can use.
@MainActor
enum SeedData {
    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        let context = model.container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<Study>())) ?? 0) == 0 else { return }
        // (patient, id, days ago, description, modalities, images, copied, imported days ago)
        let samples: [(String, String, Int, String, String, Int, Bool, Int)] = [
            ("SILVA^MARIA^C", "102938", 2, "TC TORAX SEM CONTRASTE", "CT", 412, true, 1),
            ("SILVA^MARIA^C", "102938", 400, "TC TORAX SEM CONTRASTE", "CT", 388, true, 30),
            ("OLIVEIRA^JOAO", "553201", 5, "RM CRANIO COM CONTRASTE", "MR", 1_240, false, 3),
            ("SANTOS^ANA^PAULA", "778812", 9, "US ABDOME TOTAL", "US", 46, true, 9),
            ("PEREIRA^CARLOS", "220145", 12, "RX TORAX PA E PERFIL", "CR", 2, true, 12),
            ("COSTA^LUCIA", "901277", 40, "MAMOGRAFIA BILATERAL", "MG", 4, false, 40),
            ("ALMEIDA^RICARDO^JOSE^DE", "431190", 60, "PET-CT ONCOLOGICO CORPO INTEIRO COM CONTRASTE", "PT, CT", 1_620, true, 60),
        ]
        for (index, sample) in samples.enumerated() {
            let study = Study(studyUID: "1.2.826.0.1.3680043.10.999.\(index)")
            study.patientName = sample.0
            study.patientID = sample.1
            study.studyDate = Date.now.addingTimeInterval(Double(-sample.2) * 86_400)
            study.studyDescription = sample.3
            study.modalities = sample.4
            study.imageCount = sample.5
            study.isCopied = sample.6
            study.importedAt = Date.now.addingTimeInterval(Double(-sample.7) * 86_400)
            context.insert(study)
        }
        try? context.save()
    }
}
