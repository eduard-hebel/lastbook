import Foundation

/// What one Install does, in order: the Small library (when missing or outdated), the chosen state's map (required), that
/// state's street addresses (required when published), the H.264 video copies (only where this iPad needs them, and only when
/// published), and the local AI model (when supported and wanted). Already-installed, current items are skipped. Nothing
/// downloads until the person starts the run (InstallRunner).
struct PlanItem: Identifiable, Equatable {
    enum Kind: String { case pack, map, addresses, videoCopies, model }
    enum Status: Equatable {
        case installed                  // there and current (checked where a check exists)
        case toDownload                 // will be downloaded and installed by this run
        case unavailable(String)        // needed, but not on the download site: why, and what to do instead
        case unsupported(String)        // this iPad can't use it
        case optedOut                   // the person turned it off (AI)
        case included(String)           // comes with another item of this plan (a pack's own map): nothing to fetch for it
    }
    let id: String                      // "pack:small", "map:RI", "addresses:RI", "videoCopies:small", "model:gemma-4-26b-a4b"
    let kind: Kind
    let title: String
    let downloadBytes: Int64            // the whole download
    let installedBytes: Int64           // room it takes once installed
    var partialBytes: Int64             // already downloaded (a part file to resume)
    var status: Status
    let required: Bool                  // the install is not complete without it
    var note: String?                   // a plain sentence for the person (for example "Not tested on this iPad")
    let entry: CatalogEntry?

    var remainingDownload: Int64 { status == .toDownload ? max(0, downloadBytes - partialBytes) : 0 }
}

struct Plan: Equatable {
    var pack: String = InstallPlan.packID
    var state: String?
    var items: [PlanItem]
    var free: Int64?
    var margin: Int64
    /// The iPad's whole storage, used or not (volumeTotalCapacity), when known.
    var capacity: Int64? = nil
    /// The run can never fit this iPad, even emptied: its peak is more than the iPad holds in all.
    var tooBigForDevice: Bool { capacity.map { spaceNeeded > $0 } ?? false }
    /// Still to download across the items this run installs.
    var downloadBytes: Int64 { items.reduce(0) { $0 + $1.remainingDownload } }
    /// Room the run needs at its fullest: everything installed so far plus the item being downloaded and unpacked, plus margin.
    /// (Each downloaded zip is deleted once installed; an old library or map set is kept until it is deleted.)
    var spaceNeeded: Int64 {
        var kept: Int64 = 0, peak: Int64 = 0
        for i in items where i.status == .toDownload {
            peak = max(peak, kept + i.remainingDownload + i.installedBytes)
            kept += i.installedBytes
        }
        return peak == 0 ? 0 : peak + margin
    }
    var fits: Bool { free.map { spaceNeeded <= $0 } ?? true }
    var toDo: [PlanItem] { items.filter { $0.status == .toDownload } }
    /// Required items that are neither installed nor going to be installed by this run (for example a state not chosen).
    var blockers: [String] {
        var out: [String] = []
        if state == nil { out.append("Choose your state first.") }
        if tooBigForDevice, let c = capacity {
            out.append("This iPad holds \(ByteCountFormatter.string(fromByteCount: c, countStyle: .file)) in all, and this install needs "
                       + "\(ByteCountFormatter.string(fromByteCount: spaceNeeded, countStyle: .file)) free at its fullest, so it can’t fit on this iPad even if it were empty. Choose a smaller pack.")
        }
        for i in items where i.required {
            if case .unavailable(let why) = i.status { out.append(why) }
            if case .unsupported(let why) = i.status { out.append(why) }
        }
        return out
    }
    /// The install is complete: every required item is installed (and checked).
    var complete: Bool { state != nil && items.contains { $0.kind == .map } && items.filter(\.required).allSatisfy { $0.status == .installed } }
}

enum InstallPlan {
    static let packID = "small"                         // iPad default: Small first
    static let testedRAM: UInt64 = 15 << 30             // the 16 GB M1 iPad Pro (it reports 16 GiB) ran this exact model

    /// What the plan reads from this iPad and its library; replaceable in tests.
    struct Env {
        var root: URL?                  // the open library
        var packTarget: URL             // where a downloaded pack goes (Documents/LastbookData)
        var needsH264: Bool
        var av1Missing: Int             // AV1 videos with no copy (0 when not known yet)
        var ram: UInt64
        var aiRuntime: Bool             // this build can run the local AI
        var free: Int64?
        var capacity: Int64? = nil      // the iPad's whole storage

        static func current() -> Env {
            let vc = VideoCompat.shared
            let needs = Installer.needsH264
            return Env(root: Library.shared.root, packTarget: Installer.packTarget, needsH264: needs,
                       av1Missing: Library.shared.root != nil && needs ? vc.coverage().missing : 0,
                       ram: ProcessInfo.processInfo.physicalMemory, aiRuntime: LlamaLocal.runtime,
                       free: ZipInstall.freeSpace(Installer.packTarget.deletingLastPathComponent()),
                       capacity: ZipInstall.totalSpace(Installer.packTarget.deletingLastPathComponent()))
        }
    }

    /// Is the local AI supported here, and has it been tested on an iPad like this one? (default on only when tested)
    static func aiSupport(_ env: Env) -> (supported: Bool, tested: Bool, note: String?) {
        guard env.aiRuntime else { return (false, false, "This copy of Lastbook has no local AI runtime.") }
        if env.ram >= testedRAM { return (true, true, nil) }
        let gb = String(format: "%.0f GB", (Double(env.ram) / 1073741824).rounded())
        return (true, false, "Not tested on an iPad with \(gb) of memory; the local AI may not fit. Lastbook checks the fit after the download and says so.")
    }

    static func defaultWantAI(_ env: Env = .current()) -> Bool { aiSupport(env).tested }

    /// The map each pack carries (desktop pack.json "map"; the download list names only Small's).
    static let builtInMap = ["small": "base", "medium": "CA", "all": "us"]

    static func packTitle(_ id: String) -> String { InstallCatalog.entry(.pack, id)?.title ?? id.capitalized }

    /// The plan for `pack` with `state`'s map and addresses, video copies where needed, and the AI.
    /// `pack` nil: the installed library's pack when the download list knows it, else Small (defaultPack).
    static func make(pack: String? = nil, state: String?, wantAI: Bool, env: Env = .current()) -> Plan {
        let packID = pack ?? defaultPack(env)
        var items: [PlanItem] = []
        func partial(_ e: CatalogEntry?, _ target: URL?) -> Int64 {
            guard let e, let f = e.files.first, let target else { return 0 }
            return min(DownloadInstall.partial(f, target: target), f.size)
        }
        let libTarget = env.root ?? env.packTarget

        // 1. The library. Kept when it is the chosen pack and current (a revision is compared only when the list has one;
        //    Medium and All have none), or a folder the person chose (no pack.json). Another pack is replaced (kept aside).
        let chosen = InstallCatalog.entry(.pack, packID)
        let installedPack = env.root.flatMap { ZipInstall.readJSON($0.appendingPathComponent("pack.json")) }
        let installedName = installedPack?["name"] as? String
        var packStatus: PlanItem.Status = .toDownload
        var packNote: String?
        let haveLibrary = env.root.map(MapInstall.isLibrary) ?? false
        if haveLibrary && (installedName == nil || installedName == packID) {
            if installedName == packID, let rev = chosen?.revision, (installedPack?["content_revision"] as? String) != rev {
                packNote = "A newer \(packTitle(packID)) is published; the library you have is kept until you delete it."
            } else { packStatus = .installed }
        } else if haveLibrary, let installedName {
            packNote = "Replaces the \(packTitle(installedName)) library you have; it is kept until you delete it."
        }
        if packStatus == .toDownload && chosen?.available != true {
            packStatus = .unavailable("\(packTitle(packID)) isn’t on the download site right now. Choose a pack zip or a LastbookData folder in Files.")
        }
        items.append(PlanItem(id: "pack:\(packID)", kind: .pack, title: "Library: \(chosen?.title ?? packTitle(packID))",
                              downloadBytes: chosen?.downloadBytes ?? 0, installedBytes: chosen?.installedBytes ?? 0,
                              partialBytes: packStatus == .toDownload ? partial(chosen, env.packTarget) : 0, status: packStatus,
                              required: true, note: packNote, entry: chosen))
        // The library this run ends with: the one there, or the chosen pack once it is installed.
        let finalPack = packStatus == .installed ? (installedName ?? packID) : packID
        // Its map before any state map: a state map set on the library there, else the pack's own (pack.json "map").
        let finalMap = packStatus == .installed ? (env.root.map(MapInstall.mapName) ?? "base") : (builtInMap[packID] ?? "base")
        let builtIn = packStatus == .installed ? !(env.root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("map-set.json").path) } ?? false) : true

        // 2. The state's map: required, except that All carries the whole US. 3. Its street addresses: required when published.
        if let st = state {
            let me = InstallCatalog.entry(.map, st)
            if finalMap == "us" {
                // desktop: "All needs no state map"; a state map would replace the whole-US one
                items.append(PlanItem(id: "map:us", kind: .map, title: "Whole-US map (in \(packTitle(finalPack)))", downloadBytes: 0,
                                      installedBytes: 0, partialBytes: 0,
                                      status: packStatus == .installed ? .installed : .included("Comes with \(packTitle(finalPack))."),
                                      required: true, note: nil, entry: nil))
            } else {
                let have: Bool = packStatus == .installed && finalMap == st
                    && (builtIn || env.root.map { (try? MapInstall.checkMap($0)) != nil } == true)
                var ms: PlanItem.Status = have ? .installed
                    : me?.available == true ? .toDownload : .unavailable("The \(Installer.title(st)) map isn’t on the download site yet.")
                if packStatus != .installed && finalMap == st { ms = .included("Comes with \(packTitle(finalPack)).") }
                var note: String?
                if ms == .toDownload, builtIn, finalMap != "base", finalMap != st {
                    note = "Replaces the \(Installer.title(finalMap)) map that comes with \(packTitle(finalPack))."
                }
                items.append(PlanItem(id: "map:\(st)", kind: .map, title: "\(Installer.title(st)) map", downloadBytes: me?.downloadBytes ?? 0,
                                      installedBytes: me?.installedBytes ?? 0, partialBytes: ms == .toDownload ? partial(me, libTarget) : 0,
                                      status: ms, required: true, note: note, entry: me))
            }
            let ae = InstallCatalog.entry(.addresses, st)
            if let ae, ae.available {
                let ok = env.root.map { AddressInstall.usable(root: $0, st) } ?? false
                items.append(PlanItem(id: "addresses:\(st)", kind: .addresses, title: "\(Installer.title(st)) street addresses",
                                      downloadBytes: ae.downloadBytes, installedBytes: ae.installedBytes ?? 0,
                                      partialBytes: ok ? 0 : partial(ae, libTarget), status: ok ? .installed : .toDownload,
                                      required: true, note: nil, entry: ae))
            } else {
                items.append(PlanItem(id: "addresses:\(st)", kind: .addresses, title: "\(Installer.title(st)) street addresses",
                                      downloadBytes: 0, installedBytes: 0, partialBytes: 0,
                                      status: .unavailable("Street addresses for \(Installer.title(st)) aren’t published yet; town, ZIP and place search still work."),
                                      required: false, note: nil, entry: nil))
            }
        }

        // 4. H.264 copies: only where this iPad can't decode AV1 (or VP9, when the library has VP9): VideoCompat.needsH264, and
        //    coverage() counts the videos of either kind without a copy. Not published yet: say so, never skip it silently.
        if env.needsH264 {
            let ve = InstallCatalog.entry(.videoCopies, finalPack)
            let known = packStatus == .installed && env.root != nil
            let need = known ? "this iPad needs them for \(env.av1Missing) video\(env.av1Missing == 1 ? "" : "s")"
                             : "this iPad needs them for \(packTitle(finalPack))’s AV1 and VP9 videos"
            let vs: PlanItem.Status = known && env.av1Missing == 0 ? .installed
                : ve?.available == true ? .toDownload : .unavailable("Not available to download yet — \(need); import the zip from Files.")
            items.append(PlanItem(id: "videoCopies:\(finalPack)", kind: .videoCopies, title: "Video copies for this iPad (H.264)",
                                  downloadBytes: ve?.downloadBytes ?? 0, installedBytes: ve?.installedBytes ?? 0,
                                  partialBytes: vs == .toDownload ? partial(ve, libTarget) : 0, status: vs, required: false, note: nil, entry: ve))
        }

        // 5. The local AI model.
        if let mo = InstallCatalog.model {
            let sup = aiSupport(env)
            let placed = modelPlaced(root: env.root)
            let st: PlanItem.Status = placed ? .installed
                : !sup.supported ? .unsupported(sup.note ?? "This iPad can’t run the local AI.")
                : !wantAI ? .optedOut : mo.available ? .toDownload : .unavailable("The local AI isn’t on the download site right now.")
            items.append(PlanItem(id: "model:\(mo.id)", kind: .model, title: "Local AI (\(mo.title))", downloadBytes: mo.downloadBytes,
                                  installedBytes: mo.installedBytes ?? 0, partialBytes: st == .toDownload ? partial(mo, libTarget) : 0,
                                  status: st, required: false, note: sup.note, entry: mo))
        }
        let margin: Int64 = items.contains { $0.kind == .map && $0.status == .toDownload } ? MapInstall.spaceMargin : 512 << 20
        return Plan(pack: packID, state: state, items: items, free: env.free, margin: margin, capacity: env.capacity)
    }

    /// The pack to offer first: the installed library's pack, else Small.
    static func defaultPack(_ env: Env = .current()) -> String {
        let name = env.root.flatMap { ZipInstall.readJSON($0.appendingPathComponent("pack.json")) }?["name"] as? String
        return name.flatMap { InstallCatalog.entry(.pack, $0) != nil ? $0 : nil } ?? packID
    }

    /// The packs a person can choose, with what each takes: (entry, download, installed, room needed at the peak of its step).
    static var packChoices: [(entry: CatalogEntry, download: Int64, installed: Int64, peak: Int64)] {
        InstallCatalog.entries.filter { $0.kind == .pack && $0.available }.map { e in
            (e, e.downloadBytes, e.installedBytes ?? 0, e.downloadBytes + (e.installedBytes ?? 0) + (512 << 20))
        }
    }

    /// The model file, whole, where LocalAI looks for it (the library's models/ folder, the library, Documents).
    static func modelPlaced(root: URL?) -> Bool {
        var places: [URL] = []
        if let root { places += [root.appendingPathComponent("models"), root] }
        places.append(Library.documents)
        return places.contains { folder in KnownModels.all.contains { ZipInstall.size(folder.appendingPathComponent($0.file)) == $0.size } }
    }

    /// Complete: the library and the chosen state's map are installed and check out, and its addresses when they are published.
    static func isComplete(state: String?, env: Env = .current()) -> Bool {
        make(pack: defaultPack(env), state: state, wantAI: false, env: env).complete
    }
}
