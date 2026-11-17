import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The in-process local AI boundary. Lastbook knows three models: Gemma 4 26B A4B (Unsloth UD-Q4_K_M) for machines with
/// the memory for it, and two small ones from Liquid AI, LFM2.5 2.6B and LFM3 1.7B (both Q4_K_M), the size class a
/// phone can hold. All run by llama.cpp dde879bc (the desktop's pinned commit) linked into the app
/// (Engine/AI/LlamaLocal.swift, llm/). There is no cloud AI and no fallback model. Gemma 4 loaded and answered on a
/// physical M1 iPad Pro (16 GB) in testing; the small models are new and still have to prove themselves on a phone.
protocol LocalModel: AnyObject {
    /// "absent", "wrong", "checking", "measuring", "too_big", "stopped", "loading", "ready", "error", "off" (desktop llm_local.Local).
    var state: String { get }
    /// Desktop Local.status(): what /api/assistant/status reports as `local`.
    func status() -> Rec
    /// True when a question can be answered: running, or ready to load.
    var available: Bool { get }
    /// Which prompt format the loaded model speaks: "gemma4", "lfm2" or "lfm3" (desktop llm_local MODELS' format).
    var format: String { get }
    /// Look for the file again (desktop "Look again").
    func discover()
    func setEnabled(_ on: Bool)
    /// The installer verified this file's SHA-256 while downloading it: record it as checked (desktop mark_checked).
    @discardableResult func markChecked(_ path: URL, sha256: String) -> Bool
    /// Loads the model when it is stopped and waits for it. nil when ready, "stopped" when the person stopped, else why not.
    func ensureRunning(onWait: (Int?) -> Void, cancelled: () -> Bool) -> String?
    /// Streams the visible text for an already-rendered prompt in the model's own format (segments of text and special markup, so library text
    /// can never inject turn tokens). Returns the runner's done event; throws a plain sentence.
    func generate(segments: [Segment], maxTokens: Int, cancelled: @escaping () -> Bool, piece: @escaping (String) -> Void) throws -> Rec
    /// Free the model's memory (idle stop, background, memory warning, quit, or asked).
    func stop(_ why: String)
    /// Load in the background if installed, enabled, verified and fitting. Idempotent; never blocks.
    func prewarm(_ reason: String)
    func appLaunched()
    func willEnterForeground()
    func didEnterBackground()
    func memoryWarning()
    func willTerminate()
}

extension LocalModel {
    var format: String { "gemma4" }   // test doubles and older models speak Gemma 4's format
}

/// One known model's pinned identity, copied from desktop llm_local.py's MODELS.
struct ModelSpec {
    let id: String
    let name: String
    let file: String
    let size: Int64
    let sha256: String
    let format: String   // "gemma4", "lfm2" or "lfm3": which prompt format and tool-call notation it uses
    let stop: String     // the token text that ends one of its replies
}

/// Pinned identity of the big model, copied from desktop llm_local.py.
enum Gemma4 {
    static let spec = ModelSpec(id: "gemma-4-26b-a4b", name: "Gemma 4 26B A4B (Unsloth 4-bit, UD-Q4_K_M)",
                                file: "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf", size: 16_947_541_728,
                                sha256: "f2c28b3dc4776931ac6f879e11f203dec637ea0f14267a86ec8f6165f63f293f",
                                format: "gemma4", stop: "<|tool_response>")
    static let file = spec.file
    static let size = spec.size
    static let sha256 = spec.sha256
}

/// Pinned identity of the small model, copied from desktop llm_local.py: Liquid AI's LFM2.5 2.6B, a tenth of
/// Gemma's size, for the phones and small tablets the big model will never fit.
enum LFM25 {
    static let spec = ModelSpec(id: "lfm2.5-2.6b", name: "LFM2.5 2.6B (Liquid AI 4-bit, Q4_K_M)",
                                file: "LFM2.5-2.6B-Q4_K_M.gguf", size: 1_674_455_040,
                                sha256: "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed",
                                format: "lfm2", stop: "<|im_end|>")
    static let file = spec.file
    static let size = spec.size
    static let sha256 = spec.sha256
}

/// Pinned identity of the smallest model, copied from desktop llm_local.py: Liquid AI's LFM3 1.7B, about
/// 1.0 GB on disk, the first one small enough to be the realistic phone option.
enum LFM3 {
    static let spec = ModelSpec(id: "lfm3-1.7b", name: "LFM3 1.7B (Liquid AI 4-bit, Q4_K_M)",
                                file: "LFM3-1.7B-Q4_K_M.gguf", size: 1_099_627_808,
                                sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4",
                                format: "lfm3", stop: "<|im_end|>")
    static let file = spec.file
    static let size = spec.size
    static let sha256 = spec.sha256
}

/// Every model Lastbook knows, biggest first (desktop MODELS): the first one found on disk, in size order per
/// folder, is the one that runs.
enum KnownModels {
    static let all = [Gemma4.spec, LFM25.spec, LFM3.spec]
    static func named(_ file: String) -> ModelSpec? { all.first { $0.file == file } }
}

final class LocalAI: @unchecked Sendable {
    static let shared = LocalAI()
    /// The model. Where it is looked for: the library's LastbookData folder (and its models/ folder, as desktop), then the
    /// app's own Documents folder (Files › On My iPad › Lastbook). Nothing is downloaded.
    var model: LocalModel?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = Library.documents
        model = LlamaLocal(stateFile: support.appendingPathComponent("Lastbook/local-ai.json"), places: {
            var out: [URL] = []
            if let root = Library.shared.root { out += [root.appendingPathComponent("models"), root] }
            out.append(docs)
            var seen = Set<String>()
            return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }, documents: docs)
        watchLifecycle()
    }

    /// The `local` part of /api/assistant/status (desktop Local.status()); also read by Readiness.
    var status: Rec {
        model?.status() ?? ["state": "error", "file": Gemma4.file, "message": "This copy of Lastbook has no local AI runtime."]
    }

    /// Used by the Mac harness: other places and state file.
    init(model: LocalModel?) { self.model = model }

    /// Prewarm when Lastbook opens and each time it comes back to the front. Free the model when it goes to the background,
    /// when iPadOS warns about memory (then no prewarm until the next return to the front) and when Lastbook quits. None of
    /// it runs on the main thread: the model's own work is on a background thread of utility priority.
    private func watchLifecycle() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        let q = DispatchQueue(label: "lastbook.local-ai.lifecycle", qos: .utility)
        // LocalAI.shared is made while the app starts (ChatAPI touches it when the routes are installed in LastbookApp.init):
        // prewarm once the app runs, unless it is starting in the background.
        DispatchQueue.main.async { [weak self] in
            guard UIApplication.shared.applicationState != .background else { return }
            q.async { self?.model?.appLaunched() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            q.async { self?.model?.willEnterForeground() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let m = self?.model else { return }
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "Free the local AI") { UIApplication.shared.endBackgroundTask(task) }
            DispatchQueue.global(qos: .userInitiated).async {
                m.didEnterBackground()
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            guard let m = self?.model else { return }
            DispatchQueue.global(qos: .userInitiated).async { m.memoryWarning() }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.model?.willTerminate()
        }
        #endif
    }
}
