import KidicomKit
import SwiftUI

extension SlabMode {
    var title: LocalizedStringResource {
        switch self {
        case .single: "Thin"
        case .mip: "MIP"
        case .minip: "MinIP"
        case .mean: "Mean"
        }
    }
}

/// Slab in the viewer's toolbar: how planes combine (Thin, MIP, MinIP,
/// Mean) and the thickness in mm, for the active viewport.
struct SlabControl: View {
    let viewer: ViewerModel
    @State private var thickness = 10.0

    var body: some View {
        let slab = viewer.activeSlab
        HStack(spacing: Space.sm) {
            // A plain-styled menu: the toolbar shows icons only and would hide a
            // menu's title, but keeps this one's text, drawn as content.
            Menu {
                Picker("Projection", selection: Binding(
                    get: { slab.mode },
                    set: { mode in Task { await viewer.setSlab(mode: mode, mm: thickness) } }
                )) {
                    ForEach(SlabMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: Space.xs) {
                    Text(slab.mode.title)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("How the slab combines its planes: MIP keeps the brightest (vessels, bone), MinIP the darkest (airways, lung), Mean the average")
            // Whole millimeters, without the tick marks a stepped slider draws.
            Slider(value: Binding(get: { thickness }, set: { thickness = $0.rounded() }), in: 1 ... 50)
                .controlSize(.small)
                .frame(width: 80)
                .help("Slab thickness; moving it while Thin turns on MIP")
            Text("\(Int(thickness)) mm")
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(slab.mode.isProjection ? .primary : .secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, Space.xs)
        .disabled(!viewer.canSlab)
        .onAppear { thickness = slab.mm }
        .onChange(of: slab.mm) { _, mm in if mm != thickness { thickness = mm } }
        .onChange(of: thickness) { _, mm in
            let current = viewer.activeSlab
            guard mm != current.mm || !current.mode.isProjection else { return }
            guard viewer.canSlab else { viewer.slabThickness = mm; return }
            // Thin has no thickness: moving the slider turns on MIP.
            Task { await viewer.setSlab(mode: current.mode.isProjection ? current.mode : .mip, mm: mm) }
        }
    }
}
