// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// `Vauta llm-selftest [--model] [--long] [--goldens <dir>]` (not listed in `--help`): the integrated language model's GPU kernels
/// and, with `--model`, its files, tokenizer, chat template and logits against the mlx-lm goldens, in the binary as shipped.
/// Exit codes: 0 pass, 1 fail, 2 unsupported, 3 model missing, 4 the 16 GB / GPU gate is not met, 5 the files verified but no
/// `--goldens` folder was given, so the parity checks against mlx-lm did not run (not a pass). The install folder comes from
/// `VAUTA_LLM_MODEL_DIR`. No meeting store, no network.
func llmSelfTest(_ invocation: CommandInvocation) async -> Int32 {
    let goldens = invocation.values["--goldens"].map { URL(fileURLWithPath: $0) }
    let result = await LanguageModelSelfTest.run(includeModel: invocation.has("--model"), long: invocation.has("--long"), goldens: goldens)
    result.lines.forEach { print($0) }
    return result.exitCode
}

/// `Vauta llm-install status|verify|adopt|download|import <files…>|delete` (hidden, for testing and release checks). The folder is
/// `VAUTA_LLM_MODEL_DIR`; `download` and `import` refuse to write to the app's own store unless that variable is set.
func llmInstall(_ invocation: CommandInvocation) async -> Int32 {
    let store = LanguageModelSelfTest.store()
    let env = ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] ?? ""
    guard let action = invocation.positional.first else { throw_usage(); return 1 }
    switch action {
    case "status":
        LanguageModelInstaller.status(store: store).forEach { print($0) }
        return 0
    case "verify":
        let v = LanguageModelInstaller.verify(store: store)
        print(v.line)
        return v.ok ? 0 : 1
    case "adopt":
        guard !env.isEmpty else { printError("adopt needs VAUTA_LLM_MODEL_DIR."); return 1 }
        do { try LanguageModelInstaller.adopt(store: store); print("installed.json written"); return 0 } catch { printError("adopt failed: \(error)"); return 1 }
    case "download", "import":
        guard !env.isEmpty else { printError("\(action) needs VAUTA_LLM_MODEL_DIR (it never writes to the app's own store from here)."); return 1 }
        if let refusal = LanguageModelGate.refusal(gpuSupported: true) { printError("gate not met: \(refusal)"); return 4 }
        do {
            let t0 = Date()
            if action == "download" {
                try await LanguageModelInstaller.download(store: store) { print($0) }
            } else {
                let outcome = try await LanguageModelInstaller.importFiles(invocation.positional.dropFirst().map { URL(fileURLWithPath: $0) }, store: store) { print($0) }
                print("import: \(outcome)")
            }
            print(String(format: "done in %.0f s", Date().timeIntervalSince(t0)))
            return 0
        } catch { printError("\(action) failed: \(error)"); return 1 }
    case "delete":
        guard !env.isEmpty else { printError("delete needs VAUTA_LLM_MODEL_DIR."); return 1 }
        print("freed \(store.delete() >> 20) MiB")
        return 0
    default:
        throw_usage()
        return 1
    }
}

private func throw_usage() { printError("usage: llm-install status|verify|adopt|download|import <files…>|delete (folder from VAUTA_LLM_MODEL_DIR)") }

/// `llm-eval --tasks retrieval|retrieval-controls --sets <data dir> --out <dir> [--search-model <install dir>] [--retrieval-arms K,S,S3,T,Tref,S3T,S3Tref,S3MMR,S3leak,S3od]
/// [--retrieval-sets w11,w11-stress,w10,cross] [--split dev|test] [--max-queries n] [--sweep 0.45,0.5,…] [--live-tau 0.70] [--no-embedding-cache] [--cold-model] [--controls miracl_es,mlqa_es_to_en,…]` (hidden, EVALUATION ONLY, no language
/// model): runs the app's own retrieval over public evaluation sets (`--sets` is the data folder with `meetings/` and the question files) and writes where the gold segments are
/// within Apple's Ask budget and by rank, and what the evidence gate saw. `--search-model` names the folder of an EmbeddingGemma 2 install (verified against the app's pins, loaded in
/// this process); without it only the keyword arms (K, T, Tref) run. With `--search-model`, the live-questions and live-answer tasks embed the earlier meetings of a series too.
/// `llm-eval --tasks live-questions` replays the final lines of public transcripts through the live-answer pipeline on a simulated clock
/// (`--sets <dir>`, the earlier meetings of a series become past meetings): `[--sensitivity low|standard|high] [--no-check] [--keep-answered-aloud]
/// [--sources this,past,docs] [--detect-only] [--no-detection] [--closing-probe] [--sentences <file>]`. `--detect-only` runs the cues and the evidence gate without a model;
/// `--no-detection` stores and reads the lines but detects nothing, `--closing-probe` times the first token of one question after the last line (run it with and without `--no-detection`);
/// `--sentences` writes every scored sentence (the pool the labelling draws from) and stops.
/// `llm-eval --tasks brief --sets <transcripts> --brief-fixtures <folder of *.brief.json> --out <dir> [--brief-arms K0,S0,KA,SA,KG,SG,BL] [--brief-split dev|test]
/// [--brief-minutes-apple <minutes_apple.jsonl>] [--brief-minutes-integrated <minutes_integrated.jsonl>] [--search-model <install dir>]` (hidden, EVALUATION ONLY): builds the
/// pre-meeting brief of the meeting after the `earlier` ones of each fixture with the app's own brief code, in a throwaway store. The arms are keyword (K) or search model (S)
/// ranking, without an agenda (K0, S0), with Apple's agenda (KA, SA) or the integrated model's (KG, SG), and BL, the same model's recap of the last minutes alone. It writes
/// `briefs/briefs.jsonl` and one text file per series and arm (the rendered brief, nothing that names the arm), `fixtures.sha256` and the traces. Synthetic fixtures and public
/// transcripts only; no EventKit, no model server.
/// `llm-eval --tasks actions --sets <transcripts> --out <dir> [--actions-arms ET1,ETO,EBL,FD,FDX,FBL,RP] [--actions-fixtures <folder of *.actions.json>]
/// [--actions-minutes-apple <minutes_apple.jsonl>] [--actions-minutes-integrated <minutes_integrated.jsonl>] [--actions-name-speakers]` (hidden, EVALUATION ONLY): the post-meeting actions of Part A over public
/// transcripts and the stored minutes of the minutes runs, in a throwaway store. ET1 and ETO are the follow-up email (one, or one per owner) filled from the stored minutes, EBL the same
/// backend writing it with no template; FD is the follow-up meeting detector, FDX the detector reading every segment, FBL the backend extracting the next meeting; RP replays the
/// duplicate, due-day, crash and undo scenarios against a fake writer. EventKit is never touched. Outputs carry blind labels (`emails/`, `followups/`, `sealed/key.json` and its hash),
/// `replay.jsonl` and the traces.
/// `llm-eval --tasks links --sets <transcripts> --links-series <series.json> --out <dir> [--links-arms LK0,LS0,LKA,LSA,LKG,LSG,LBL,LS0R,POOL,RP] [--links-minutes-apple <minutes_apple.jsonl>]
/// [--links-minutes-integrated <minutes_integrated.jsonl>] [--links-fixtures <folder of *.links.json>] [--links-split dev|test] [--search-model <install dir>]` (hidden, EVALUATION ONLY): the links
/// to earlier meetings of Part B over the meetings of public series and the stored minutes of the minutes runs, in a throwaway store, through the real job queue. LK0 and LS0 link by keywords or
/// by the search model's vectors with the deterministic difference rules; LKA, LSA, LKG and LSG add the check of Apple's model or the integrated one; LBL is the backend listing the links
/// itself; LS0R (development only) includes the items the ranking left out; POOL writes every same-series pair with its cosine and keyword bands for the gold sample; RP replays the dismissal,
/// confirmation and rewrite scenarios. Outputs carry blind labels (`links/`, `pool/`, `sealed/key.json` and its hash), `replay.jsonl` and the traces. No model server, no EventKit.
/// `llm-eval --tasks minutes --extraction old|new [--meetings a,b,c] [--arms …]` regenerates the minutes of the named meetings with the extraction of decisions, tasks and owners
/// before this phase (`old`) or the app's (`new`, the default: the new extraction with the ranking of Apple's list and the lean block shape; `integrated`: the same without them, as the integrated model runs it; or a list of prompts, evidence, owners, closing, due, drop, rank, shape, procedure to switch one part). `--tasks minutes-replay --replay-from <folder of
/// <meeting>.<provider>.json> --extraction old|new` plays the stored replies of an earlier run through the app's validation, item filter and owner rules with no model (the prompts and the
/// closing request are not replayed).
/// `--notes old|new` (notepad) expands the user's shorthand notes on the small window as they shipped (`old`) or with the harness of this phase (`new`, the default: a quote of 4 to 15 words with empty shapes, 700 tokens of output, the finished sentences of a cut reply, segment tags repaired, sentences about something said over 75 s before the note dropped); a list of prompt, budget, salvage, repair, relevance switches one part. The raw replies go to `notepad/replies.<provider>.jsonl`.
/// `--live old|new` (live-notes) takes the live notes as they shipped (`old`) or with the harness of this phase (`new`, the default: Apple gets empty shapes in the instruction and the checks, the integrated model the checks only; Swift drops a note that copies its cited line or repeats an earlier one, "Me" is an owner only on the user's own line, and a reply that is not JSON is repaired in Swift); a list of shape, copies, repeats, owners, repair switches one part.
/// `--open-questions old|new` (minutes) writes the open questions as they shipped (`old`) or with the checks of this phase (`new`, the default: Swift drops a transcript line copied as it is, a text of under 4 words or with no question form, a restated topic, a point a decision settles and repeats; Apple's digest shows the open questions the blocks wrote as objects in its Open lines (`lines`); the cap of 3 and the digest rule stay out and can be named, as can `short`); a list of checks, form, copy, topic, settled, repeats, generic, cap, digest, lines, short switches one part.
/// `--ask old|new` (live-answer, ask-cross, ask-retrieval) asks with Ask as it shipped (`old`) or with the harness of this phase (`new`, the default: the proposal rule only for questions about a decision, short keyword windows with spelled numbers and a rerank on the small window, passages oldest first with the place of their meeting, and the keyword query translated as the app does it); a list of rule, windows, order, translate switches one part. `--tasks ask-retrieval` runs Ask's retrieval alone (no model) and writes the passages sent per question.
/// `--harness old|new` (minutes, integrated model) regenerates the minutes with the request as it shipped (`old`) or with the items before the summary, the outcome rule for the summary, the recall wording, the expected counts and greedy decoding (`new`, the default); a list of items, rule, recall, count, greedy, t03 switches one part (greedy and t03 set the temperature of the minutes request).
/// `Vauta llm-eval --tasks minutes,live-answer --providers apple,integrated --sets <dir> [--questions <file.jsonl>] --out <dir>
/// [--seed 7] [--sampler card|greedy] [--only <text>] [--max-items n] [--quiet-wait seconds] [--repeat n]
/// [--arms a0|a1|a2|a3|streaming,recall,items] [--decided on] [--guard none|g1|g2|g1+g2] [--warm|--replay-realtime] [--renumber-final] [--after-meeting]`: EVALUATION ONLY (hidden). `--warm` replays each meeting as a
/// recording, with the integrated model reading it as the segments arrive; `--renumber-final` makes the final speaker labelling
/// number the voices the other way round than the live one; `--after-meeting` (with `--warm`, live-answer) asks the questions
/// about the finished meeting, whose whole transcript was read while it recorded.
/// Runs the app's minutes code and Ask with both providers interleaved item by item (ABAB) on PUBLIC transcripts, in a throwaway
/// store; never the user's store. See docs/LANGUAGE_MODEL.md. The integrated model comes from `VAUTA_LLM_MODEL_DIR`.
/// `--providers server --server <config.json> [--ask-key]` (minutes only) adds a model server, from the same file as `server-check`: its
/// requests go through the app's client, address rules and Network Activity purposes, and the key, if any, is typed without echo.
/// Without `server` in `--providers` no model server is contacted.
func llmEval(_ invocation: CommandInvocation) async -> Int32 {
    if invocation.has("--print-context") { print(await LLMEvaluation.contextLine()); return 0 }
    guard let sets = invocation.values["--sets"], let out = invocation.values["--out"] else { printError("usage: llm-eval --sets <dir> --out <dir> [--tasks minutes,live-answer] [--providers apple,integrated] [--questions <file>]"); return 1 }
    var options = LLMEvaluation.Options(sets: URL(fileURLWithPath: sets), out: URL(fileURLWithPath: out))
    if let t = invocation.values["--tasks"] { options.tasks = Set(t.split(separator: ",").map(String.init)) }
    if let p = invocation.values["--providers"] { options.providers = p.split(separator: ",").map(String.init) }
    options.questions = invocation.values["--questions"].map { URL(fileURLWithPath: $0) }
    options.seed = invocation.values["--seed"].flatMap { UInt64($0) } ?? 7
    options.greedy = invocation.values["--sampler"] == "greedy"
    options.only = invocation.values["--only"]
    options.maxItems = invocation.values["--max-items"].flatMap { Int($0) }
    options.quietWait = invocation.values["--quiet-wait"].flatMap { Double($0) } ?? 0
    options.repetitions = invocation.values["--repeat"].flatMap { Int($0) } ?? 1
    options.embeddingTranscript = invocation.values["--with-embeddings"].map { URL(fileURLWithPath: $0) }
    options.embeddingPurpose = invocation.values["--embedding-purpose"] == "query" ? .query : .document
    if let arms = invocation.values["--arms"] {
        guard let parsed = MinutesArms.parse(arms) else { printError("--arms: a0, a1, a2, a3, or a list of streaming, recall, items"); return 1 }
        options.arms = parsed
    }
    if let guards = invocation.values["--guard"] {
        guard let parsed = AnswerGuards.parse(guards) else { printError("--guard: none, g1, g2, g1+g2"); return 1 }
        options.guards = parsed
    }
    options.brief.fixtures = invocation.values["--brief-fixtures"].map { URL(fileURLWithPath: $0) }
    options.brief.split = invocation.values["--brief-split"]
    if let apple = invocation.values["--brief-minutes-apple"] { options.brief.minutes["apple"] = URL(fileURLWithPath: apple) }
    if let integrated = invocation.values["--brief-minutes-integrated"] { options.brief.minutes["integrated"] = URL(fileURLWithPath: integrated) }
    if let list = invocation.values["--brief-arms"] {
        guard let arms = BriefEvaluation.Arm.named(list.split(separator: ",").map(String.init)) else { printError("--brief-arms: K0, S0, KA, SA, KG, SG, BL, BLG"); return 1 }
        options.brief.arms = arms
    }
    if options.tasks.contains("brief"), options.brief.fixtures == nil { printError("brief needs --brief-fixtures <folder>"); return 1 }
    options.actions.fixtures = invocation.values["--actions-fixtures"].map { URL(fileURLWithPath: $0) }
    options.actions.nameSpeakers = invocation.has("--actions-name-speakers")
    if let apple = invocation.values["--actions-minutes-apple"] { options.actions.minutes["apple"] = URL(fileURLWithPath: apple) }
    if let integrated = invocation.values["--actions-minutes-integrated"] { options.actions.minutes["integrated"] = URL(fileURLWithPath: integrated) }
    if let list = invocation.values["--actions-arms"] {
        guard let kinds = ActionsEvaluation.Options.kinds(named: list.split(separator: ",").map(String.init)) else { printError("--actions-arms: ET1, ETO, EBL, FD, FDX, FBL, RP"); return 1 }
        options.actions.kinds = kinds
    }
    options.links.series = invocation.values["--links-series"].map { URL(fileURLWithPath: $0) }
    options.links.fixtures = invocation.values["--links-fixtures"].map { URL(fileURLWithPath: $0) }
    options.links.split = invocation.values["--links-split"]
    if let apple = invocation.values["--links-minutes-apple"] { options.links.minutes["apple"] = URL(fileURLWithPath: apple) }
    if let integrated = invocation.values["--links-minutes-integrated"] { options.links.minutes["integrated"] = URL(fileURLWithPath: integrated) }
    if let list = invocation.values["--links-arms"] {
        guard let arms = LinksEvaluation.Options.arms(named: list.split(separator: ",").map(String.init)) else { printError("--links-arms: LK0, LS0, LKA, LSA, LKG, LSG, LBL, LS0R, POOL, RP"); return 1 }
        options.links.arms = arms
    }
    if options.tasks.contains("links"), options.links.series == nil { printError("links needs --links-series <series.json>"); return 1 }
    options.warm = invocation.has("--warm") || invocation.has("--replay-realtime")
    options.renumberFinal = invocation.has("--renumber-final")
    options.afterMeeting = invocation.has("--after-meeting")
    options.decidedFilter = invocation.values["--decided"] == "on"
    options.outputLanguage = invocation.values["--output-language"]
    options.notepad = invocation.values["--notepad"].map { URL(fileURLWithPath: $0) }
    options.crossQuestions = invocation.values["--cross-questions"].map { URL(fileURLWithPath: $0) }
    // `release` on any of the four minutes choices: every backend runs what the app ships for it.
    for flag in ["--extraction", "--summary", "--harness", "--open-questions"] where invocation.values[flag]?.lowercased() == "release" { options.release = true }
    if let summary = invocation.values["--summary"], summary.lowercased() != "release" {
        guard let parsed = MinutesSummary.parse(summary) else { printError("--summary: old, new, release, or a list of outcomes, wording, checks"); return 1 }
        options.summary = parsed
    }
    if let harness = invocation.values["--harness"], harness.lowercased() != "release" {
        guard let parsed = MinutesHarness.parse(harness) else { printError("--harness: old, new, release, or a list of items, rule, recall, count, greedy, t03"); return 1 }
        options.harness = parsed
    }
    if let questions = invocation.values["--open-questions"], questions.lowercased() != "release" {
        guard let parsed = MinutesQuestions.parse(questions) else { printError("--open-questions: old, new, release, or a list of form, copy, topic, settled, repeats, generic, cap, digest, lines, short"); return 1 }
        options.openQuestions = parsed
    }
    if let ask = invocation.values["--ask"] {
        guard let parsed = AskHarness.parse(ask) else { printError("--ask: old, new, or a list of rule, windows, order, translate"); return 1 }
        options.ask = parsed
    }
    if let notes = invocation.values["--notes"] {
        guard let parsed = NoteHarness.parse(notes) else { printError("--notes: old, new, or a list of prompt, budget, salvage, repair, relevance"); return 1 }
        options.notes = parsed
    }
    if let live = invocation.values["--live"] {
        guard let parsed = LiveHarness.parse(live) else { printError("--live: old, new, checks, or a list of shape, copies, repeats, owners, repair"); return 1 }
        options.live = ["new", "shipped", "all"].contains(live.lowercased()) ? nil : parsed
    }
    if let windows = invocation.values["--ask-windows"] {
        guard let parsed = AskWindows.parse(windows) else { printError("--ask-windows: before, after, chars, count, coverage, candidates as name=number"); return 1 }
        options.askWindows = parsed
    }
    if let extraction = invocation.values["--extraction"], extraction.lowercased() != "release" {
        guard let parsed = MinutesExtraction.parse(extraction) else { printError("--extraction: old, new, integrated, release, or a list of prompts, evidence, owners, closing, due, drop, rank, shape, procedure"); return 1 }
        options.extraction = parsed
        // The integrated closing request needs the extraction's closing step and the arm: an explicit `--arms` list must not turn it off silently.
        if parsed.contains(.closing) { options.arms.insert(.closingPass) }
    }
    options.meetings = invocation.values["--meetings"].map { Set($0.split(separator: ",").map(String.init)) }
    options.replayLive = invocation.has("--replay-live")
    options.replayFrom = invocation.values["--replay-from"].map { URL(fileURLWithPath: $0) }
    // The search model (EvaluationSearchModel) and the retrieval tasks.
    options.searchModelDirectory = invocation.values["--search-model"].map { URL(fileURLWithPath: $0) }
    if let list = invocation.values["--retrieval-arms"] { options.retrieval.arms = list.split(separator: ",").map(String.init) }
    if let list = invocation.values["--retrieval-sets"] { options.retrieval.sets = list.split(separator: ",").map(String.init) }
    if let list = invocation.values["--controls"] { options.retrieval.controls = list.split(separator: ",").map(String.init) }
    if let list = invocation.values["--sweep"] { options.retrieval.sweep = list.split(separator: ",").compactMap { Double($0) } }
    if let tau = invocation.values["--live-tau"] {
        guard let value = Double(tau), value > 0, value <= 1 else { printError("--live-tau: a cosine in (0, 1]"); return 1 }
        options.retrieval.liveThresholds = .all(value)
    }
    options.retrieval.coldModel = invocation.has("--cold-model")
    options.retrieval.embeddingCache = !invocation.has("--no-embedding-cache") && !options.retrieval.coldModel
    options.retrieval.split = invocation.values["--split"]
    options.retrieval.maxQueries = invocation.values["--max-queries"].flatMap { Int($0) }
    if options.tasks.contains(where: { $0.hasPrefix("retrieval") }) {
        let known = Set(["K", "S", "S3", "T", "Tref", "S3T", "S3Tref", "S3MMR", "S3leak", "S3od"])
        guard Set(options.retrieval.arms).isSubset(of: known) else { printError("--retrieval-arms: \(known.sorted().joined(separator: ", "))"); return 1 }
        guard Set(options.retrieval.sets).isSubset(of: ["w11", "w11-stress", "w10", "cross"]) else { printError("--retrieval-sets: w11, w11-stress, w10, cross"); return 1 }
        if options.tasks.contains("retrieval-controls"), options.searchModelDirectory == nil { printError("retrieval-controls needs --search-model <dir>"); return 1 }
    }
    // live-questions: the variants under evaluation.
    if let level = invocation.values["--sensitivity"] {
        guard let parsed = QuestionSensitivity(rawValue: level) else { printError("--sensitivity: low, standard, high"); return 1 }
        options.questionSensitivity = parsed
    }
    options.questionSkipCheck = invocation.has("--no-check")
    options.questionKeepAnsweredAloud = invocation.has("--keep-answered-aloud")
    options.questionDetectOnly = invocation.has("--detect-only")
    options.questionNoDetection = invocation.has("--no-detection")
    options.questionClosingProbe = invocation.has("--closing-probe")
    options.questionRealtime = invocation.has("--realtime")
    options.questionDocuments = invocation.values["--documents"].map { URL(fileURLWithPath: $0) }
    options.questionSentences = invocation.values["--sentences"].map { URL(fileURLWithPath: $0) }
    if let list = invocation.values["--sources"] {
        var sources: LiveAnswerSources = []
        for word in list.split(separator: ",") {
            switch word {
            case "this": sources.insert(.thisMeeting)
            case "past": sources.insert(.pastMeetings)
            case "docs": sources.insert(.documents)
            default: printError("--sources: this, past, docs"); return 1
            }
        }
        options.questionSources = sources
    }
    guard Set(options.providers).isSubset(of: ["apple", "integrated", "server"]) else { printError("providers: apple, integrated, server"); return 1 }
    if options.providers.contains("server") {
        // The same file as `server-check` and Settings › Models › Paste Configuration; the key is typed without echo, never an argument.
        guard let path = invocation.values["--server"] else { printError("--providers server needs --server <config.json> (and --ask-key if the server needs a key)"); return 1 }
        guard options.tasks == ["minutes"] else { printError("--providers server runs the minutes task only (--tasks minutes)"); return 1 }
        do {
            let config = try JSONDecoder().decode(LLMServerConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            _ = try config.validated(embeddingsOnServer: false)
            let key = invocation.has("--ask-key") ? readSecret("Server key (not shown): ") : nil
            options.server = .server(config, bearer: { key })
        } catch { printError("--server: \(error)"); return 1 }
    }
    do {
        try await LLMEvaluation.run(options, store: LanguageModelSelfTest.store()) { print($0) }
        return 0
    } catch { printError("llm-eval failed: \(error)"); return 1 }
}

/// `Vauta embed-loop --transcript <set.json> [--seconds n] [--passes n] [--batch n] [--purpose document|query] [--out report.json]` (hidden, EVALUATION ONLY): the
/// search model embeds the windows of a PUBLIC transcript in a loop, for `--seconds` (default 60) or `--passes` passes. The model comes
/// from `VAUTA_SEARCH_MODEL_DIR`. It prints counts and timings, never text.
func embedLoop(_ invocation: CommandInvocation) async -> Int32 {
    guard let path = invocation.values["--transcript"], let data = FileManager.default.contents(atPath: path),
          let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else {
        printError("usage: embed-loop --transcript <set.json> [--seconds n] [--passes n] [--batch n] [--out report.json] (model from VAUTA_SEARCH_MODEL_DIR)")
        return 1
    }
    let passes = invocation.values["--passes"].flatMap { Int($0) } ?? 0
    let seconds = invocation.values["--seconds"].flatMap { Double($0) } ?? (passes > 0 ? .infinity : 60)
    let deadline = Date().addingTimeInterval(seconds)
    do {
        let report = try await EmbeddingLoop.run(transcript: transcript, store: SearchModelSelfTest.store(), batch: invocation.values["--batch"].flatMap { Int($0) } ?? 8,
                                                 passes: passes,
                                                 purpose: invocation.values["--purpose"] == "query" ? .query : .document, until: { Date() >= deadline })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try encoder.encode(report)
        if let out = invocation.values["--out"] { try json.write(to: URL(fileURLWithPath: out)) }
        print(String(decoding: json, as: UTF8.self))
        return report.errors == 0 ? 0 : 1
    } catch { printError("embed-loop failed: \(error)"); return 1 }
}
