// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Darwin
import Foundation
import IOKit
internal import VautaMLX

/// `Vauta llm-eval`: EVALUATION ONLY. Runs the app's own minutes code and its Ask path with Apple's on-device model and the
/// integrated Gemma 4, one item at a time with the two providers interleaved (ABAB: which one goes first alternates), and writes
/// one JSON line of measurements per run plus the outputs, for `tools/llm-eval/aggregate.py`. Public or approved transcripts only
/// (the AMI sets of `eval/`), a throwaway encrypted store in a temporary folder, no model server, no audio.
///
/// Per run it records the context (load averages, thermal state), this process's CPU time, energy (`ri_energy_nj`),
/// instructions and cycles from `proc_pid_rusage`, the peak `phys_footprint` (sampled every 50 ms) and, per model call, the
/// prompt and completion tokens, time to first token and total time. Apple's model runs in another process: its cost is not in
/// this process's counters, which the report says (the chip-level figures come from `tools/llm-eval/probe.py`).
public enum LLMEvaluation {
    public struct Options: Sendable {
        public var tasks: Set<String> = ["minutes"]
        public var providers: [String] = ["apple", "integrated"]
        /// `--providers server`: the model server (`--server <config.json>`, the key typed with `--ask-key`). Its runs go through the
        /// app's own client and rules; the minutes and live-answer tasks run on it.
        public var server: EvaluationModel?
        /// `--ask-reasoning on|off|on,off` (live-answer on a model server, after the meeting): Ask on the server's main model reasons
        /// (bounded) or not; with both, each question is asked both ways under `server.reasoning` and `server.plain`. Empty = the release
        /// choice (`AskReasoningRelease.serverAfterMeeting`).
        public var askReasoning: [Bool] = []
        public var sets: URL
        public var questions: URL?
        public var out: URL
        public var seed: UInt64 = 7
        public var greedy = false
        public var only: String?
        public var maxItems: Int?
        /// Seconds to wait before each pair for a quiet Mac; 0 = do not wait. Quiet means load1 below `quietLoad`, no other process of
        /// this user above `quietProcessCPU` percent of a core, and GPU utilisation below `quietGPU` percent. After the wait the pair
        /// runs anyway and its trace says which of the three was not met.
        public var quietWait: Double = 0
        public var quietLoad: Double = 4
        public var quietProcessCPU: Double = 50
        public var quietGPU: Int = 10
        public var repetitions = 1
        /// Prefill the integrated model in chunks of exactly this many tokens (`LanguageModelEngine.setPrefillChunk`) instead of the app's chunks
        /// sized by speed, which change from run to run and with them the bf16 rounding: the same prompt then decodes the same tokens every time.
        public var prefillChunk: Int?
        /// A public transcript the search model embeds in a loop in this process while the runs go on (the concurrency measurement:
        /// both MLX models share the one GPU gate). `embeddings.json` in the output folder has the loop's timings.
        public var embeddingTranscript: URL?
        /// `.document` (bulk indexing, lowest GPU priority: it waits for a running generation) or `.query` (a question's embedding,
        /// interactive priority: it waits at most one chunk or burst).
        public var embeddingPurpose: EmbeddingPurpose = .document
        /// `--search-model <dir>`: the install folder of the search model. The evaluation's embeddings are then that model (verified against
        /// the app's pins) and the services behave as with "Search by meaning on this Mac" chosen; without it embeddings stay off.
        public var searchModelDirectory: URL?
        /// The opened model (set by `run` from `searchModelDirectory`).
        public var searchModel: (any ChunkBudgeting)?
        /// `--tasks retrieval` and `retrieval-controls`: see `RetrievalEvaluation.Options`.
        public var retrieval = RetrievalEvaluation.Options()
        /// `--tasks brief`: see `BriefEvaluation.Options`.
        public var brief = BriefEvaluation.Options()
        /// `--tasks actions`: see `ActionsEvaluation.Options`.
        public var actions = ActionsEvaluation.Options()
        /// `--tasks links`: see `LinksEvaluation.Options`.
        public var links = LinksEvaluation.Options()
        /// Which parts of the integrated minutes are on (A0 to A3 of docs/LANGUAGE_MODEL.md).
        public var arms: MinutesArms = .shipped
        /// Which parts of the extraction of decisions, tasks and owners are on: `.legacy` is the extraction before the current
        /// phase "fix task/decision/owner extraction", `.shipped` the new one (the app's choice is `MinutesRelease.extraction(integrated:)`).
        public var extraction: MinutesExtraction = .ranked
        /// Which parts of the outcome-first summary are on (`--summary old|new`); `.shipped` is the new one, the app's choice is `MinutesSummaryRelease`.
        public var summary: MinutesSummary = .shipped
        /// Which parts of the integrated model's items-first minutes request are on (`--harness old|new`); the app's choice is `MinutesHarnessRelease`.
        public var harness: MinutesHarness = .shipped
        /// Which checks of the minutes' open questions are on (`--open-questions old|new`); the app's choice is `MinutesQuestionsRelease`.
        public var openQuestions: MinutesQuestions = .shipped
        /// `--extraction`, `--summary`, `--harness` or `--open-questions` given as `release`: each backend runs the choices the app ships for it
        /// (`MinutesRelease`, `MinutesSummaryRelease`, `MinutesHarnessRelease`, `MinutesQuestionsRelease`), so one run measures the shipped combination.
        public var release = false
        /// `--variants old,new` (minutes): each provider runs each variant, interleaved per meeting (`LLMEvaluation+Variants.swift`).
        public var variants: [String] = []
        /// Only these meetings (exact names), in the order of the sets folder.
        public var meetings: Set<String>?
        /// `--tasks minutes-replay`: the folder with the result files of an earlier minutes run (`<meeting>.<provider>.json`).
        public var replayFrom: URL?
        /// `--replay-live`: Apple's model answers the final request for real while the block extracts and the closing reply are the recorded ones.
        public var replayLive = false
        /// Replay each meeting as a recording: the integrated model reads it as the segments arrive (the incremental prefix), then the
        /// minutes (or the question) read only what came after.
        public var warm = false
        /// With `warm`: the final speaker labelling numbers the voices the other way round than the live clustering did (as a real
        /// diarization may), so the replay shows whether the lines read during the meeting survive the final step.
        public var renumberFinal = false
        /// With `warm`: the questions are asked after the recording ended (the whole meeting is read while it records, then the recording
        /// stops and each question is about the finished meeting: the finished rules and the meeting's kept prefix).
        public var afterMeeting = false
        /// Which guards of a live answer are on.
        public var guards: AnswerGuards = .shipped
        /// Which parts of Ask's request and retrieval are on (`--ask old|new`); the app's choice is `AskHarnessRelease`. The keyword query is
        /// translated as the app does it only with `.queryTranslation`.
        public var ask: AskHarness = .shipped
        /// Which parts of the notepad expansion on the small window are on (`--notes old|new`); the app's choice is `NoteHarnessRelease`.
        public var notes: NoteHarness = .shipped
        /// Which parts of the live notes are on (`--live old|new`); the app's choice is `LiveHarnessRelease`.
        /// `nil` = `LiveHarness.shipped(integrated:)` for each backend.
        public var live: LiveHarness?
        /// `--ask-windows before=20,after=30,chars=1100,count=5,coverage=2,candidates=40` (`ask-retrieval` only): the shape of the windows.
        public var askWindows: AskWindows = .standard
        /// Apple's "was it decided?" check of the decisions (off by default).
        public var decidedFilter = false
        /// `--output-language <id>`: the minutes are written in this language whatever the meeting's (the translation of the minutes).
        public var outputLanguage: String?
        /// `--tasks notepad`: the shorthand notes of the meetings (`dev/notepad.jsonl`); `--tasks ask-cross`: the cross-meeting questions.
        public var notepad: URL?
        public var crossQuestions: URL?
        /// `--tasks ask-retrieval`: minutes written for the meetings (`<meeting>.server.new.json` as `minutes-eval` keeps them), whose decisions
        /// and tasks are stored before the questions, and the weight of those items as keys of the retrieval (`--item-key-weight`, 0 = off).
        public var minutesItems: URL?
        public var itemKeyWeight: Double?
        /// `live-questions`: the cue threshold, the variant without the model check (V0), the suppression of questions answered aloud,
        /// the sources and the earlier meetings of a series as past meetings.
        public var questionSensitivity: QuestionSensitivity = .standard
        public var questionSkipCheck = false
        public var questionKeepAnsweredAloud = false
        public var questionDetectOnly = false
        /// `live-questions`: the lines are stored and the integrated model reads them as they come, but nothing is detected (the
        /// detection stages never run): the arm "off" of the measurement of the warm model's time to the first token with detection on and off.
        public var questionNoDetection = false
        /// `live-questions`: after the last line one question is asked of the meeting (live rules, the kept prefix), and the time to its first
        /// token is written in the trace (`closingTTFTSeconds`). Run with and without `questionNoDetection` to see what detection costs it.
        public var questionClosingProbe = false
        public var questionSources: LiveAnswerSources = [.thisMeeting, .pastMeetings]
        /// `live-questions`: a folder with one sub folder per meeting (`<meeting>/*.md`), indexed as the documents of that meeting's replay
        /// (use with `--sources this,past,docs`).
        public var questionDocuments: URL?
        /// `live-questions`: the replay waits for the wall clock (a line arrives when it ends), so energy is measured over real time.
        public var questionRealtime = false
        /// Writes every scored sentence of every transcript (for the labelling pool) to this file, then stops.
        public var questionSentences: URL?
        public init(sets: URL, out: URL) {
            self.sets = sets
            self.out = out
        }
    }

    public struct Rusage: Codable, Sendable {
        public var userSeconds = 0.0, systemSeconds = 0.0, energyJoules = 0.0, instructions = 0.0, cycles = 0.0
    }

    public struct Trace: Codable, Sendable {
        public var task: String
        public var provider: String
        public var item: String
        public var pair: Int
        public var order: String
        public var model: String
        public var startedAt: Double
        public var endedAt: Double
        public var wallSeconds: Double
        public var loadAverage: [Double]
        public var loadBucket: String
        public var quietWaitedSeconds: Double
        /// The Mac's other load when the run began (public, sudo-less counters): the sum and the largest of the CPU percentages of
        /// the other processes of this user, and the GPU utilisation from the IORegistry. nil = could not be read.
        public var foreignCpuPct: Double?
        public var foreignTopProcessCpuPct: Double?
        public var gpuUtilPct: Int?
        /// The GPU's "Device Utilization %" sampled once a second during the run: its mean and highest. It includes this process's own
        /// work (the integrated model uses the GPU; Apple's runs elsewhere), so it is not foreign load: `gpuUtilPct` above is (read
        /// before the run starts, when this process is idle).
        public var gpuUtilRunMeanPct: Double?
        public var gpuUtilRunMaxPct: Int?
        public var quiet: Bool?
        /// Memory of the whole Mac when this run began: free + inactive + speculative pages (MB), compressed pages (MB), swap in use
        /// (MB) and the kernel's free-memory level (kern.memorystatus_level, percent). nil = could not be read.
        public var freeMemoryMB: Int?
        public var compressedMB: Int?
        public var swapUsedMB: Int?
        public var memoryLevelPct: Int?
        public var thermalStart: String
        public var thermalEnd: String
        public var peakFootprintMB: Int
        public var ownProcess: Rusage
        public var calls: [EvaluationCall]
        public var detail: [String: String]
        public var error: String?
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func rusage() -> Rusage {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        guard ok == 0 else { return Rusage() }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ns = Double(tb.numer) / Double(tb.denom)
        return Rusage(userSeconds: Double(info.ri_user_time) * ns / 1e9, systemSeconds: Double(info.ri_system_time) * ns / 1e9,
                      energyJoules: Double(info.ri_energy_nj) / 1e9, instructions: Double(info.ri_instructions), cycles: Double(info.ri_cycles))
    }

    static func load() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l
    }

    static func bucket(_ load1: Double) -> String { load1 < 4 ? "quiet" : load1 <= 10 ? "moderate" : "heavy" }

    /// What the rest of the Mac is doing, from public counters that need no privileges.
    struct MachineContext: Sendable {
        var load1: Double
        /// CPU of the other processes of this user, in percent of one core: their sum and the busiest one.
        var foreignCPUSum: Double?
        var foreignCPUTop: Double?
        var gpu: Int?
        var freeMemoryMB: Int?
        var compressedMB: Int?
        var swapUsedMB: Int?
        var memoryLevelPct: Int?

        func isQuiet(_ o: Options) -> Bool {
            load1 < o.quietLoad && (foreignCPUTop ?? 0) < o.quietProcessCPU && (gpu ?? 0) < o.quietGPU
        }
    }

    /// CPU time of every other process of this user over `window` seconds (proc_pid_rusage, like probe.py). Processes of other
    /// users cannot be read without privileges and are not counted.
    static func foreignCPU(window: Double = 0.5) async -> (sum: Double, top: Double)? {
        func snapshot() -> [Int32: UInt64]? {
            let capacity = proc_listallpids(nil, 0)
            guard capacity > 0 else { return nil }
            var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard n > 0 else { return nil }
            var out: [Int32: UInt64] = [:]
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            for pid in pids.prefix(Int(n)) where pid > 0 && pid != getpid() {
                var info = rusage_info_current()
                let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) } }
                guard ok == 0 else { continue }
                out[pid] = (info.ri_user_time &+ info.ri_system_time) &* UInt64(tb.numer) / UInt64(tb.denom)
            }
            return out
        }
        let start = Date()
        guard let a = snapshot() else { return nil }
        try? await Task.sleep(for: .seconds(window))
        guard let b = snapshot() else { return nil }
        let elapsed = Date().timeIntervalSince(start) * 1e9
        var sum = 0.0, top = 0.0
        for (pid, after) in b {
            guard let before = a[pid], after >= before else { continue }
            let pct = Double(after - before) / elapsed * 100
            sum += pct
            top = max(top, pct)
        }
        return (sum, top)
    }

    /// "Device Utilization %" of the GPU from the IORegistry (public IOKit), the highest of the accelerators; nil when absent.
    static func gpuUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any],
                  let util = stats["Device Utilization %"] as? Int else { continue }
            best = max(best ?? 0, util)
        }
        return best
    }

    /// What `--print-context` shows: the same readings a run records before it starts (no model is loaded).
    public static func contextLine() async -> String {
        let c = await machineContext()
        let object: [String: Any?] = ["load1": c.load1, "foreignCpuPct": c.foreignCPUSum, "foreignTopProcessCpuPct": c.foreignCPUTop, "gpuUtilPct": c.gpu,
                                      "freeMemoryMB": c.freeMemoryMB, "swapUsedMB": c.swapUsedMB, "memoryLevelPct": c.memoryLevelPct]
        let clean = object.compactMapValues { $0 }
        return (try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func machineContext() async -> MachineContext {
        let cpu = await foreignCPU()
        let mem = memory()
        return MachineContext(load1: load()[0], foreignCPUSum: cpu?.sum, foreignCPUTop: cpu?.top, gpu: gpuUtilization(),
                              freeMemoryMB: mem.free, compressedMB: mem.compressed, swapUsedMB: mem.swap, memoryLevelPct: mem.level)
    }

    /// Free memory, compressed pages, swap in use and the memory-pressure level of the whole Mac (public, sudo-less).
    static func memory() -> (free: Int?, compressed: Int?, swap: Int?, level: Int?) {
        var free: Int?, compressed: Int?, swap: Int?, level: Int?
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if ok == KERN_SUCCESS {
            let page = sysconf(_SC_PAGESIZE)
            // `>>` binds tighter than `*` in Swift: the products need their parentheses (without them both figures were always 0).
            free = ((Int(stats.free_count) + Int(stats.inactive_count) + Int(stats.speculative_count)) * page) >> 20
            compressed = (Int(stats.compressor_page_count) * page) >> 20
        }
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 { swap = Int(usage.xsu_used >> 20) }
        var l: Int32 = 0
        var ls = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &l, &ls, nil, 0) == 0 { level = Int(l) }
        return (free, compressed, swap, level)
    }

    /// Waits up to `seconds` for a quiet Mac (see `Options.quietWait`); returns how long it waited and what it saw last.
    static func waitForQuiet(_ o: Options) async -> (waited: Double, context: MachineContext) {
        let start = Date()
        var context = await machineContext()
        while o.quietWait > 0, !context.isQuiet(o), Date().timeIntervalSince(start) < o.quietWait {
            try? await Task.sleep(for: .seconds(2))
            context = await machineContext()
        }
        return (Date().timeIntervalSince(start), context)
    }

    /// The GPU's utilisation once a second while a run goes on (public IOKit counters).
    final class GPUSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Int] = []
        private var task: Task<Void, Never>?
        func start() {
            task = Task.detached { [self] in
                while !Task.isCancelled {
                    if let u = LLMEvaluation.gpuUtilization() { lock.withLock { samples.append(u) } }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        func stop() -> (mean: Double?, max: Int?) {
            task?.cancel()
            return lock.withLock { (samples.isEmpty ? nil : Double(samples.reduce(0, +)) / Double(samples.count), samples.max()) }
        }
    }

    final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0
        private var task: Task<Void, Never>?
        func start() {
            task = Task.detached { [self] in
                while !Task.isCancelled {
                    let mb = MLXRuntime.physFootprintMB()
                    lock.withLock { peak = max(peak, mb) }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        func stop() -> Int {
            task?.cancel()
            return lock.withLock { max(peak, MLXRuntime.physFootprintMB()) }
        }
    }

    static func model(_ kind: String, store: LanguageModelStore, greedy: Bool, engine: LanguageModelEngine, server: EvaluationModel? = nil) -> EvaluationModel {
        switch kind {
        case "apple": .apple
        case "server": server ?? EvaluationModel(name: "Model server", kind: "server") { (AppleChatModel(), 0, nil, "no --server configuration") }
        default: .integrated(store: store, greedy: greedy, engine: engine)
        }
    }

    /// Runs `body` with the measurements around it.
    /// The machine context is sampled here, right before each run (the pair-level wait only decides when a pair starts: the second
    /// run of a pair can begin minutes later under a different load).
    static func measure(task: String, provider: String, item: String, pair: Int, order: String, model: EvaluationModel, waited: Double, options: Options? = nil,
                        body: () async throws -> (calls: [EvaluationCall], detail: [String: String])) async -> Trace {
        let context = await machineContext()
        let load0 = load()
        let thermal0 = thermal()
        let r0 = rusage()
        let sampler = FootprintSampler()
        sampler.start()
        let gpuSampler = GPUSampler()
        gpuSampler.start()
        let t0 = Date()
        var calls: [EvaluationCall] = [], detail: [String: String] = [:], failure: String?
        do { (calls, detail) = try await body() } catch let e { failure = "\(e)"; calls = (e as? CallsCarrying)?.calls ?? [] }
        let t1 = Date()
        let peak = sampler.stop()
        let gpuRun = gpuSampler.stop()
        let r1 = rusage()
        let delta = Rusage(userSeconds: r1.userSeconds - r0.userSeconds, systemSeconds: r1.systemSeconds - r0.systemSeconds,
                           energyJoules: r1.energyJoules - r0.energyJoules, instructions: r1.instructions - r0.instructions, cycles: r1.cycles - r0.cycles)
        return Trace(task: task, provider: provider, item: item, pair: pair, order: order, model: model.name, startedAt: t0.timeIntervalSince1970,
                     endedAt: t1.timeIntervalSince1970, wallSeconds: t1.timeIntervalSince(t0), loadAverage: load0, loadBucket: bucket(load0[0]),
                     quietWaitedSeconds: waited, foreignCpuPct: context.foreignCPUSum, foreignTopProcessCpuPct: context.foreignCPUTop, gpuUtilPct: context.gpu,
                     gpuUtilRunMeanPct: gpuRun.mean, gpuUtilRunMaxPct: gpuRun.max, quiet: options.map { context.isQuiet($0) },
                     freeMemoryMB: context.freeMemoryMB, compressedMB: context.compressedMB, swapUsedMB: context.swapUsedMB, memoryLevelPct: context.memoryLevelPct, thermalStart: thermal0, thermalEnd: thermal(), peakFootprintMB: peak, ownProcess: delta,
                     calls: calls, detail: detail, error: failure)
    }

    // MARK: Entry point

    public static func run(_ options: Options, store: LanguageModelStore, log: @escaping @Sendable (String) -> Void) async throws {
        var o = options
        try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        defer { EvaluationDefaults.remove() }   // the one place that removes the suite for this command
        if let directory = o.searchModelDirectory {
            o.searchModel = try await EvaluationSearchModel.open(directory: directory)
            log("search model verified against the pinned manifest and loaded")
        }
        // The model is unloaded before the command returns (a detached task could be cut off by the process ending).
        let model = o.searchModel as? EvaluationSearchModel
        do { try await runTasks(o, store: store, log: log) } catch {
            await model?.unload()
            throw error
        }
        await model?.unload()
    }

    private static func runTasks(_ o: Options, store: LanguageModelStore, log: @escaping @Sendable (String) -> Void) async throws {
        // The retrieval tasks need no language model: they run the app's retrieval only.
        if o.tasks.isSubset(of: ["retrieval", "retrieval-controls"]) {
            if o.tasks.contains("retrieval") { try await RetrievalEvaluation.run(o, log: log) }
            if o.tasks.contains("retrieval-controls") { try await RetrievalEvaluation.runControls(o, log: log) }
            return
        }
        // The echo sweep needs no model either: simulated echoes through `EchoDetection`.
        if o.tasks == ["echo"] {
            try EchoEvaluation.run(o, log: log)
            return
        }
        // Apple's own token counts against Vauta's estimate: no generation.
        if o.tasks == ["token-count"] { try await TokenCountEvaluation.run(o, log: log); return }
        let engine = LanguageModelEngine(store: store)
        if let n = o.prefillChunk { await engine.setPrefillChunk(n) }
        if o.tasks == ["ask-retrieval"] {   // no model call: Apple's model object is only handed to the service
            try await runAskRetrieval(o, store: store, engine: engine)
            return
        }
        if o.providers.contains("integrated"), !o.tasks.isSubset(of: ["brief", "actions", "links", "minutes-replay"]) || (o.tasks.contains("brief") && o.brief.needsIntegrated) || (o.tasks.contains("actions") && o.actions.needsModel) || (o.tasks.contains("links") && o.links.needsIntegratedModel(providers: o.providers)) {
            guard case .installed = store.disk() else { throw MinutesEvaluation.Failure.modelUnavailable("the language model is not installed") }
            await engine.setKeepWarm(true)
            try await engine.load()
        }
        if o.providers.contains("server") { try await checkServer(o.server, log: log) }
        let traces = o.out.appendingPathComponent("traces.jsonl")
        FileManager.default.createFile(atPath: traces.path, contents: nil)
        let handle = try FileHandle(forWritingTo: traces)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func write(_ t: Trace) {
            if let d = try? encoder.encode(t) { handle.write(d); handle.write(Data("\n".utf8)) }
            log("\(t.task) \(t.provider) \(t.item) \(String(format: "%.1f", t.wallSeconds)) s calls \(t.calls.count) \(t.error.map { "ERROR \($0)" } ?? "ok") load1 \(String(format: "%.1f", t.loadAverage[0]))")
        }
        let stop = StopFlag()
        var embeddings: Task<EmbeddingLoop.Report, Error>?
        if let file = o.embeddingTranscript {
            guard let data = FileManager.default.contents(atPath: file.path), let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else {
                throw MinutesEvaluation.Failure.noAnswer
            }
            let purpose = o.embeddingPurpose
            embeddings = Task { try await EmbeddingLoop.run(transcript: transcript, store: SearchModelSelfTest.store(), purpose: purpose, until: { stop.isSet }) }
            log("embedding loop started alongside the runs")
        }
        defer { stop.set() }
        if o.tasks.contains("minutes") { try await runMinutes(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("minutes-replay") { try await runMinutesReplay(o, write: write) }
        if o.tasks.contains("live-notes") { try await runLiveNotes(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("notepad") { try await runNotepad(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("ask-cross") { try await runAskCross(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("live-answer") { try await runAnswers(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("live-questions") { try await runLiveQuestions(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("brief") { try await BriefEvaluation.run(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("actions") { try await ActionsEvaluation.run(o, store: store, engine: engine, write: write) }
        if o.tasks.contains("links") { try await LinksEvaluation.run(o, store: store, engine: engine, write: write) }
        if let embeddings {
            stop.set()
            let report = try await embeddings.value
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(report).write(to: o.out.appendingPathComponent("embeddings.json"))
            log("embedding loop: \(report.windows) windows in \(report.batches) batches, batch median \(String(format: "%.2f", report.batchMedianSeconds)) s, p90 \(String(format: "%.2f", report.batchP90Seconds)) s, max \(String(format: "%.2f", report.batchMaxSeconds)) s, \(report.errors) errors")
        }
    }

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    static func setFiles(_ o: Options) -> [URL] {
        let all = ((try? FileManager.default.contentsOfDirectory(at: o.sets, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return all.filter { (o.only == nil || $0.lastPathComponent.contains(o.only!))
            && (o.meetings == nil || o.meetings!.contains($0.deletingPathExtension().lastPathComponent)) }
    }

    /// Before the first run on a model server, what `server-check` checks: it answers, it lists the configured chat models, and it loads
    /// them with at least the configured context (a shorter one is only a warning: the server cuts the prompt, which the numbers show).
    static func checkServer(_ server: EvaluationModel?, log: @Sendable (String) -> Void) async throws {
        guard let server = server?.server else { throw MinutesEvaluation.Failure.serverUnavailable("no --server configuration") }
        let listed = try await server.client.allModels(purpose: .connectionTest)
        let wanted = [server.config.fastModel, server.config.deepModel].filter { !$0.isEmpty }
        let missing = wanted.filter { !listed.contains($0) }
        guard missing.isEmpty else { throw MinutesEvaluation.Failure.serverUnavailable("not listed by the server: \(missing.joined(separator: ", "))") }
        if let inspected = try? await server.client.inspect() {
            for short in inspected.models(wanted, loadedWithLessThan: server.config.contextTokens) {
                log("warning: \(short.id) is loaded with a context of \(short.context) tokens, less than contextTokens (\(server.config.contextTokens))")
            }
        }
        log("model server: \(server.config.baseURL), main \(server.config.deepModel), fast \(server.config.fastModel)")
    }

    static func order(_ pair: Int, _ providers: [String]) -> [String] { pair % 2 == 0 ? providers : providers.reversed() }

    static func runMinutes(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        var files = setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        let minutesDir = o.out.appendingPathComponent("minutes")
        try FileManager.default.createDirectory(at: minutesDir, withIntermediateDirectories: true)
        var pair = 0
        for rep in 0..<o.repetitions {
            for file in files {
                guard let data = FileManager.default.contents(atPath: file.path),
                      let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { continue }
                let name = file.deletingPathExtension().lastPathComponent + (o.repetitions > 1 ? "#\(rep)" : "")
                let language = Locale(identifier: transcript.language == "es" || name.hasPrefix("es_") ? "es-ES" : "en-US")
                let (waited, _) = await waitForQuiet(o)
                let labels = o.minutesLabels
                let sequence = order(pair, labels)
                for label in sequence {
                    let (kind, choices) = o.minutesRun(label)
                    let m = model(kind, store: store, greedy: o.greedy, engine: engine, server: o.server)
                    var result: MinutesEvaluation.Result?
                    var failed: MinutesEvaluation.RunFailure?
                    let trace = await measure(task: "minutes", provider: label, item: name, pair: pair, order: sequence[0] == labels[0] ? "AB" : "BA",
                                              model: m, waited: waited, options: o) {
                        let r: MinutesEvaluation.Result
                        do {
                            r = try await MinutesEvaluation.run(transcript, language: language, model: m, arms: o.arms, warm: o.warm && kind == "integrated", renumberFinal: o.renumberFinal,
                                                            decidedFilter: o.decidedFilter, extraction: choices.extraction, summary: choices.summary, harness: choices.harness,
                                                            questions: choices.questions, outputLocale: o.outputLanguage.map { Locale(identifier: $0) })
                        } catch let failure as MinutesEvaluation.RunFailure { failed = failure; throw failure }
                        result = r
                        var detail = ["proposed": "\(r.proposed)", "kept": "\(r.items.count)", "dropped": "\(r.dropped)",
                                      "arms": o.arms.names(extraction: choices.extraction), "extraction": choices.extraction.names, "summary": choices.summary.names, "harness": choices.harness.names, "openQuestions": choices.questions.names, "release": "\(o.release)", "warm": "\(o.warm && kind == "integrated")",
                                      "warmSeconds": (r.warmSeconds ?? []).map { String(format: "%.2f", $0) }.joined(separator: ","),
                                      "unconfirmed": "\(r.items.filter(\.unconfirmed).count)", "contextTokens": "\(r.contextTokens)"]
                        if let d = r.diagnostics {
                            detail["checks"] = d.line
                            detail["dueGiven"] = "\(d.dueGiven)"
                            detail["dueUnreadable"] = "\(d.dueUnreadable)"
                            detail["dueRuleViolations"] = "\(d.dueRuleViolations)"
                            detail["junkTopics"] = "\(d.drops["topic.junk", default: 0])"
                            detail["junkOpenQuestions"] = "\(d.drops["open_question.junk", default: 0])"
                        }
                        return (r.calls, detail)
                    }
                    if let result {
                        let enc = JSONEncoder()
                        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try? enc.encode(result).write(to: minutesDir.appendingPathComponent("\(name).\(label).json"))
                        try? Self.writeMinutes(result, name: name, kind: label, to: minutesDir)
                    }
                    if let failed { try? Self.writeFailedRun(failed, name: name, kind: label, to: minutesDir) }
                    write(trace)
                }
                pair += 1
            }
        }
    }

    static func jsonString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [s], options: [])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
}

extension LLMEvaluation.Options {
    /// The minutes choices a provider runs: the ones given, or with `release` the ones the app ships for that backend (a model server
    /// keeps the minutes it had: the harness phase measured Apple's model and the integrated one only, `ChatProvider.releasedHarness`).
    func minutesChoices(provider: String) -> (extraction: MinutesExtraction, summary: MinutesSummary, harness: MinutesHarness, questions: MinutesQuestions) {
        guard release else { return (extraction, summary, harness, openQuestions) }
        if provider == "server" { return (.legacy, .legacy, .legacy, .legacy) }
        let integrated = provider == "integrated"
        return (MinutesRelease.extraction(integrated: integrated), MinutesSummaryRelease.summary(integrated: integrated),
                MinutesHarnessRelease.harness(integrated: integrated), MinutesQuestionsRelease.questions(integrated: integrated))
    }
}
