import Foundation

/// What can be installed: the desktop's download list (manifest-v1.json), bundled as InstallCatalogData. Cleaned like desktop
/// engine/setup/manifest.validate: safe names, SHA-256 digests, https addresses on downloads.lastbook.org only.
/// A zip chosen in Files is matched against it by name and size, and its SHA-256 must equal the listed one.
struct CatalogFile: Equatable { let name: String; let url: String; let size: Int64; let sha256: String }

struct CatalogEntry: Equatable {
    enum Kind: String { case pack, map, addresses, videoCopies, model }
    let kind: Kind
    let id: String
    let title: String
    let installedBytes: Int64?
    let revision: String?
    let files: [CatalogFile]
    let available: Bool
    /// The local AI model only: memory the model and its context need (desktop manifest memory_bytes).
    var memoryBytes: Int64? = nil
    var downloadBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum InstallCatalog {
    static let host = "downloads.lastbook.org"

    static let entries: [CatalogEntry] = (parse(Data(InstallCatalogData.json.utf8)) ?? []) + videoCopies

    /// The H.264 copies of each pack's AV1 videos (iPads without an AV1 decoder). Not on the download site yet, so not
    /// downloadable: the zip is imported from Files (VideoCopiesInstall). When published, list them here like a pack's files.
    static let videoCopies: [CatalogEntry] = [
        CatalogEntry(kind: .videoCopies, id: "small", title: "Video copies for Small", installedBytes: 2_045_641_750, revision: "2026-11-13-small-v2",
                     files: [], available: false),
        // Medium: 273 of 285 copies built (21,682,838,969 bytes); about 27.5 GB when complete.
        CatalogEntry(kind: .videoCopies, id: "medium", title: "Video copies for Medium", installedBytes: 27_500_000_000, revision: nil,
                     files: [], available: false),
        // All: planned; about 100 GB (an estimate until built).
        CatalogEntry(kind: .videoCopies, id: "all", title: "Video copies for All", installedBytes: 100_000_000_000, revision: nil,
                     files: [], available: false),
    ]

    static func isName(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, s.unicodeScalars.count <= 121,
              CharacterSet.alphanumerics.contains(f) && f.isASCII else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    static func isSHA(_ s: String) -> Bool { s.count == 64 && s.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) } }

    static func isAllowedURL(_ s: String) -> Bool {
        guard let u = URLComponents(string: s), u.scheme == "https", u.host?.lowercased() == host, u.user == nil, u.password == nil,
              u.port == nil || u.port == 443 else { return false }
        return true
    }

    /// nil if anything in it is wrong (desktop: the whole manifest is then not used).
    static func parse(_ d: Data) -> [CatalogEntry]? {
        guard let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (m["version"] as? NSNumber)?.intValue == 1 else { return nil }
        func int(_ v: Any?) -> Int64? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n), n.int64Value >= 0 else { return nil }
            return n.int64Value
        }
        func files(_ x: [String: Any]) -> [CatalogFile]? {
            var out: [CatalogFile] = []
            for f in x["files"] as? [[String: Any]] ?? [] {
                guard let name = f["name"] as? String, isName(name), let size = int(f["size"]), let sha = f["sha256"] as? String, isSHA(sha),
                      let url = f["url"] as? String, isAllowedURL(url) else { return nil }
                out.append(CatalogFile(name: name, url: url, size: size, sha256: sha))
            }
            return out
        }
        var out: [CatalogEntry] = []
        for (key, kind) in [("packs", CatalogEntry.Kind.pack), ("maps", .map), ("address_indexes", .addresses)] {
            for x in m[key] as? [[String: Any]] ?? [] {
                guard let id = x["id"] as? String, isName(id), let fs = files(x) else { return nil }
                if kind == .addresses && !(id.count == 2 && id == id.uppercased()) { return nil }
                let rev = x["revision"] as? String
                if let rev, !rev.isEmpty, !isName(rev) { return nil }
                let ib = int(x["installed_bytes"])
                var available = (x["available"] as? Bool ?? false) && !fs.isEmpty
                if kind != .pack { available = available && fs.allSatisfy { $0.size > 0 } }
                if available && ib == nil { return nil }
                out.append(CatalogEntry(kind: kind, id: id, title: (x["title"] as? String) ?? id, installedBytes: ib,
                                        revision: (rev?.isEmpty ?? true) ? nil : rev, files: fs, available: available))
            }
        }
        for x in m["models"] as? [[String: Any]] ?? [] {
            guard let id = x["id"] as? String, isName(id), let file = x["file"] as? String, isName(file), let size = int(x["size"]),
                  let sha = x["sha256"] as? String, isSHA(sha), let url = x["url"] as? String, let u = URL(string: url),
                  Download.urlAllowed(u, .model), let mem = int(x["memory_bytes"]) else { return nil }
            out.append(CatalogEntry(kind: .model, id: id, title: (x["title"] as? String) ?? id, installedBytes: size, revision: nil,
                                    files: [CatalogFile(name: file, url: url, size: size, sha256: sha)],
                                    available: (x["available"] as? Bool) ?? true, memoryBytes: mem))
        }
        return out
    }

    /// The local AI model the app knows (LocalAI's KnownModels identities), if the download list has it.
    static var model: CatalogEntry? {
        entries.first { e in
            guard e.kind == .model, let f = e.files.first, let spec = KnownModels.named(f.name) else { return false }
            return f.sha256 == spec.sha256
        }
    }

    static func entry(_ kind: CatalogEntry.Kind, _ id: String) -> CatalogEntry? { entries.first { $0.kind == kind && $0.id == id } }

    /// The entry and file a chosen zip is, by its name and size (a renamed download is found by size alone when that is unique).
    static func match(fileName: String, size: Int64) -> (CatalogEntry, CatalogFile)? {
        for e in entries { if let f = e.files.first(where: { $0.name == fileName && $0.size == size }) { return (e, f) } }
        let bySize = entries.flatMap { e in e.files.filter { $0.size == size }.map { (e, $0) } }
        return bySize.count == 1 ? bySize[0] : nil
    }

    /// The states (and DC, PR) a state map is listed for, by title.
    static var states: [(id: String, title: String)] {
        entries.filter { $0.kind == .map && $0.available }.map { ($0.id, $0.title) }.sorted { $0.title < $1.title }
    }
}
