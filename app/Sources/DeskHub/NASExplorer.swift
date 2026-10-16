import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLook

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDir: Bool
    let size: Int64?
    let modified: Date?
    var id: String { url.path }
    var ext: String { url.pathExtension.lowercased() }
}

enum SortKey: String, CaseIterable {
    case name = "이름", modified = "수정일", size = "크기", kind = "종류"
}

@MainActor
final class ExplorerModel: ObservableObject {
    let root: URL
    let smbURL: URL?
    let fileStationURL: URL?
    let favorites: [String]

    @Published var current: URL
    @Published var items: [FileItem] = []
    @Published var loading = false
    @Published var mounted = true
    @Published var connecting = false
    @Published var errorText: String?
    @Published var query = ""
    @Published var searchResults: [FileItem]? = nil
    @Published var searching = false
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var foldersFirst = true
    @Published var selection: Set<String> = []
    @Published var previewURL: URL?
    @Published var status: String = ""
    @Published var dropTargeted = false
    @Published var slowLoad = false

    private var back: [URL] = []
    private var fwd: [URL] = []
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var mountTask: Task<Void, Never>?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !fwd.isEmpty }
    var atRoot: Bool { current.standardizedFileURL.path == root.standardizedFileURL.path }

    init(root: String, smb: String, fileStation: String, favorites: [String]) {
        self.root = URL(fileURLWithPath: root, isDirectory: true)
        self.smbURL = URL(string: smb)
        self.fileStationURL = URL(string: fileStation)
        self.favorites = favorites
        self.current = URL(fileURLWithPath: root, isDirectory: true)
        refresh()
        mountTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.pollMount()
            }
        }
    }

    // MARK: 마운트

    private func checkMounted() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func pollMount() {
        let m = checkMounted()
        if m != mounted {
            mounted = m
            if m { connecting = false; navigate(root, record: false) }
        }
    }

    func reconnect() {
        guard let smb = smbURL else { return }
        connecting = true
        NSWorkspace.shared.open(smb)
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if self.checkMounted() {
                    self.mounted = true; self.connecting = false
                    self.navigate(self.root, record: false)
                    return
                }
            }
            self?.connecting = false
        }
    }

    // MARK: 탐색

    func navigate(_ url: URL, record: Bool = true) {
        if record, url.path != current.path { back.append(current); fwd.removeAll() }
        current = url
        selection = []
        searchResults = nil
        query = ""
        refresh()
    }
    func goBack() { guard let u = back.popLast() else { return }; fwd.append(current); current = u; selection = []; searchResults = nil; refresh() }
    func goForward() { guard let u = fwd.popLast() else { return }; back.append(current); current = u; selection = []; searchResults = nil; refresh() }
    func goUp() { guard !atRoot else { return }; navigate(current.deletingLastPathComponent()) }
    func goFavorite(_ rel: String) {
        let u = rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
        navigate(u)
    }

    func refresh() {
        guard checkMounted() else { mounted = false; items = []; return }
        mounted = true
        generation += 1
        let gen = generation
        let dir = current
        loading = true
        slowLoad = false
        errorText = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let self, self.loading, gen == self.generation { self.slowLoad = true }
        }
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
            var out: [FileItem] = []
            var err: String?
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                for u in urls {
                    let rv = try? u.resourceValues(forKeys: Set(keys))
                    let isDir = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
                    out.append(FileItem(url: u, name: u.lastPathComponent, isDir: isDir,
                                        size: isDir ? nil : Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate))
                }
            } catch { err = error.localizedDescription }
            let result = out
            let errFinal = err
            await MainActor.run {
                guard gen == self.generation else { return }
                self.items = result
                self.loading = false
                self.slowLoad = false
                self.errorText = errFinal
                self.updateStatus()
            }
        }
    }

    var sortedItems: [FileItem] { sorted(items) }

    func sorted(_ list: [FileItem]) -> [FileItem] {
        let s = list.sorted { a, b in
            if foldersFirst, a.isDir != b.isDir { return a.isDir }
            var r: Bool
            switch sortKey {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: r = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: r = (a.size ?? -1) < (b.size ?? -1)
            case .kind:
                if a.ext == b.ext { r = a.name.localizedStandardCompare(b.name) == .orderedAscending }
                else { r = a.ext < b.ext }
            }
            return ascending ? r : !r
        }
        return s
    }

    func updateStatus() {
        if let r = searchResults {
            status = "검색 결과 \(r.count)개" + (searching ? " (검색 중…)" : "")
        } else {
            let folders = items.filter(\.isDir).count
            status = "폴더 \(folders) · 파일 \(items.count - folders)" + (selection.isEmpty ? "" : " · 선택 \(selection.count)")
        }
    }

    // MARK: 항목 동작

    func open(_ item: FileItem) {
        if item.isDir { navigate(item.url) } else { NSWorkspace.shared.open(item.url) }
    }
    func openSelected() {
        for it in selectedItems() { open(it); if it.isDir { break } }
    }
    func selectedItems() -> [FileItem] {
        let src = searchResults ?? items
        return src.filter { selection.contains($0.id) }
    }
    func quickLookSelected() {
        if let first = selectedItems().first, !first.isDir { previewURL = first.url }
    }
    func revealInFinder(_ items: [FileItem]) {
        if items.isEmpty { NSWorkspace.shared.open(current) }
        else { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
    }
    func copyPath(_ items: [FileItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }
    func openFileStation() {
        if let u = fileStationURL { NSWorkspace.shared.open(u) }
    }
    func openCurrentInFinder() { NSWorkspace.shared.open(current) }

    func relativePath(_ url: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(r) { return String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return p
    }

    var breadcrumb: [(name: String, url: URL)] {
        var out: [(String, URL)] = [(root.lastPathComponent, root)]
        let rel = relativePath(current)
        guard !rel.isEmpty else { return out }
        var u = root
        for c in rel.split(separator: "/") {
            u = u.appendingPathComponent(String(c), isDirectory: true)
            out.append((String(c), u))
        }
        return out
    }

    // MARK: 복사(드롭)

    func copyIn(_ urls: [URL]) {
        let dest = current
        Task.detached {
            var failed: [String] = []
            for u in urls {
                let target = dest.appendingPathComponent(u.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { failed.append("\(u.lastPathComponent) (이미 있음)"); continue }
                do { try FileManager.default.copyItem(at: u, to: target) } catch { failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            let failedFinal = failed
            await MainActor.run {
                self.refresh()
                if !failedFinal.isEmpty { self.errorText = "복사 실패: " + failedFinal.joined(separator: ", ") }
            }
        }
    }

    // MARK: 검색

    func search(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searchResults = nil; searching = false; updateStatus(); return }
        let base = current
        searching = true
        searchResults = []
        updateStatus()
        searchTask = Task.detached(priority: .userInitiated) {
            var found: [FileItem] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            var scanned = 0
            var lastFlush = Date()
            while let u = en.nextObject() as? URL {
                if Task.isCancelled { return }
                scanned += 1
                if en.level > 7 { en.skipDescendants(); continue }
                if u.lastPathComponent.localizedCaseInsensitiveContains(q) {
                    let rv = try? u.resourceValues(forKeys: Set(keys))
                    let isDir = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
                    found.append(FileItem(url: u, name: u.lastPathComponent, isDir: isDir,
                                          size: isDir ? nil : Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate))
                    if found.count >= 500 { break }
                }
                if Date().timeIntervalSince(lastFlush) > 0.4 {
                    lastFlush = Date()
                    let snap = found
                    await MainActor.run { if !Task.isCancelled { self.searchResults = snap; self.updateStatus() } }
                }
                if scanned > 60000 { break }
            }
            let finalFound = found
            await MainActor.run {
                if Task.isCancelled { return }
                self.searchResults = finalFound
                self.searching = false
                self.updateStatus()
            }
        }
    }
}

// MARK: - 뷰

struct NASWidget: View {
    @ObservedObject var model: ExplorerModel
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        WidgetChrome(kind: .nas, subtitle: model.mounted ? model.relativePath(model.current).isEmpty ? model.root.lastPathComponent : model.relativePath(model.current) : "연결 안 됨") {
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { model.refresh() }
            IconButton(symbol: "folder", help: "현재 폴더를 Finder에서 열기", label: "Finder") { model.openCurrentInFinder() }
            IconButton(symbol: "globe", help: "Synology File Station 열기 (브라우저)", label: "File Station") { model.openFileStation() }
        } content: {
            VStack(spacing: 0) {
                toolbar
                favoritesRow
                Divider().opacity(0.6)
                Group {
                    if !model.mounted { notMounted }
                    else if let results = model.searchResults { fileList(model.sorted(results), showPath: true) }
                    else { fileList(model.sortedItems, showPath: false) }
                }
                Divider().opacity(0.6)
                statusBar
            }
        }
    }

    // 툴바: 뒤로/앞으로/위 · 경로 · 검색 · 정렬
    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).help("뒤로")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).help("앞으로")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }.disabled(model.atRoot).help("상위 폴더 (⌘↑)")
            }
            .buttonStyle(HeaderButtonStyle())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 { Image(systemName: "chevron.right").font(.hub(9)).foregroundStyle(.tertiary) }
                        Button(crumb.name) { model.navigate(crumb.url) }
                            .buttonStyle(.plain)
                            .font(.hub(12.5, weight: idx == model.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == model.breadcrumb.count - 1 ? .primary : .secondary)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.hub(11))
                TextField("이 폴더에서 검색", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.hub(12.5))
                    .focused($searchFocused)
                    .onSubmit { model.search(model.query) }
                    .onChange(of: model.query) { _, v in
                        if v.isEmpty { model.search("") }
                    }
                if !model.query.isEmpty {
                    Button { model.query = ""; model.search("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            .frame(width: 180)

            Menu {
                Picker("정렬", selection: $model.sortKey) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("오름차순", isOn: $model.ascending)
                Toggle("폴더 먼저", isOn: $model.foldersFirst)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("정렬")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("house.fill", model.root.lastPathComponent, active: model.atRoot) { model.goFavorite("") }
                ForEach(model.favorites, id: \.self) { fav in
                    let exists = FileManager.default.fileExists(atPath: model.root.appendingPathComponent(fav).path)
                    chip("star.fill", fav, active: model.relativePath(model.current) == fav) { model.goFavorite(fav) }
                        .opacity(exists || !model.mounted ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 7)
        }
    }

    private func chip(_ symbol: String, _ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.hub(10))
                Text(text).font(.hub(12))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(active ? Color(nsColor: WidgetKind.nas.tint).opacity(0.25) : Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private var notMounted: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.xmark").font(.hub(40)).foregroundStyle(.secondary)
            Text("NAS가 연결되어 있지 않습니다").font(.hub(15, weight: .semibold))
            Text(model.smbURL?.absoluteString ?? "").font(.caption).foregroundStyle(.secondary)
            if model.connecting {
                ProgressView().controlSize(.small)
                Text("연결 중… (Finder 암호 창이 뜨면 입력하세요)").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { model.reconnect() } label: { Label("NAS 연결", systemImage: "link") }
                    .buttonStyle(.borderedProminent)
            }
            Button("File Station (웹)") { model.openFileStation() }.buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fileList(_ list: [FileItem], showPath: Bool) -> some View {
        ZStack {
            List(selection: $model.selection) {
                if list.isEmpty && !model.loading && !model.searching {
                    Text(showPath ? "일치하는 항목이 없습니다" : "빈 폴더")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                }
                ForEach(list) { item in
                    FileRow(item: item, subpath: showPath ? model.relativePath(item.url.deletingLastPathComponent()) : nil)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.open(item) })
                        .onDrag { NSItemProvider(object: item.url as NSURL) }
                        .contextMenu {
                            Button("열기") { model.open(item) }
                            if !item.isDir { Button("훑어보기 (Space)") { model.previewURL = item.url } }
                            Divider()
                            Button("Finder에서 보기") { model.revealInFinder([item]) }
                            Button("경로 복사") { model.copyPath([item]) }
                            if item.isDir { Button("이 폴더를 Finder에서 열기") { NSWorkspace.shared.open(item.url) } }
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .quickLookPreview($model.previewURL)
            .onKeyPress(.space) { model.quickLookSelected(); return .handled }
            .onKeyPress(.return) { model.openSelected(); return .handled }
            .onKeyPress(.upArrow, phases: .down) { kp in
                if kp.modifiers.contains(.command) { model.goUp(); return .handled }
                return .ignored
            }
            .onKeyPress(.downArrow, phases: .down) { kp in
                if kp.modifiers.contains(.command) { model.openSelected(); return .handled }
                return .ignored
            }
            .onKeyPress(.leftArrow, phases: .down) { kp in
                if kp.modifiers.contains(.command) { model.goBack(); return .handled }
                return .ignored
            }
            .onChange(of: model.selection) { _, _ in model.updateStatus() }
            .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                        if let d = data as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) }
                        else if let u = data as? URL { urls.append(u) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    let inside = urls.filter { !$0.path.hasPrefix(model.current.path + "/") || $0.deletingLastPathComponent().path != model.current.path }
                    if !inside.isEmpty { model.copyIn(inside) }
                }
                return true
            }
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                    .allowsHitTesting(false)
            }
            if model.loading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("불러오는 중…").font(.caption).foregroundStyle(.secondary)
                    if model.slowLoad {
                        Text("macOS가 \"네트워크 볼륨 접근\" 권한을 묻는 창을 띄웠다면\n'허용'을 눌러 주세요. (최초 1회)")
                            .font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
                .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(model.status).font(.hub(11)).foregroundStyle(.secondary)
            if let e = model.errorText {
                Text(e).font(.hub(11)).foregroundStyle(.red).lineLimit(1).help(e)
            }
            Spacer()
            Text("더블클릭: 열기 · Space: 훑어보기 · 끌어다 놓기: 복사")
                .font(.hub(10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .padding(.trailing, 14)
    }
}

struct FileRow: View {
    let item: FileItem
    var subpath: String?

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileRow.icon(for: item))
                .resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.hub(13.5)).lineLimit(1).truncationMode(.middle)
                if let s = subpath, !s.isEmpty {
                    Text(s).font(.hub(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let d = item.modified {
                Text(d, format: .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits).hour().minute())
                    .font(.hub(11.5)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 112, alignment: .trailing)
            }
            Text(item.isDir ? "—" : FileRow.bytes.string(fromByteCount: item.size ?? 0))
                .font(.hub(11.5)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private static var iconCache: [String: NSImage] = [:]
    static func icon(for item: FileItem) -> NSImage {
        let key = item.isDir ? "<dir>" : (item.ext.isEmpty ? "<none>" : item.ext)
        if let c = iconCache[key] { return c }
        let img: NSImage
        if item.isDir { img = NSWorkspace.shared.icon(for: .folder) }
        else if let t = UTType(filenameExtension: item.ext) { img = NSWorkspace.shared.icon(for: t) }
        else { img = NSWorkspace.shared.icon(for: .data) }
        iconCache[key] = img
        return img
    }
}
