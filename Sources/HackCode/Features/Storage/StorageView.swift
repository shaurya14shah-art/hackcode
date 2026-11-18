import SwiftUI
import HackCodeKit

/// 04 STORAGE — disk usage explorer (read-only; actions are staged in SYS.ADMIN for approval).
struct StorageView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.storage
        VStack(spacing: 0) {
            StorageToolbar()
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if let error = vm.error {
                InlineState(kind: .error, title: "Cannot open this folder.", detail: error)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Group {
                        switch vm.viewMode {
                        case .list: EntryList()
                        case .map: StorageTreemap()
                        case .apps: AppsInventoryView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if vm.viewMode != .apps { StorageSidePanel().frame(width: 330) }
                }
                .padding(Theme.Space.m)
            }
        }
        .onAppear { vm.appeared() }
    }
}

private struct StorageToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.storage
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                BracketButton("← BACK", color: Theme.textSecondary) { vm.back() }.disabled(vm.backStack.isEmpty)
                BracketButton("↑ UP", color: Theme.textSecondary) { vm.up() }
                BracketButton(vm.isScanning ? "■ STOP" : "↻ RESCAN", color: vm.isScanning ? Theme.amber : Theme.accent) {
                    vm.isScanning ? vm.cancel() : vm.rescan()
                }
                Text("·").foregroundStyle(Theme.textTertiary)
                ForEach(StorageViewModel.shortcuts, id: \.1) { name, p in
                    BracketButton(name, color: vm.path == p ? Theme.accent : Theme.textTertiary) { vm.open(p) }
                }
                Spacer()
                Picker("", selection: Binding(get: { vm.viewMode }, set: { vm.viewMode = $0 })) {
                    ForEach(StorageViewModel.ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                .help("MAP: tiles sized by disk usage · APPS: installed apps and their CPU architecture")
                if vm.isScanning {
                    ProgressView().controlSize(.small)
                    Text("scanning \(vm.entries.count)/\(vm.childCount) · \(vm.scannedItems.formatted()) items")
                        .font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
                } else if let at = vm.scannedAt {
                    Text("\(vm.scannedItems.formatted()) items · scanned \(at.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if vm.viewMode == .apps {
                HStack(spacing: 4) {
                    Text("$ ls").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
                    Text("/Applications  /Applications/Utilities  ~/Applications").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("bundle Info.plist + Mach-O header · nothing executed").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Font.body)
            } else {
            HStack(spacing: 4) {
                Text("$ du").font(Theme.Font.bodyStrong).foregroundStyle(Theme.amber)
                ForEach(Array(vm.breadcrumbs.enumerated()), id: \.offset) { i, crumb in
                    if i > 0 { Text("/").foregroundStyle(Theme.textTertiary) }
                    Button(crumb.name) { vm.open(crumb.path) }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == vm.breadcrumbs.count - 1 ? Theme.textPrimary : Theme.accentDim)
                }
                Spacer()
                Text(ByteFormat.string(vm.totalBytes, .file) + (vm.isScanning ? "+" : ""))
                    .font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.body)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface.opacity(0.75))
    }
}

private struct EntryList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let vm = app.storage
        let total = max(vm.totalBytes, 1)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("SIZE").frame(width: 90, alignment: .trailing)
                Text("SHARE").frame(width: 170, alignment: .leading).padding(.leading, 12)
                Text("ITEMS").frame(width: 80, alignment: .trailing)
                Text("MODIFIED").frame(width: 96, alignment: .trailing)
            }
            .font(Theme.Font.micro).tracking(0.8).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if vm.entries.isEmpty && !vm.isScanning {
                InlineState(kind: .empty, title: "This folder is empty.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.entries) { e in
                            EntryRow(entry: e, share: Double(e.bytes) / Double(total), selected: vm.selectedPath == e.path)
                                .onTapGesture(count: 2) { vm.enter(e) }
                                .onTapGesture { vm.selectedPath = e.path }
                                .contextMenu {
                                    if e.isDirectory && !e.isProtected { Button("Open") { vm.enter(e) } }
                                    Button("Reveal in Finder") { vm.reveal(e) }
                                    Button("Move to Trash…") { vm.trash(e) }
                                    if e.isDirectory && !e.isProtected {
                                        Divider()
                                        Button("Largest files inside") { vm.largest(in: e.path) }
                                        Button("Duplicates inside") { vm.duplicates(in: e.path) }
                                        Button("Old files inside") { vm.stale(in: e.path) }
                                    }
                                    Button("Copy Path") { copyToPasteboard(e.path) }
                                }
                        }
                    }
                }
            }
        }
        .background(Theme.surface.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { vm.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { vm.moveSelection(1); return .handled }
        .onKeyPress(.return) { if let s = vm.selected { vm.enter(s) }; return .handled }
        .onKeyPress(.leftArrow) { vm.up(); return .handled }
        .onKeyPress(.rightArrow) { if let s = vm.selected { vm.enter(s) }; return .handled }
        .accessibilityHint("Arrow keys select; Return or right arrow opens a folder; left arrow goes up")
    }
}

private struct EntryRow: View {
    let entry: SizedEntry
    let share: Double
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(entry.isDirectory ? (entry.isPackage ? "◆" : "▸") : " ").foregroundStyle(Theme.accentDim).frame(width: 12)
                Text(entry.name).lineLimit(1).truncationMode(.middle).foregroundStyle(entry.isProtected ? Theme.textTertiary : Theme.textPrimary)
                if entry.isProtected { Text("PROTECTED").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).help("Credentials / private data — HackCode never reads inside") }
                if entry.unreadable { Text("NO ACCESS").font(Theme.Font.micro).foregroundStyle(Theme.amber).help("macOS denied access; grant Full Disk Access to include it") }
                if entry.partial { Text("PARTIAL").font(Theme.Font.micro).foregroundStyle(Theme.amber).help("Some items could not be read or the scan limit was reached; size is a lower bound") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isProtected ? "—" : ByteFormat.string(entry.bytes, .file))
                .frame(width: 90, alignment: .trailing).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 6) {
                Meter(fraction: share, color: share > 0.25 ? Theme.amber : Theme.accent).frame(width: 110)
                Text(String(format: "%4.1f%%", share * 100)).foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 170, alignment: .leading).padding(.leading, 12)
            Text(entry.isDirectory ? entry.itemCount.formatted() : "").frame(width: 80, alignment: .trailing).foregroundStyle(Theme.textTertiary)
            Text(entry.modified?.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) ?? "").frame(width: 96, alignment: .trailing).foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Font.caption).monospacedDigit()
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
        .background(selected ? Theme.accent.opacity(0.13) : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.accent).frame(width: 2) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(ByteFormat.string(entry.bytes, .file)), \(Int(share * 100)) percent")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct StorageSidePanel: View {
    @Environment(AppModel.self) private var app
    static var palette: [Color] {
        [Theme.accent, Theme.info, Theme.amber, Color(red: 0.78, green: 0.56, blue: 1.0), Color(red: 1.0, green: 0.52, blue: 0.70),
         Color(red: 0.55, green: 0.85, blue: 0.80), Color(red: 0.95, green: 0.88, blue: 0.45), Theme.textSecondary]
    }

    var body: some View {
        let vm = app.storage
        let top = Array(vm.entries.filter { $0.bytes > 0 }.prefix(7))
        let other = max(0, vm.totalBytes - top.reduce(0) { $0 + $1.bytes })
        let slices: [(String, Int64)] = top.map { ($0.name, $0.bytes) } + (other > 0 ? [("other", other)] : [])
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(text: "Breakdown")
                ZStack {
                    Donut(values: slices.map { Double($0.1) }, colors: Self.palette)
                        .frame(width: 190, height: 190)
                    VStack(spacing: 2) {
                        Text(ByteFormat.string(vm.totalBytes, .file))
                            .font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                        Text((vm.path as NSString).lastPathComponent).font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    .frame(width: 120)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 6) {
                            Rectangle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                            Text(s.0).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(ByteFormat.string(s.1, .file)).foregroundStyle(Theme.textTertiary)
                        }
                        .font(Theme.Font.caption)
                    }
                }
                if let volume = SystemMetrics.volumes().first(where: { vm.path.hasPrefix($0.mountPoint == "/" ? "/" : $0.mountPoint + "/") && ($0.mountPoint != "/" || !vm.path.hasPrefix("/Volumes/")) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        SectionLabel(text: "Volume")
                        Text("\(volume.name): \(ByteFormat.string(volume.availableBytes, .file)) free of \(ByteFormat.string(volume.totalBytes, .file))")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Meter(fraction: Double(volume.totalBytes - volume.availableBytes) / Double(max(volume.totalBytes, 1)))
                    }
                }
                if let s = vm.selected {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "Selected")
                        Text(s.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Text(ByteFormat.string(s.bytes, .file) + (s.isDirectory ? " · \(s.itemCount.formatted()) items" : ""))
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        HStack(spacing: Theme.Space.s) {
                            if s.isDirectory && !s.isProtected { BracketButton("OPEN", color: Theme.accent) { vm.enter(s) } }
                            BracketButton("REVEAL", color: Theme.textSecondary) { vm.reveal(s) }
                            BracketButton("TRASH…", color: Theme.red) { vm.trash(s) }
                        }
                        Text("Actions open in SYS.ADMIN; Move to Trash needs your approval and only works inside Downloads, Desktop, Documents, Movies, Music, Pictures or ~/Library/Caches.")
                            .font(Theme.Font.micro).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "This folder")
                        HStack(spacing: Theme.Space.s) {
                            BracketButton("LARGEST", color: Theme.textSecondary) { vm.largest(in: vm.path) }
                            BracketButton("DUPLICATES", color: Theme.textSecondary) { vm.duplicates(in: vm.path) }
                            BracketButton("OLD FILES", color: Theme.textSecondary) { vm.stale(in: vm.path) }
                        }
                        Text("Double-click a folder to open it · ← goes up.").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Simple donut chart (proportional arcs).
private struct Donut: View {
    let values: [Double]
    let colors: [Color]

    var body: some View {
        Canvas { ctx, size in
            let total = values.reduce(0, +)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            guard total > 0 else {
                ctx.stroke(Path(ellipseIn: rect), with: .color(Theme.border), lineWidth: 18)
                return
            }
            var start = Angle.degrees(-90)
            for (i, v) in values.enumerated() {
                let sweep = Angle.degrees(360 * v / total)
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep - .degrees(sweep.degrees > 2 ? 1 : 0), clockwise: false)
                ctx.stroke(arc, with: .color(colors[i % colors.count]), style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                start += sweep
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Treemap

/// MAP mode: squarified treemap of the current folder (largest 80 items; the rest grouped).
private struct StorageTreemap: View {
    @Environment(AppModel.self) private var app
    @State private var hovered: String?

    struct Tile: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let entry: SizedEntry?
        let count: Int
    }

    static let maxTiles = 80

    static func tiles(_ entries: [SizedEntry]) -> [Tile] {
        let sized = entries.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var out = sized.prefix(maxTiles).map { Tile(id: $0.path, name: $0.name, bytes: $0.bytes, entry: $0, count: 1) }
        let rest = sized.dropFirst(maxTiles)
        if !rest.isEmpty {
            out.append(Tile(id: "…other", name: "\(rest.count) smaller items", bytes: rest.reduce(0) { $0 + $1.bytes }, entry: nil, count: rest.count))
        }
        return out
    }

    var body: some View {
        let vm = app.storage
        let tiles = Self.tiles(vm.entries)
        let total = max(1, tiles.reduce(Int64(0)) { $0 + $1.bytes })
        VStack(spacing: 0) {
            GeometryReader { geo in
                let rects = Treemap.squarify(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                        let r = rects[i]
                        if r.width >= 2 && r.height >= 2 {
                            TileView(tile: tile, share: Double(tile.bytes) / Double(total), size: r.size,
                                     selected: vm.selectedPath == tile.id, hovered: hovered == tile.id)
                                .offset(x: r.minX, y: r.minY)
                                .onHover { inside in
                                    if inside { hovered = tile.id } else if hovered == tile.id { hovered = nil }
                                }
                                .onTapGesture(count: 2) { if let e = tile.entry { vm.enter(e) } }
                                .onTapGesture { if tile.entry != nil { vm.selectedPath = tile.id } }
                                .accessibilityAction { if tile.entry != nil { vm.selectedPath = tile.id } }
                                .accessibilityActions {
                                    if let e = tile.entry, e.isDirectory, !e.isProtected { Button("Open folder") { vm.enter(e) } }
                                }
                                .contextMenu {
                                    if let e = tile.entry {
                                        if e.isDirectory && !e.isProtected { Button("Open") { vm.enter(e) } }
                                        Button("Reveal in Finder") { vm.reveal(e) }
                                        Button("Move to Trash…") { vm.trash(e) }
                                        Button("Copy Path") { copyToPasteboard(e.path) }
                                    }
                                }
                        }
                    }
                }
            }
            .padding(2)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            HStack(spacing: Theme.Space.m) {
                if let id = hovered ?? vm.selectedPath, let t = tiles.first(where: { $0.id == id }) {
                    Text(t.name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(ByteFormat.string(t.bytes)).foregroundStyle(Theme.textSecondary)
                    Text(String(format: "%.1f%%", Double(t.bytes) / Double(total) * 100)).foregroundStyle(Theme.textTertiary)
                    if let e = t.entry, e.isDirectory { Text("\(e.itemCount.formatted()) items").foregroundStyle(Theme.textTertiary) }
                } else {
                    Text("hover a tile for details · double-click a folder to open · right-click for actions")
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                legend(Theme.accent, "folder")
                legend(Theme.amber, "app/package")
                legend(Theme.info, "file")
                legend(Theme.textTertiary, "protected")
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
        }
        .background(Theme.surface.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { vm.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { vm.moveSelection(1); return .handled }
        .onKeyPress(.return) { if let s = vm.selected { vm.enter(s) }; return .handled }
        .onKeyPress(.leftArrow) { vm.up(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage map of \(tiles.count) items")
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.6)).frame(width: 9, height: 9)
            Text(label).foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.Font.micro)
    }
}

private struct TileView: View {
    let tile: StorageTreemap.Tile
    let share: Double
    let size: CGSize
    let selected: Bool
    let hovered: Bool

    private var color: Color {
        guard let e = tile.entry else { return Theme.textTertiary }
        if e.isProtected || e.unreadable { return Theme.textTertiary }
        if e.isPackage { return Theme.amber }
        return e.isDirectory ? Theme.accent : Theme.info
    }

    var body: some View {
        let opacity = min(0.62, 0.16 + sqrt(share) * 0.7) + (hovered ? 0.12 : 0)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(opacity))
            Rectangle().strokeBorder(selected ? Theme.textPrimary : Theme.background.opacity(0.9), lineWidth: selected ? 2 : 1)
            if size.width > 56 && size.height > 28 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.name).font(Theme.Font.caption).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if size.height > 40 {
                        Text(ByteFormat.string(tile.bytes)).font(Theme.Font.micro).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(4)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.name), \(ByteFormat.string(tile.bytes)), \(String(format: "%.0f", share * 100)) percent")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Apps inventory

private struct AppsInventoryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var vm = app.storage
        let all = vm.apps
        let rows = vm.filteredApps
        let intel = all.filter { $0.architecture.needsRosetta }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                if vm.appsScanning {
                    ProgressView().controlSize(.small)
                    Text("reading app bundles…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(all.count) apps").font(Theme.Font.bodyStrong).foregroundStyle(Theme.textPrimary)
                    ForEach(AppArchitecture.allCases, id: \.self) { a in
                        let n = all.filter { $0.architecture == a }.count
                        if n > 0 { Text("\(n) \(a.rawValue.lowercased())").font(Theme.Font.caption).foregroundStyle(Self.color(a)) }
                    }
                }
                Spacer()
                ForEach(StorageViewModel.AppFilter.allCases, id: \.self) { f in
                    BracketButton(f == .intel ? "\(f.rawValue) \(intel.count)" : f.rawValue, color: vm.appFilter == f ? Theme.accent : Theme.textTertiary) { vm.appFilter = f }
                }
                BracketButton("↻ RESCAN", color: Theme.textSecondary) { vm.scanApps() }.disabled(vm.appsScanning)
            }
            .padding(Theme.Space.s)
            if !intel.isEmpty && !vm.appsScanning {
                Text("Intel-only apps run through Rosetta 2 translation on Apple silicon — slower and using more energy — and Apple is phasing Rosetta out. Check each vendor for an Apple-silicon or universal version.")
                    .font(Theme.Font.micro).foregroundStyle(Theme.amber).padding(.horizontal, Theme.Space.s).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            HStack(spacing: 0) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("VERSION").frame(width: 120, alignment: .leading)
                Text("ARCHITECTURE").frame(width: 130, alignment: .leading)
                Text("BUNDLE ID").frame(width: 260, alignment: .leading)
                Text("MODIFIED").frame(width: 96, alignment: .trailing)
            }
            .font(Theme.Font.micro).tracking(0.8).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            Rectangle().fill(Theme.border).frame(height: Theme.hairline)
            if rows.isEmpty && !vm.appsScanning {
                InlineState(kind: .empty, title: vm.appFilter == .intel ? "No Intel-only apps — everything runs natively." : "No apps found.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { a in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Text(a.name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    if a.isApple { Text("apple").font(Theme.Font.micro).foregroundStyle(Theme.textTertiary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(a.version ?? "—").foregroundStyle(Theme.textSecondary).lineLimit(1).frame(width: 120, alignment: .leading)
                                Text(a.architecture.rawValue).font(Theme.Font.micro).tracking(0.6).foregroundStyle(Self.color(a.architecture))
                                    .frame(width: 130, alignment: .leading)
                                Text(a.bundleID ?? "—").foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle).frame(width: 260, alignment: .leading)
                                Text(a.modified.map { Self.date($0) } ?? "—").foregroundStyle(Theme.textTertiary).frame(width: 96, alignment: .trailing)
                            }
                            .font(Theme.Font.caption)
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, 4)
                            .background(vm.selectedApp == a.path ? Theme.accent.opacity(0.12) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.selectedApp = a.path }
                            .contextMenu {
                                Button("Reveal in Finder") { vm.stage("finder.reveal", ["path": .string(a.path)], "Reveal \(a.name) in Finder") }
                                Button("Verify code signature") { vm.stage("security.file_signature", ["path": .string(a.path)], "Code signature of \(a.name)") }
                                Button("Copy Path") { copyToPasteboard(a.path) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .background(Theme.surface.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    static func color(_ a: AppArchitecture) -> Color {
        switch a {
        case .universal, .appleSilicon: return Theme.accent
        case .intel, .missing: return Theme.amber
        case .script, .unknown: return Theme.textTertiary
        }
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd-MMM-yy"
        return f.string(from: d)
    }
}
