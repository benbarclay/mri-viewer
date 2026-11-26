import MRICore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        NavigationSplitView {
            SeriesList(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
        } detail: {
            ViewerPane(store: store)
                .inspector(isPresented: $store.showInspector) {
                    ModelInspector(store: store)
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
                }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in store.open(folder: url) } }
            }
            return true
        }
        .alert("Error", isPresented: Binding(get: { store.errorText != nil }, set: { if !$0 { store.errorText = nil } })) {
            Button("OK") { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }
}

struct SeriesList: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        List(selection: Binding(get: { store.selectedSeriesID }, set: { store.select($0) })) {
            ForEach(store.series) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.description.isEmpty ? "Series \(s.seriesNumber)" : s.description)
                        .lineLimit(1)
                    Text("\(s.acquisitionPlane) · \(s.columns)×\(s.rows)×\(s.slices.count) · \(String(format: "%.2f", s.pixelSpacing.y)) mm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(s.id)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.series.isEmpty && !store.isBusy {
                ContentUnavailableView {
                    Label("No Folder", systemImage: "folder")
                } description: {
                    Text("Open a folder of DICOM files, or drop one here.")
                } actions: {
                    Button("Open Folder…") { store.openPanel() }
                }
            }
        }
    }
}

struct ViewerPane: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        Group {
            if store.reslicer != nil {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        SliceView(plane: .axial, store: store)
                        SliceView(plane: .coronal, store: store)
                    }
                    GridRow {
                        SliceView(plane: .sagittal, store: store)
                        ModelPreview(store: store)
                    }
                }
                .background(Color.black)
            } else if store.isBusy {
                VStack(spacing: 12) {
                    if let p = store.progress { ProgressView(value: p).frame(width: 240) } else { ProgressView() }
                    Text(store.status).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Series Loaded", systemImage: "brain.head.profile",
                                       description: Text("Open a DICOM folder with ⌘O."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(store.selectedSeries?.description ?? "MRI Viewer")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { store.openPanel() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a DICOM folder (⌘O)")
                Button { store.resetWindow() } label: { Label("Reset Window", systemImage: "circle.lefthalf.filled") }
                    .help("Reset window/level (right-drag or ⌥-drag on an image to adjust)")
                    .disabled(store.volume == nil)
                Button { store.showInspector.toggle() } label: { Label("3D Model", systemImage: "cube") }
                    .help("Show the 3D model panel")
            }
        }
    }

    var subtitle: String {
        guard let v = store.volume else { return "" }
        let wl = String(format: "W %.0f  L %.0f", store.windowWidth, store.windowCenter)
        let c = store.cursor
        let value = v.value(c[0], c[1], c[2])
        return "\(v.nx)×\(v.ny)×\(v.nz) · " + String(format: "%.2f×%.2f×%.2f mm", v.spacing.x, v.spacing.y, v.spacing.z)
            + " · \(wl) · value \(Int(value))" + (store.status.isEmpty ? "" : " · \(store.status)")
    }
}

struct ModelPreview: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        ZStack {
            Color.black
            if store.panelMode == .kit, let k = store.kit {
                KitView(kit: k, token: store.kitVersion, explode: store.explode, showHead: store.showHeadInPreview)
                    .overlay(alignment: .bottom) {
                        HStack {
                            Text("Explode").font(.caption)
                            Slider(value: $store.explode, in: 0 ... 1).frame(maxWidth: 160)
                            Toggle("Head", isOn: $store.showHeadInPreview).toggleStyle(.checkbox).font(.caption)
                        }
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    }
            } else if store.panelMode == .kit && store.isBuildingKit {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.kitLog.last ?? "Building kit…").font(.caption).foregroundStyle(.secondary)
                }
            } else if store.panelMode == .kit {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                    Text(store.labels == nil ? "Segment the brain to build a print kit" : "Print kit preview").foregroundStyle(.secondary)
                }
            } else if let m = store.model {
                MeshView(mesh: m.mesh, token: store.modelVersion)
            } else if store.isBuilding {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.modelLog.last ?? "Building…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.secondary)
                    Text("3D model preview").foregroundStyle(.secondary)
                    Button("Generate Model") { store.buildModel() }
                }
            }
        }
    }
}

struct ModelInspector: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $store.panelMode) {
                ForEach(ViewerStore.PanelMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            if store.panelMode == .kit { KitInspector(store: store) } else { singleModel }
        }
    }

    var singleModel: some View {
        Form {
            Section("Model") {
                Picker("Part", selection: Binding(get: { store.options.mode }, set: { store.options.mode = $0; store.modeChanged() })) {
                    ForEach(ModelMode.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Threshold") {
                    Text(String(format: "%.0f", store.effectiveThreshold)).monospacedDigit()
                }
                Slider(value: Binding(get: { store.effectiveThreshold },
                                      set: { store.options.threshold = $0; store.invalidate() }),
                       in: store.thresholdRange)
                HStack {
                    Button("Auto") { store.options.threshold = nil; store.invalidate() }
                        .disabled(store.options.threshold == nil)
                    Spacer()
                    Picker("Overlay", selection: Binding(get: { store.overlay }, set: { store.overlay = $0; store.invalidate() })) {
                        ForEach(OverlayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("Shape") {
                if store.options.mode == .brain {
                    Stepper(value: $store.options.erodeMM, in: 1 ... 10, step: 0.5) {
                        LabeledContent("Detach radius", value: String(format: "%.1f mm", store.options.erodeMM))
                    }
                    .help("Erosion used to separate the brain from the scalp before growing it back.")
                    Toggle("Trim spinal cord", isOn: Binding(get: { store.options.trimTailFraction > 0 },
                                                             set: { store.options.trimTailFraction = $0 ? 0.05 : 0 }))
                }
                Stepper(value: $store.options.smoothMM, in: 0 ... 3, step: 0.25) {
                    LabeledContent("Pre-smoothing", value: String(format: "%.2f mm", store.options.smoothMM))
                }
                Stepper(value: $store.options.taubinIterations, in: 0 ... 50, step: 5) {
                    LabeledContent("Surface smoothing", value: "\(store.options.taubinIterations)")
                }
                Picker("Resolution", selection: $store.options.downsample) {
                    Text("Full").tag(1)
                    Text("½").tag(2)
                    Text("⅓").tag(3)
                }
                Toggle("Fill cavities", isOn: $store.options.fillCavities)
            }
            Section {
                Button(store.isBuilding ? "Building…" : "Generate Model") { store.buildModel() }
                    .disabled(store.volume == nil || store.isBuilding)
                    .keyboardShortcut("g", modifiers: .command)
                Button("Export STL…") { store.exportSTL() }
                    .disabled(store.model == nil)
                    .keyboardShortcut("e", modifiers: .command)
            }
            if let m = store.model {
                Section("Result") {
                    LabeledContent("Triangles", value: m.report.triangles.formatted())
                    LabeledContent("Size", value: String(format: "%.0f × %.0f × %.0f mm", m.report.size.x, m.report.size.y, m.report.size.z))
                    LabeledContent("Volume", value: String(format: "%.0f mL", m.report.volumeMM3 / 1000))
                    LabeledContent("Watertight", value: m.report.isWatertight ? "Yes" : "No")
                    LabeledContent("Pieces", value: "\(m.report.components)")
                }
            }
            if !store.modelLog.isEmpty {
                Section("Log") {
                    ForEach(Array(store.modelLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct KitInspector: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        Form {
            Section("Brain regions") {
                if let src = store.labelsSource {
                    LabeledContent("Segmentation", value: src)
                } else {
                    Text("Brain parts come from an anatomical segmentation (FastSurfer, runs locally).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.segmentationRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("FastSurfer running… \(Int(ctx.date.timeIntervalSince(store.segmentationStarted ?? ctx.date))) s")
                                .font(.caption)
                        }
                    }
                } else {
                    HStack {
                        Button(store.labels == nil ? "Run FastSurfer" : "Re-run") { store.runFastSurfer() }
                            .disabled(ViewerStore.fastSurferHome() == nil || store.volume == nil)
                            .help(ViewerStore.fastSurferHome() == nil ? "FastSurfer for macOS is not installed (see README)" : "Segment this series (a few minutes)")
                        Button("Load Labels…") { store.loadLabelsPanel() }
                            .disabled(store.volume == nil)
                    }
                }
                Toggle("Deep structures as pieces", isOn: Binding(get: { store.kitOptions.deepStructures },
                                                                  set: { store.kitOptions.deepStructures = $0; store.refreshRegions() }))
                    .help("Basal ganglia + thalamus, hippocampus + amygdala and the ventricles as separate inner pieces")
            }
            Section("Head") {
                Toggle("Head shell", isOn: $store.kitOptions.head)
                Toggle("Eyeballs", isOn: $store.kitOptions.eyes).disabled(!store.kitOptions.head)
                Stepper(value: $store.kitOptions.cavityClearanceMM, in: 0.2 ... 3, step: 0.1) {
                    LabeledContent("Brain clearance", value: String(format: "%.1f mm", store.kitOptions.cavityClearanceMM))
                }
                Stepper(value: $store.kitOptions.partGapMM, in: 0 ... 1, step: 0.05) {
                    LabeledContent("Part gap", value: String(format: "%.2f mm", store.kitOptions.partGapMM))
                }
                Toggle("Automatic split height", isOn: Binding(get: { store.kitOptions.headSplitMM == nil },
                                                               set: { store.kitOptions.headSplitMM = $0 ? nil : (store.kit?.splitHeightMM ?? 0) }))
                if let z = store.kitOptions.headSplitMM {
                    Slider(value: Binding(get: { z }, set: { store.kitOptions.headSplitMM = $0 }), in: -60 ... 80) {
                        Text(String(format: "S %.0f mm", z)).monospacedDigit()
                    }
                }
            }
            Section {
                Button(store.isBuildingKit ? "Building…" : "Generate Kit") { store.buildKit() }
                    .disabled(store.labels == nil || store.isBuildingKit)
                Button("Export Kit…") { store.exportKit() }
                    .disabled(store.kit == nil)
            }
            if let k = store.kit {
                Section("Parts (\(k.parts.count))") {
                    ForEach(Array(k.parts.enumerated()), id: \.offset) { _, p in
                        HStack {
                            Circle().fill(Color(red: Double(p.color.x), green: Double(p.color.y), blue: Double(p.color.z))).frame(width: 9, height: 9)
                            Text(p.name)
                            Spacer()
                            Text(String(format: "%.0f mL", p.report.volumeMM3 / 1000)).foregroundStyle(.secondary).monospacedDigit()
                            Image(systemName: p.report.isWatertight ? "checkmark.seal" : "exclamationmark.triangle")
                                .foregroundStyle(p.report.isWatertight ? Color.secondary : Color.orange)
                        }
                        .font(.caption)
                    }
                }
            }
            if !store.kitLog.isEmpty {
                Section("Log") {
                    ForEach(Array(store.kitLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
