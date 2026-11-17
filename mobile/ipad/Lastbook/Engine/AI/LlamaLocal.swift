import Foundation
import CryptoKit
#if canImport(LastbookLLM)
import LastbookLLM
#endif

/// A known local model (Gemma 4 26B A4B, or the small LFM2.5 2.6B), run in this process by llama.cpp (llm/lastbook_llm_bridge.cpp). It mirrors desktop
/// llm_local.Local: the same states, the same once-only size and SHA-256 check (remembered by path, size and modification time),
/// llama.cpp's own fit before loading, a 16,384-token context, idle stop after 15 minutes, one retry after a failed load.
/// Nothing here opens a socket and nothing is downloaded.
///
/// Prewarm (iPad): when Lastbook opens or comes back to the front, an installed, enabled, verified model that
/// fits is loaded in the background, so the first question doesn't wait for it. It is freed on background, quit, memory
/// warning and after 15 minutes unused. After a memory warning it is not loaded again until the next time Lastbook comes to
/// the front (a question still loads it). After an idle stop, the next return to the front loads it again.
///
/// States (desktop names, chat.js localLine) and their phase (the `phase` field, for the iPad's own UI):
///   checking   reading the file to check it (pct)         in_progress
///   measuring  asking llama.cpp how it fits this iPad     in_progress
///   loading    loading (pct)                              in_progress
///   ready      loaded, answering                          ready
///   stopped    found, checked and fits; loads when asked  ready
///   absent     no model file found                        unavailable
///   off        turned off in the app                      unavailable
///   wrong      a file of that name that is not the one    incompatible
///   too_big    it does not fit this iPad's memory         incompatible
///   error      it failed (message)                        failed
final class LlamaLocal: LocalModel, @unchecked Sendable {
    static let CTX = 16384                         // tokens the model holds: the system prompt, sources, the conversation and the answer
    static let RESERVE: Double = 2.5 * 1073741824  // shown with the fit, as desktop; on iPad the fit's own margins decide (see judge)
    static let START_WAIT: TimeInterval = 600      // longest a question waits for the model to load
    static var IDLE_STOP: TimeInterval {           // seconds without a question before the model is freed
        TimeInterval(ProcessInfo.processInfo.environment["LASTBOOK_AI_IDLE_S"].flatMap(Int.init) ?? 15 * 60)
    }
    /// Tests only (Mac harness): slows each load progress step by this many ms, to ask a question while it loads.
    static let testSlowLoadMs = ProcessInfo.processInfo.environment["LASTBOOK_AI_TEST_SLOW_LOAD_MS"].flatMap(Int.init) ?? 0

    static let phases = ["checking": "in_progress", "measuring": "in_progress", "loading": "in_progress", "ready": "ready",
                         "stopped": "ready", "absent": "unavailable", "off": "unavailable", "wrong": "incompatible",
                         "too_big": "incompatible", "error": "failed"]

    private let lock = NSRecursiveLock()
    /// The model this instance runs: the first known one found on disk (LocalAI's KnownModels), Gemma 4 until then.
    private(set) var spec: ModelSpec = Gemma4.spec
    var format: String { spec.format }
    private let genLock = NSLock()                 // one answer at a time: the model holds one conversation
    private let loadSerial = NSLock()              // one load at a time, even while a stopped one is still unwinding
    private(set) var state = "absent"
    private var pct: Int?
    private var message = ""
    private var path: URL?
    private var fit: Rec?
    private var readyInfo: Rec?
    private var handle: OpaquePointer?             // lb_llm *
    private var lastUsed = Date.distantPast
    private var failedLoads = 0
    private var loadToken = 0                      // the current load; a stop or a newer load makes older ones give up
    private var loadStarted = Date()
    private var interrupted: String?               // why the app stopped an answer or a load (background, memory), for the person
    private var generating = false
    private var nextId = 0
    private var saved: Rec
    private var discovering = false
    private var discoveredFor: String?
    private var started = false
    // prewarm
    private var foreground = true
    private var wantLoad = false                   // load as soon as found, checked and measured
    private var blocked: String?                   // "memory": no prewarm until Lastbook next comes to the front
    private var lastPrewarm: Rec = [:]

    let stateFile: URL
    let places: () -> [URL]
    let documents: URL?

    init(stateFile: URL, places: @escaping () -> [URL], documents: URL?) {
        self.stateFile = stateFile
        self.places = places
        self.documents = documents
        saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateFile))) as? Rec ?? [:]
    }

    static var runtime: Bool {
        #if canImport(LastbookLLM)
        return true
        #else
        return false
        #endif
    }

    // -- what the app shows ------------------------------------------------------------------------------------------------
    func status() -> Rec {
        startOnce()
        lock.lock(); defer { lock.unlock() }
        let f = fit ?? [:]
        return ["name": spec.name, "file": spec.file, "size": spec.size, "state": state,
                "phase": Self.phases[state] ?? "failed", "pct": pct as Any? ?? NSNull(), "message": message,
                "found_at": path.map(folderName) as Any? ?? NSNull(), "enabled": enabled, "runtime": Self.runtime,
                "needs_bytes": f["needs"] ?? NSNull(), "ram_total": f["ram_total"] ?? NSNull(), "placement": f["placement"] ?? NSNull(),
                "load_s": readyInfo?["load_s"] ?? NSNull(), "places": places().prefix(6).map(folderName),
                "prewarm": ["wanted": wantLoad, "blocked": blocked as Any? ?? NSNull(), "foreground": foreground,
                            "last": lastPrewarm.isEmpty ? NSNull() : lastPrewarm] as Rec]
    }

    var enabled: Bool { (saved["enabled"] as? Bool) ?? true }

    /// True when a question can be answered, now or once preparing ends: loaded, ready to load, or being checked, measured or
    /// loaded. A question asked while it prepares waits for it (ensureRunning).
    var available: Bool { lock.lock(); defer { lock.unlock() }; return Self.phases[state] == "in_progress" || Self.phases[state] == "ready" }

    /// The first status request looks for the file; a changed library looks again (and, in front, loads what it finds).
    private func startOnce() {
        lock.lock()
        let root = places().first?.path ?? ""
        let again = discoveredFor != root && !discovering && !["checking", "measuring", "loading", "ready"].contains(state)
        let first = !started
        started = true
        if again && !first && foreground && blocked == nil && enabled { wantLoad = true }   // a library picked later
        lock.unlock()
        idleOnce()
        if again { discover() }
    }

    private var idleStarted = false
    private func idleOnce() {
        lock.lock(); let go = !idleStarted; idleStarted = true; lock.unlock()
        if go { Thread.detachNewThread { [weak self] in self?.idleWatch() } }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted]).write(to: stateFile, options: .atomic)
        } catch { NSLog("local AI: could not save its state: \(error)") }
    }

    // -- app lifecycle (LocalAI calls these from UIKit's notifications; the Mac harness calls them directly) ----------------
    func appLaunched() { lock.lock(); foreground = true; blocked = nil; lock.unlock(); prewarm("launch") }

    func willEnterForeground() { lock.lock(); foreground = true; blocked = nil; lock.unlock(); prewarm("foreground") }

    /// iPadOS gives no GPU time in the background: a load stops cleanly and the model is freed.
    func didEnterBackground() { lock.lock(); foreground = false; wantLoad = false; lock.unlock(); stop("background") }

    /// Freed, and not prewarmed again until Lastbook next comes to the front: no unload/reload loop.
    func memoryWarning() { lock.lock(); blocked = "memory"; wantLoad = false; lock.unlock(); stop("memory") }

    func willTerminate() { lock.lock(); wantLoad = false; lock.unlock(); stop("quit") }

    /// Load the model in the background if it is installed, enabled, verified and fits. Idempotent: a prewarm while one is
    /// checking, measuring, loading or loaded changes nothing. Never blocks the caller.
    func prewarm(_ reason: String) {
        idleOnce()
        lock.lock()
        lastPrewarm = ["reason": reason, "at": Date().timeIntervalSince1970, "state": state]
        guard foreground, blocked == nil, enabled, Self.runtime else {
            lastPrewarm["skipped"] = !enabled ? "off" : blocked ?? (foreground ? "no runtime" : "background")
            lock.unlock(); return
        }
        wantLoad = true
        let s = state, known = discoveredFor != nil, fits = (fit?["fits"] as? Bool) == true, disc = discovering, p = path
        lock.unlock()
        if disc || ["checking", "measuring", "loading", "ready"].contains(s) { return }   // joins what is under way
        if s == "stopped" && fits && p != nil && known && fileUnchanged() {
            lock.lock(); if state == "stopped" { spawn(reason) }; lock.unlock()
            return
        }
        if s == "error" && known { lock.lock(); lastPrewarm["skipped"] = "error"; wantLoad = false; lock.unlock(); return }
        discover()   // finds (fast) and checks/measures in the background, then loads because wantLoad is set
    }

    /// Desktop llm_local.mark_checked: the installer downloaded this file and verified its SHA-256 as the bytes arrived, so record
    /// it as checked (by its stamp) instead of reading the whole file again. Only a known model's pinned name, size and hash are accepted.
    @discardableResult
    func markChecked(_ p: URL, sha256: String) -> Bool {
        guard let spec = KnownModels.named(p.lastPathComponent), sha256.lowercased() == spec.sha256,
              let size = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? NSNumber)?.int64Value,
              size == spec.size else { return false }
        lock.lock(); saved["checked"] = stamp(p); saved["bad"] = nil; save(); lock.unlock()
        NSLog("local AI: \(p.lastPathComponent) verified while downloading; recorded as checked")
        return true
    }

    /// The found file is still the one checked (cheap: one stat).
    private func fileUnchanged() -> Bool {
        lock.lock(); let p = path; lock.unlock()
        guard let p else { return false }
        return (saved["checked"] as? [Any]).map(stampEqual(stamp(p))) == true
    }

    // -- finding and checking the file -------------------------------------------------------------------------------------
    /// Finds the file now (a few stats), then checks it if it has not been checked as it is now, and measures the fit, in the
    /// background. Safe to call again (Look again). Never re-reads a file already checked at the same path, size and time.
    func discover() {
        lock.lock()
        if discovering || ["checking", "measuring", "loading", "ready"].contains(state) { lock.unlock(); return }
        discoveredFor = places().first?.path ?? ""
        if !enabled { state = "off"; message = ""; wantLoad = false; lock.unlock(); return }
        if !Self.runtime { state = "error"; message = "This copy of Lastbook has no local AI runtime."; lock.unlock(); return }
        discovering = true
        lock.unlock()
        var found: URL?, foundSpec: ModelSpec?, wrong: (URL, Int64, ModelSpec)?
        for folder in places() {
            for known in KnownModels.all {
                let p = folder.appendingPathComponent(known.file)
                guard let a = try? FileManager.default.attributesOfItem(atPath: p.path), (a[.type] as? FileAttributeType) == .typeRegular,
                      let size = (a[.size] as? NSNumber)?.int64Value else { continue }
                if size == known.size { found = p; foundSpec = known; break }
                if wrong == nil { wrong = (p, size, known) }
            }
            if found != nil { break }
        }
        lock.lock()
        guard let found else {
            defer { discovering = false; wantLoad = false; lock.unlock() }
            pct = nil; path = nil
            if let (p, size, known) = wrong {
                state = "wrong"
                message = "The file in \(folderName(p)) is \(gb(size)) of \(gb(known.size)). " +
                    (size < known.size ? "The copy may not have finished." : "It is not the file Lastbook expects.")
            } else { state = "absent"; message = "" }
            return
        }
        if let foundSpec { spec = foundSpec }
        let st = stamp(found)
        let checked = (saved["checked"] as? [Any]).map(stampEqual(st)) == true
        // The fit is remembered with the check, for this file, context and iPad (memory and system version).
        let fitKey = "\(st[0])|\(st[1])|\(st[2])|\(Self.CTX)|\(ProcessInfo.processInfo.physicalMemory)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let knownFit = checked ? (saved["fit"] as? Rec).flatMap { f -> Rec? in f.s("key") == fitKey ? f["fit"] as? Rec : nil } : nil
        if !checked, (saved["bad"] as? [Any]).map(stampEqual(st)) == true {   // this exact file already failed its check
            state = "wrong"; pct = nil; path = nil; discovering = false; wantLoad = false
            message = "The file in \(folderName(found)) has the right size but different contents. Copy it again."
            lock.unlock()
            return
        }
        state = checked ? (knownFit == nil ? "measuring" : state) : "checking"
        pct = checked ? nil : 0; message = ""
        lock.unlock()
        if let knownFit {
            NSLog("local AI: check and fit remembered for \(found.lastPathComponent); not reading it again")
            lock.lock(); path = found; fit = knownFit; settle(); lock.unlock()
            return
        }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            Thread.current.qualityOfService = .utility
            if !checked {
                guard self.check(found) else {
                    self.lock.lock(); self.discovering = false; self.wantLoad = false
                    if self.state == "wrong" && self.message.contains("different contents") { self.saved["bad"] = st; self.save() }
                    self.lock.unlock(); return
                }
                self.lock.lock(); self.saved["checked"] = st; self.save(); self.lock.unlock()
            }
            self.lock.lock(); self.path = found; self.lock.unlock()
            self.measure(fitKey)
        }
    }

    /// After a check and measure (or remembering them): stopped or too_big, then a wanted load starts. Lock held.
    private func settle() {
        discovering = false
        if (fit?["fits"] as? Bool) == true {
            state = "stopped"; message = ""
            if wantLoad && foreground && blocked == nil { spawn("prewarm") }
        } else {
            state = "too_big"; message = fit?.s("why") ?? ""; wantLoad = false
        }
    }

    private func stamp(_ p: URL) -> [Any] {
        let a = (try? FileManager.default.attributesOfItem(atPath: p.path)) ?? [:]
        let mtime = ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1e9
        return [Self.portable(p.path), (a[.size] as? NSNumber)?.int64Value ?? 0, Int64(mtime)]
    }

    /// The path as it stays valid across app updates. iPadOS may move the app's data container
    /// (/var/mobile/Containers/Data/Application/<UUID>/…) when the app is updated, so an absolute path made a verified
    /// model look new after the 0.2 → 0.3 update and it was hashed again (seen on a physical M1 iPad). Paths inside the
    /// container are kept from the container on ("~/Documents/…"); older absolute entries are read the same way, so they
    /// still count. A bookmarked folder outside the container keeps its absolute path.
    static func portable(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        if let r = path.range(of: #"/Containers/Data/Application/[0-9A-Fa-f-]{36}/"#, options: .regularExpression) {
            return "~/" + path[r.upperBound...]
        }
        return path
    }

    private func stampEqual(_ a: [Any]) -> ([Any]) -> Bool {
        { b in
            b.count == 3 && (b[0] as? String).map(Self.portable) == (a[0] as? String).map(Self.portable)
                && (b[1] as? NSNumber)?.int64Value == (a[1] as? Int64)
                && (b[2] as? NSNumber)?.int64Value == (a[2] as? Int64)
        }
    }

    /// Reads the whole file once to compare the SHA-256 with the published one, showing how far it has got.
    private func check(_ p: URL) -> Bool {
        NSLog("local AI: checking \(p.lastPathComponent) (SHA-256 of the whole file, once)")
        let t0 = Date()
        var h = SHA256()
        var done: Int64 = 0
        do {
            let fh = try FileHandle(forReadingFrom: p)
            defer { try? fh.close() }
            while true {
                let chunk: Data? = try autoreleasepool { try fh.read(upToCount: 8 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                h.update(data: chunk)
                done += Int64(chunk.count)
                let n = Int(done * 100 / spec.size)
                lock.lock(); pct = n; lock.unlock()
            }
        } catch {
            lock.lock(); state = "wrong"; pct = nil; message = "Lastbook could not read the model file (\(type(of: error)))."; lock.unlock()
            return false
        }
        let hex = h.finalize().map { String(format: "%02x", $0) }.joined()
        guard done == spec.size, hex == spec.sha256 else {
            lock.lock(); defer { lock.unlock() }
            state = "wrong"; pct = nil
            message = "The file in \(folderName(p)) has the right size but different contents. Copy it again."
            return false
        }
        NSLog("local AI: check passed in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        return true
    }

    /// llama.cpp's fitting decides where each part of the model goes (no weights are loaded).
    private func measure(_ key: String) {
        lock.lock(); state = "measuring"; pct = nil; message = ""; let p = path; lock.unlock()
        var f: Rec?
        #if canImport(LastbookLLM)
        if let p, let raw = lb_measure(p.path, Int32(Self.CTX), Int32(Self.threads)) {
            f = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? Rec
            lb_string_free(raw)
        }
        #endif
        lock.lock(); defer { lock.unlock() }
        guard let f, f.s("ev") == "fit" else {
            discovering = false; wantLoad = false
            state = "error"; message = "The local AI could not read the model file."
            NSLog("local AI: measure failed: \(String(describing: f))")
            return
        }
        fit = Self.judge(f)
        saved["fit"] = ["key": key, "fit": fit!] as Rec
        save()
        NSLog("local AI: fit \(fit!)")
        settle()
    }

    /// Does it fit this iPad? llama.cpp's fit (common_fit_params) places the model on the Metal device against the memory the
    /// device reports as usable, leaving a 1 GiB margin, as on desktop. On iPad that is the whole decision: the weights stay in
    /// the mapped file, which iPadOS does not count against the app, so the desktop's total-memory sum (device + host + RESERVE
    /// against the computer's RAM) would wrongly refuse the M1 iPad Pro on which this exact model loaded and answered (the
    /// estimate there was 19.0 GB on a 16 GB iPad). There is no blanket RAM floor.
    static func judge(_ fit: Rec) -> Rec {
        let mem = fit["memory"] as? [Rec] ?? []
        let dev = fit.d("device_bytes"), host = fit.d("host_bytes")
        var placement: [Rec] = mem.filter { $0.s("kind") == "device" }.map {
            ["device": $0.str("desc").flatMap { $0.isEmpty ? nil : $0 } ?? $0.s("name"), "bytes": Int64($0.d("model") + $0.d("context") + $0.d("compute")),
             "free": $0["free"] ?? NSNull()]
        }
        placement.append(["device": "memory", "bytes": Int64(host)])
        var out: Rec = ["status": fit["status"] ?? NSNull(), "ram_total": fit["ram_total"] ?? NSNull(), "device_bytes": Int64(dev),
                        "host_bytes": Int64(host), "needs": Int64(dev + host + RESERVE), "model_bytes": Int64(dev + host),
                        "placement": placement, "host_overrides": fit["host_overrides"] ?? NSNull(),
                        "n_gpu_layers": fit["n_gpu_layers"] ?? NSNull(), "app_available": fit["app_available"] ?? NSNull()]
        if fit.s("status") != "fits" {
            out["fits"] = false
            out["why"] = "The local AI does not fit this iPad’s memory."
        } else { out["fits"] = true }
        return out
    }

    static var threads: Int {
        let n = ProcessInfo.processInfo.activeProcessorCount
        #if os(iOS)
        return max(1, min(8, n - 2))      // as the physical iPad test ran it
        #else
        return max(4, min(16, n / 2))     // desktop: about the number of performance cores
        #endif
    }

    // -- running ---------------------------------------------------------------------------------------------------------
    /// Waits for the model, loading it if it is stopped: through checking, measuring and a load already under way (a prewarm
    /// or another question), reporting pct as it goes. nil when ready, "stopped" when the person stopped, else a sentence why
    /// not. A failed load is tried once more (desktop: one retry).
    func ensureRunning(onWait: (Int?) -> Void, cancelled: () -> Bool) -> String? {
        lock.lock()
        let fresh = discoveredFor == nil && !discovering
        lock.unlock()
        if fresh { discover() }
        var spawned = false
        let t0 = Date()
        while Date().timeIntervalSince(t0) < Self.START_WAIT {
            lock.lock()
            if state == "ready" && handle != nil { lastUsed = Date(); lock.unlock(); return nil }
            let s = state, p = pct, m = message, why = interrupted
            let fits = path != nil && (fit?["fits"] as? Bool) == true
            if discovering || ["checking", "measuring", "loading"].contains(s) {
                lock.unlock()
            } else if ["stopped", "error"].contains(s) && fits && !spawned {
                spawned = true
                spawn("question")
                lock.unlock()
                continue
            } else {
                lock.unlock()
                if spawned || s == "stopped" { return why ?? (m.isEmpty ? "The local AI did not start. Ask again to try once more." : m) }
                return m.isEmpty ? Self.unavailable(s) : m
            }
            if cancelled() { return "stopped" }
            onWait(p)
            Thread.sleep(forTimeInterval: 0.25)
        }
        stop("took too long to start")
        return "The local AI took too long to start."
    }

    static func unavailable(_ s: String) -> String {
        ["absent": "The local AI file is not on this iPad. Search and reading still work.",
         "off": "The local AI is turned off. Search and reading still work.",
         "too_big": "The local AI does not fit this iPad’s memory.",
         "wrong": "The local AI file on this iPad is not the right one."][s] ?? "The local AI is not set up on this iPad."
    }

    /// Starts a load on its own background thread (lock held). Utility priority, so Videos, Map and WebKit stay ahead of it.
    private func spawn(_ reason: String) {
        guard let p = path else { return }
        loadToken += 1
        let token = loadToken
        state = "loading"; pct = 0; message = ""; interrupted = nil; wantLoad = false
        loadStarted = Date()
        NSLog("local AI: loading (\(reason))")
        let t = Thread { [weak self] in self?.load(p, token) }
        t.stackSize = 8 << 20
        t.qualityOfService = .utility
        t.name = "local-ai-load"
        t.start()
    }

    fileprivate final class LoadCtx {
        weak var owner: LlamaLocal?
        let token: Int
        init(_ o: LlamaLocal, _ t: Int) { owner = o; token = t }
    }

    /// llama.cpp's progress callback: the load goes on only while it is still the current one.
    fileprivate func loadProgress(_ p: Float, _ token: Int) -> Bool {
        lock.lock()
        let live = token == loadToken && state == "loading"
        if live { pct = min(99, Int(p * 100)) }
        lock.unlock()
        if Self.testSlowLoadMs > 0 { usleep(useconds_t(Self.testSlowLoadMs * 1000)) }
        return live
    }

    private func load(_ p: URL, _ token: Int) {
        #if canImport(LastbookLLM)
        loadSerial.lock()                 // a stopped load still unwinding finishes (and frees) first
        defer { loadSerial.unlock() }
        lock.lock()
        guard token == loadToken && state == "loading" else { lock.unlock(); return }
        lock.unlock()
        var info: UnsafeMutablePointer<CChar>?, err: UnsafeMutablePointer<CChar>?
        let ctx = Unmanaged.passRetained(LoadCtx(self, token))
        defer { ctx.release() }
        let cb: lb_progress_fn = { prog, user in
            let c = Unmanaged<LoadCtx>.fromOpaque(user!).takeUnretainedValue()
            return c.owner?.loadProgress(prog, c.token) ?? false
        }
        let h = lb_load(p.path, Int32(Self.CTX), Int32(Self.threads), cb, ctx.toOpaque(), &info, &err)
        let infoRec = info.flatMap { (try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8))) as? Rec }
        let errRec = err.flatMap { (try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8))) as? Rec }
        if let info { lb_string_free(info) }
        if let err { lb_string_free(err) }
        lock.lock()
        let current = token == loadToken && state == "loading"
        if let h {
            if !current {                 // stopped while it loaded: give the memory straight back
                lock.unlock()
                lb_free(h)
                NSLog("local AI: a stopped load was freed")
                return
            }
            handle = h
            state = "ready"; pct = nil; failedLoads = 0; lastUsed = Date()
            var r = infoRec ?? [:]
            r["load_s"] = (Date().timeIntervalSince(loadStarted) * 10).rounded() / 10
            readyInfo = r
            NSLog("local AI: ready in \(r["load_s"]!) s (\(r.filter { $0.key != "fit" }))")
            lock.unlock()
            return
        }
        defer { lock.unlock() }
        if !current { NSLog("local AI: load stopped"); return }   // the app stopped it (background, memory warning, turned off)
        failedLoads += 1
        NSLog("local AI: load failed \(String(describing: errRec))")
        if failedLoads < 2 {      // once may be chance: the next question tries again
            state = "stopped"
            message = Self.plainError(errRec ?? [:]) + " Ask again to try once more."
        } else {                  // twice in a row: it would fail the same way again
            state = "error"
            message = Self.plainError(errRec ?? [:])
        }
        #endif
    }

    /// Frees the model's memory and stops a load under way. `why` other than "asked" is told to the person if it
    /// interrupted an answer or a load.
    func stop(_ why: String) {
        lock.lock()
        let h = handle
        handle = nil
        let wasLoading = state == "loading"
        if wasLoading { loadToken += 1 }  // the load gives up at its next progress step, then frees what it made
        if generating || wasLoading {
            interrupted = ["background": "The local AI was stopped because Lastbook went to the background. Ask again to continue.",
                           "memory": "iPadOS asked for memory back, so the local AI was stopped. Ask again, or close other apps first.",
                           "quit": "Lastbook is closing."][why]
        }
        if ["ready", "loading", "error"].contains(state), path != nil, (fit?["fits"] as? Bool) == true {
            state = "stopped"; pct = nil
            if why != "decode" { message = "" }
        }
        lock.unlock()
        #if canImport(LastbookLLM)
        if let h {
            NSLog("local AI: stopping (\(why))")
            lb_cancel(h)
            genLock.lock()           // waits for an answer being written to notice the stop
            lb_free(h)
            genLock.unlock()
        } else if wasLoading {
            NSLog("local AI: stopping the load (\(why))")
        }
        #endif
    }

    func setEnabled(_ on: Bool) {
        lock.lock(); saved["enabled"] = on; save(); lock.unlock()
        if on {
            lock.lock(); if state == "off" { state = "absent"; discoveredFor = nil }; lock.unlock()
            prewarm("turned on")
            lock.lock(); let known = discoveredFor != nil; lock.unlock()
            if !known { discover() }
        } else {
            lock.lock(); wantLoad = false; lock.unlock()
            stop("turned off")
            lock.lock(); state = "off"; message = ""; lock.unlock()
        }
    }

    private func idleWatch() {
        while true {
            Thread.sleep(forTimeInterval: min(30, max(1, Self.IDLE_STOP / 4)))
            lock.lock()
            let idle = state == "ready" && !generating && Date().timeIntervalSince(lastUsed) > Self.IDLE_STOP
            lock.unlock()
            // After an idle stop the model loads again when a question comes or when Lastbook next comes to the front.
            if idle { stop("idle") }
        }
    }

    // -- one model turn --------------------------------------------------------------------------------------------------
    /// Streams one answer. Returns the runner's 'done' event, or throws a plain sentence (desktop Local.generate).
    func generate(segments: [Segment], maxTokens: Int, cancelled: @escaping () -> Bool, piece: @escaping (String) -> Void) throws -> Rec {
        #if canImport(LastbookLLM)
        genLock.lock()
        defer { genLock.unlock() }
        lock.lock()
        guard let h = handle, state == "ready" else {
            let m = interrupted ?? (message.isEmpty ? "The local AI is not running." : message)
            lock.unlock()
            throw LocalAIError(m)
        }
        lb_reset(h)                    // under the lock: a stop that comes after this is never lost
        nextId += 1
        let seed = UInt32(1234 + nextId)   // desktop: 1234 + request id
        generating = true
        interrupted = nil
        lastUsed = Date()
        lock.unlock()
        defer { lock.lock(); generating = false; lastUsed = Date(); lock.unlock() }

        // The person's Stop, seen within 0.2 s, as desktop polls it.
        let watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watch.schedule(deadline: .now() + 0.2, repeating: 0.2)
        watch.setEventHandler { if cancelled() { lb_cancel(h) } }
        watch.resume()
        defer { watch.cancel() }

        final class Sink { let f: (String) -> Void; init(_ f: @escaping (String) -> Void) { self.f = f } }
        let sink = Unmanaged.passRetained(Sink(piece))
        defer { sink.release() }
        let pieceCB: lb_piece_fn = { bytes, n, user in
            guard let bytes, n > 0 else { return }
            let s = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(n)), as: UTF8.self)
            Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue().f(s)
        }
        // Segment texts as C strings that live through the call.
        let cstrs = segments.map { strdup($0.text) }
        defer { cstrs.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = cstrs.map { UnsafePointer($0) }
        let specials = segments.map { $0.special }
        let raw = ptrs.withUnsafeBufferPointer { pp in
            specials.withUnsafeBufferPointer { sp in
                lb_generate(h, pp.baseAddress, sp.baseAddress, Int32(segments.count), Int32(maxTokens), 0.2, 64, 0.95, 0.05,
                            seed, spec.stop, pieceCB, sink.toOpaque())
            }
        }
        let ev = raw.flatMap { (try? JSONSerialization.jsonObject(with: Data(String(cString: $0).utf8))) as? Rec } ?? [:]
        if let raw { lb_string_free(raw) }
        if ev.s("ev") == "error" {
            if ev.s("code") == "decode" {   // the desktop runner would have ended here: free it; the next question loads it again
                NSLog("local AI: \(ev)")
                genLockReleasedStop()
            }
            throw LocalAIError(Self.plainError(ev))
        }
        if ev.s("reason") == "cancel", !cancelled() {
            lock.lock(); let why = interrupted; lock.unlock()
            throw LocalAIError(why ?? "The local AI stopped unexpectedly. Ask again to restart it.")
        }
        return ev
        #else
        throw LocalAIError("This copy of Lastbook has no local AI runtime.")
        #endif
    }

    /// After a failed decode, inside generate (the gen lock is held): free the model without waiting on ourselves.
    private func genLockReleasedStop() {
        #if canImport(LastbookLLM)
        lock.lock()
        let h = handle
        handle = nil
        if state == "ready" { state = "stopped"; message = "" }
        lock.unlock()
        if let h { lb_free(h) }
        #endif
    }

    static func plainError(_ ev: Rec) -> String {
        ["too_long": "The question and its sources were too long for the local AI. Start a new chat or ask a shorter question.",
         "load": "The local AI could not load the model file.",
         "context": "There was not enough free memory to start the local AI. Close other apps and ask again.",
         "model_file": "The local AI could not read the model file.",
         "decode": "The local AI stopped while writing. Ask again to restart it."][ev.s("code")]
            ?? (ev.s("msg").isEmpty ? "The local AI failed." : ev.s("msg"))
    }

    // -- helpers ---------------------------------------------------------------------------------------------------------
    private func gb(_ n: Int64) -> String { String(format: "%.1f GB", Double(n) / 1e9) }

    /// Where a file is, as the person sees it in Files.
    func folderName(_ p: URL) -> String {
        let folder = p.pathExtension == "gguf" ? p.deletingLastPathComponent() : p
        if let d = documents?.standardizedFileURL.path, folder.standardizedFileURL.path.hasPrefix(d) {
            let rel = String(folder.standardizedFileURL.path.dropFirst(d.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? "On My iPad › Lastbook" : "On My iPad › Lastbook › " + rel.replacingOccurrences(of: "/", with: " › ")
        }
        return folder.lastPathComponent
    }
}

struct LocalAIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
