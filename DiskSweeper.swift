// DiskSweeper — scan common macOS space hogs ("System Data") and clean them up.
// Build: ./build.sh   Run: open DiskSweeper.app
import SwiftUI
import AppKit

// MARK: - Model

enum Safety: String { case safe = "Safe to delete", review = "Review first", careful = "Careful" }

struct Location: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let hint: String
    let safety: Safety
}

final class Entry: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    let hint: String
    let safety: Safety
    @Published var size: Int64 = -1          // bytes, -1 = scanning
    @Published var children: [Child] = []
    @Published var expanded = false
    @Published var loadingChildren = false
    init(_ l: Location) { name = l.name; path = l.path; hint = l.hint; safety = l.safety }
}

struct Child: Identifiable, Hashable { let id = UUID(); let path: String; let size: Int64 }

let home = NSHomeDirectory()
func h(_ p: String) -> String { home + "/" + p }

let locations: [Location] = [
    .init(name: "User Caches", path: h("Library/Caches"), hint: "App caches. Apps rebuild them.", safety: .safe),
    .init(name: "System Caches", path: "/Library/Caches", hint: "System-wide caches.", safety: .safe),
    .init(name: "User Logs", path: h("Library/Logs"), hint: "Log files & crash reports.", safety: .safe),
    .init(name: "Temp files (var/folders)", path: "/private/var/folders", hint: "Per-user temp/cache. Usually cleared on reboot.", safety: .review),
    .init(name: "Trash", path: h(".Trash"), hint: "Empty the Trash in Finder.", safety: .safe),
    .init(name: "Downloads", path: h("Downloads"), hint: "Old installers, DMGs, zips.", safety: .review),
    .init(name: "Xcode DerivedData", path: h("Library/Developer/Xcode/DerivedData"), hint: "Build products. Fully regenerable.", safety: .safe),
    .init(name: "Xcode Archives", path: h("Library/Developer/Xcode/Archives"), hint: "Old app archives (keep ones you ship dSYMs for).", safety: .review),
    .init(name: "iOS DeviceSupport", path: h("Library/Developer/Xcode/iOS DeviceSupport"), hint: "Symbols for old iOS versions. Re-downloads when needed.", safety: .safe),
    .init(name: "Simulators", path: h("Library/Developer/CoreSimulator/Devices"), hint: "Use `xcrun simctl delete unavailable` for old ones.", safety: .review),
    .init(name: "Simulator Caches", path: h("Library/Developer/CoreSimulator/Caches"), hint: "Dyld caches for simulators.", safety: .safe),
    .init(name: "Simulator Runtimes", path: "/Library/Developer/CoreSimulator/Volumes", hint: "Manage in Xcode > Settings > Platforms.", safety: .careful),
    .init(name: "iPhone/iPad Backups", path: h("Library/Application Support/MobileSync/Backup"), hint: "Local device backups. Can be huge.", safety: .review),
    .init(name: "Docker", path: h("Library/Containers/com.docker.docker"), hint: "Use `docker system prune -a` instead of deleting.", safety: .careful),
    .init(name: "App Containers", path: h("Library/Containers"), hint: "Sandboxed app data. Drill in to find the culprit.", safety: .careful),
    .init(name: "Group Containers", path: h("Library/Group Containers"), hint: "Shared app data (Office, Messages, etc.).", safety: .careful),
    .init(name: "Application Support", path: h("Library/Application Support"), hint: "App data. Leftovers from uninstalled apps are safe.", safety: .careful),
    .init(name: "Mail", path: h("Library/Mail"), hint: "Mail downloads & attachments.", safety: .careful),
    .init(name: "Messages Attachments", path: h("Library/Messages/Attachments"), hint: "Delete in Messages > Settings or Storage settings.", safety: .careful),
    .init(name: "Homebrew", path: "/opt/homebrew", hint: "Run `brew cleanup --prune=all`.", safety: .careful),
    .init(name: "npm cache", path: h(".npm"), hint: "Or `npm cache clean --force`.", safety: .safe),
    .init(name: "~/.cache (pip, uv, HF…)", path: h(".cache"), hint: "Tool caches, incl. HuggingFace models.", safety: .review),
    .init(name: "Gradle", path: h(".gradle"), hint: "Gradle caches.", safety: .safe),
    .init(name: "CocoaPods", path: h("Library/Caches/CocoaPods"), hint: "Pod cache.", safety: .safe),
    .init(name: "Android SDK", path: h("Library/Android/sdk"), hint: "Old system images/emulators.", safety: .review),
    .init(name: "Ollama models", path: h(".ollama"), hint: "Use `ollama rm <model>`.", safety: .review),
    .init(name: "Movies", path: h("Movies"), hint: "Videos, iMovie/Final Cut libraries.", safety: .review),
    .init(name: "Photos/Music libraries", path: h("Pictures"), hint: "Photos library etc.", safety: .careful),
    .init(name: "macOS Installers / Updates", path: "/Library/Updates", hint: "Leftover update payloads.", safety: .review),
]

// MARK: - Helpers

func duBytes(_ path: String) -> Int64 {
    guard FileManager.default.fileExists(atPath: path) else { return 0 }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-sk", "-x", path]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return 0 }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (Int64(s.split(separator: "\t").first ?? "0") ?? 0) * 1024
}

func fmt(_ b: Int64) -> String {
    if b < 0 { return "…" }
    return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func run(_ cmd: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: cmd); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    try? p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

func trash(_ path: String) -> String? {
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); return nil }
    catch { return error.localizedDescription }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var scanning = false
    @Published var bigFiles: [Child] = []
    @Published var scanningFiles = false
    @Published var minFileMB: Double = 500
    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var snapshots: [String] = []

    func refreshDisk() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        Task.detached {
            let s = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
                .split(separator: "\n").map(String.init).filter { $0.contains("com.apple") }
            await MainActor.run { self.snapshots = s }
        }
    }

    func scan() {
        refreshDisk()
        scanning = true
        entries = locations.filter { FileManager.default.fileExists(atPath: $0.path) }.map(Entry.init)
        let list = entries
        Task.detached {
            await withTaskGroup(of: Void.self) { g in
                var i = 0
                for e in list {
                    if i >= 6 { await g.next() }   // limit concurrency
                    i += 1
                    g.addTask {
                        let s = duBytes(e.path)
                        await MainActor.run { e.size = s }
                    }
                }
            }
            await MainActor.run {
                self.entries.sort { $0.size > $1.size }
                self.scanning = false
            }
        }
    }

    func loadChildren(_ e: Entry) {
        e.expanded.toggle()
        guard e.expanded, e.children.isEmpty else { return }
        e.loadingChildren = true
        Task.detached {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: e.path)) ?? []
            var kids: [Child] = []
            await withTaskGroup(of: Child.self) { g in
                var i = 0
                for name in items {
                    if i >= 8 { if let c = await g.next() { kids.append(c) } }
                    i += 1
                    let p = e.path + "/" + name
                    g.addTask { Child(path: p, size: duBytes(p)) }
                }
                for await c in g { kids.append(c) }
            }
            kids.sort { $0.size > $1.size }
            let top = Array(kids.prefix(25))
            await MainActor.run { e.children = top; e.loadingChildren = false }
        }
    }

    func findBigFiles() {
        scanningFiles = true; bigFiles = []
        let min = Int64(minFileMB * 1_000_000)
        Task.detached {
            var found: [Child] = []
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            if let en = fm.enumerator(at: URL(fileURLWithPath: home), includingPropertiesForKeys: keys,
                                      options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) {
                for case let u as URL in en {
                    guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    let s = Int64(v.totalFileAllocatedSize ?? 0)
                    if s >= min { found.append(Child(path: u.path, size: s)) }
                }
            }
            found.sort { $0.size > $1.size }
            let top = Array(found.prefix(200))
            await MainActor.run { self.bigFiles = top; self.scanningFiles = false }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject var store = Store()
    @State var tab = 0
    @State var confirm: Child?
    @State var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("Common Locations").tag(0)
                Text("Large Files").tag(1)
                Text("Tips").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
            Divider()
            switch tab {
            case 0: locationsView
            case 1: bigFilesView
            default: tipsView
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { store.scan() }
        .alert("Move to Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
               presenting: confirm) { c in
            Button("Move to Trash (\(fmt(c.size)))", role: .destructive) {
                if let err = trash(c.path) { message = err } else {
                    store.bigFiles.removeAll { $0.path == c.path }
                    for e in store.entries { e.children.removeAll { $0.path == c.path } }
                    store.refreshDisk()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.path + "\n\nRemember to empty the Trash to actually free the space.") }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }

    var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Disk Sweeper").font(.title2.bold())
                if store.diskTotal > 0 {
                    Text("\(fmt(store.diskFree)) available of \(fmt(store.diskTotal))").foregroundStyle(.secondary)
                    ProgressView(value: Double(store.diskTotal - store.diskFree), total: Double(store.diskTotal))
                        .frame(width: 300)
                }
            }
            Spacer()
            Button("Empty Trash") {
                _ = run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
                store.refreshDisk()
            }
            Button { store.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(store.scanning)
        }.padding()
    }

    var locationsView: some View {
        List {
            if store.scanning { HStack { ProgressView().controlSize(.small); Text("Scanning…") } }
            ForEach(store.entries) { e in EntryRow(entry: e, store: store, confirm: $confirm) }
        }
    }

    var bigFilesView: some View {
        VStack {
            HStack {
                Text("Files in your home folder larger than")
                TextField("", value: $store.minFileMB, format: .number).frame(width: 70)
                Text("MB")
                Button("Find") { store.findBigFiles() }.disabled(store.scanningFiles)
                if store.scanningFiles { ProgressView().controlSize(.small) }
                Spacer()
            }.padding(.horizontal).padding(.top, 8)
            List(store.bigFiles) { c in ChildRow(child: c, confirm: $confirm) }
        }
    }

    var tipsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What is \"System Data\"?").font(.headline)
                Text("macOS lumps caches, logs, Xcode/simulator data, iOS backups, Docker disks, app containers, temp files and Time Machine local snapshots into \"System Data\". The Common Locations tab measures each of these.")
                Text("Time Machine local snapshots: \(store.snapshots.count)").font(.headline)
                ForEach(store.snapshots, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text("Snapshots are purged automatically when space is needed. To remove now, in Terminal: `tmutil thinlocalsnapshots / 999999999999 4`")
                Text("Full Disk Access").font(.headline)
                Text("Some folders (Mail, Messages, Containers) show 0 or too small without Full Disk Access. Grant it in System Settings > Privacy & Security > Full Disk Access, add DiskSweeper.app, then Rescan.")
                Button("Open Full Disk Access settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Text("Handy commands").font(.headline)
                Text("xcrun simctl delete unavailable\nbrew cleanup --prune=all\ndocker system prune -a\nnpm cache clean --force")
                    .font(.body.monospaced()).textSelection(.enabled)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EntryRow: View {
    @ObservedObject var entry: Entry
    let store: Store
    @Binding var confirm: Child?

    var color: Color { entry.safety == .safe ? .green : entry.safety == .review ? .orange : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { store.loadChildren(entry) } label: {
                    Image(systemName: entry.expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }.buttonStyle(.plain)
                VStack(alignment: .leading) {
                    Text(entry.name).bold()
                    Text(entry.hint).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.safety.rawValue).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.2)).clipShape(Capsule())
                Text(fmt(entry.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    .foregroundStyle(entry.size > 5_000_000_000 ? .red : .primary)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.path) } label: {
                    Image(systemName: "folder")
                }.help("Reveal in Finder")
            }
            if entry.expanded {
                if entry.loadingChildren { ProgressView().controlSize(.small).padding(.leading, 30) }
                ForEach(entry.children) { c in ChildRow(child: c, confirm: $confirm).padding(.leading, 30) }
            }
        }.padding(.vertical, 2)
    }
}

struct ChildRow: View {
    let child: Child
    @Binding var confirm: Child?
    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: child.path)).resizable().frame(width: 16, height: 16)
            Text((child.path as NSString).lastPathComponent).lineLimit(1)
            Text((child.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Text(fmt(child.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Button { NSWorkspace.shared.selectFile(child.path, inFileViewerRootedAtPath: "") } label: {
                Image(systemName: "magnifyingglass")
            }.help("Reveal in Finder")
            Button { confirm = child } label: { Image(systemName: "trash") }.help("Move to Trash")
        }
    }
}

@main
struct DiskSweeperApp: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene { WindowGroup { ContentView() } }
}
