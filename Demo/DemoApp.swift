import AssistantModes
import AssistantModesUI
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The demo app owns the configuration the library takes as parameters: the mode graph, the
/// platform profile and the two model backends. Launch arguments pick a scripted scenario so the
/// same build shows each behaviour: `-scenario iphone | appletv | stale | eval`, plus `-systemModel`
/// to use Apple's on-device model instead of the scripted one.
@main
struct DemoApp: App {
    @State private var console: AssistantConsoleModel?
    @State private var evalReport: EvalReport?
    @State private var setupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let console {
                    AssistantConsoleView(model: console)
                } else if let evalReport {
                    EvalReportView(report: evalReport)
                } else if let setupError {
                    Text(setupError).padding()
                } else {
                    ProgressView("Running…")
                }
            }
            .task { await start() }
        }
    }

    @MainActor
    private func start() async {
        guard console == nil, evalReport == nil, setupError == nil else { return }
        let scenario = Scenario(arguments: ProcessInfo.processInfo.arguments)
        let backend = DemoConfig.onDeviceModel(useSystemModel: scenario.useSystemModel, slowCapture: scenario.kind == .stale)
        do {
            if scenario.kind == .eval {
                evalReport = try await EvalReport.run(backend: backend)
                return
            }
            let engine = try AssistantEngine(
                graph: DemoConfig.graph(),
                profile: scenario.profile(contextTokens: backend.contextTokens),
                onDevice: backend.model,
                escalation: DemoConfig.simulatedClaude,
                cloudConsent: false // consent is granted explicitly; the scripts do it on screen
            )
            let model = AssistantConsoleModel(engine: engine, backendLabel: backend.label)
            console = model
            await model.refresh()
            await scenario.play(on: model)
        } catch {
            setupError = "Configuration rejected: \(error)"
        }
    }
}

struct OnDeviceBackend {
    let model: any OnDeviceModel
    let label: String
    /// The on-device context window to plan against: Apple's reported `contextSize` when the real
    /// model is in use, otherwise the documented 4,096.
    var contextTokens: Int = DemoConfig.contextTokens
}

/// Thrown by the stand-in used when `-systemModel` can't be honoured, so nothing (not even the
/// stability probe, which calls the model directly) can mistake it for a working model.
struct SystemModelUnavailable: Error, CustomStringConvertible {
    var description: String { "Foundation Models is not available in this build or OS" }
}

enum DemoConfig {
    static let topic: StateKey = "topic"
    static let notes: StateKey = "notes"
    static let steps: StateKey = "steps"

    /// 4,096 tokens: the fallback window for the scripted scenarios and for SDKs that can't report
    /// `contextSize` (the real model on iOS 27.2 reported 8,192). The window is shared by input and
    /// output, so every mode budget plus the engine's response reserve (1,024 by default) must fit
    /// inside it, or `AssistantEngine` refuses the configuration at launch.
    static let contextTokens = 4096

    static func graph() throws -> ModeGraph {
        try ModeGraph(initialMode: "capture", modes: [
            ModeDefinition(
                id: "capture", title: "Capture",
                instructions: "You are in capture mode. Turn what the user says into short, factual notes. Do not plan.",
                contextBudget: 1200, writableKeys: [topic, notes],
                transitions: ["plan": [topic, notes]]
            ),
            ModeDefinition(
                id: "plan", title: "Plan",
                instructions: "You are in plan mode. Turn the notes in session state into ordered, concrete steps.",
                requirements: [.onDeviceText, .guidedGeneration],
                contextBudget: 2000, writableKeys: [steps],
                transitions: ["review": [topic, steps], "capture": [topic]]
            ),
            ModeDefinition(
                id: "review", title: "Review",
                instructions: "You are in review mode. Critique the plan honestly. This content is private.",
                contextBudget: 1500,
                escalation: .forbidden,
                // Private mode: the graph refuses to carry any state out of it into an escalating mode.
                transitions: ["capture": []]
            ),
        ])
    }

    /// Scripted on-device answers by default, so screenshots are deterministic. With `-systemModel`,
    /// Apple's Foundation Models backend is used. If this build or OS can't provide it, the backend
    /// reports itself unavailable, so the router escalates or refuses and the log says why; it never
    /// silently falls back to the scripted model.
    static func onDeviceModel(useSystemModel: Bool, slowCapture: Bool) -> OnDeviceBackend {
        if useSystemModel {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return OnDeviceBackend(model: SystemModelBackend(), label: "Foundation Models (SystemLanguageModel)",
                                       contextTokens: systemContextTokens())
            }
            #endif
            let missing = ClosureModel(availability: .unavailable(.other("needs iOS 26+ and an Xcode 26+ SDK"))) { _ in
                throw SystemModelUnavailable()
            }
            return OnDeviceBackend(model: missing, label: "Foundation Models (not available in this build)")
        }
        let scripted = ClosureModel { request in
            // The stale scenario slows capture answers so a mode switch can land mid-generation.
            if slowCapture, request.mode == "capture" { try await Task.sleep(nanoseconds: 1_500_000_000) }
            switch request.mode {
            case "capture": return "Noted: \(request.prompt)"
            case "plan": return "1. Renew passport  2. Book flights  3. Pack carry-on"
            default: return "Step 2 depends on step 1; book flights only after the passport arrives."
            }
        }
        return OnDeviceBackend(model: scripted, label: "scripted (deterministic demo answers)")
    }

    #if canImport(FoundationModels)
    /// Apple's reported context window. `contextSize` is in the iOS 26.4 SDK (back-deployed to 26.0);
    /// with an older SDK (Swift < 6.3, i.e. before Xcode 26.4), or while the model reports 0 (iOS 27,
    /// model still downloading), the documented 4,096 is used.
    @available(iOS 26.0, *)
    static func systemContextTokens() -> Int {
        #if compiler(>=6.3)
        // A model that is still downloading reports 0 (seen on a freshly created Simulator). Fall
        // back rather than reject every mode; the router then reports the model as not ready.
        let reported = SystemLanguageModel.default.contextSize
        return reported > 0 ? reported : contextTokens
        #else
        return contextTokens
        #endif
    }
    #endif

    /// Stands in for Claude behind your server. No network call is made in this demo.
    static let simulatedClaude = ClosureModel { request in
        "(simulated Claude) Handled in \(request.mode) with \(request.history.count) earlier turn(s) of context."
    }
}

struct Scenario {
    enum Kind: Equatable {
        case iphone
        case appletv
        case stale
        case eval
    }

    let kind: Kind
    /// `-systemModel`: use Apple's on-device model instead of the scripted one.
    let useSystemModel: Bool

    init(arguments: [String]) {
        let value = arguments.firstIndex(of: "-scenario").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        switch value {
        case "appletv": kind = .appletv
        case "stale": kind = .stale
        case "eval": kind = .eval
        default: kind = .iphone
        }
        useSystemModel = arguments.contains("-systemModel")
    }

    func profile(contextTokens: Int) -> PlatformProfile {
        kind == .appletv ? .appleTV(contextTokens: contextTokens) : .iPhone(contextTokens: contextTokens)
    }

    @MainActor
    func play(on console: AssistantConsoleModel) async {
        switch kind {
        case .iphone:
            await console.write(.text("Lisbon trip"), for: DemoConfig.topic)
            await console.write(.list(["passport expires in March", "flights cheaper on Tuesdays"]), for: DemoConfig.notes)
            await say("passport expires in March", on: console)
            // A pasted itinerary larger than capture's 1,200-token budget. Consent is off, so it is
            // refused; the user grants consent and resends, and it escalates.
            let itinerary = "Itinerary: " + String(repeating: "day trip to Sintra, ", count: 200)
            await say(itinerary, on: console)
            await console.setCloudConsent(true)
            await say(itinerary, on: console)
            await console.transition(to: "plan")
            await say("make me a plan", on: console)
        case .appletv:
            await console.setCloudConsent(true)
            await say("read the receipt I'm pointing the camera at", needsImage: true, on: console)
            await console.transition(to: "plan")
            await console.write(.list(["book flights"]), for: DemoConfig.steps)
            await console.transition(to: "review")
            await say("check the screenshot of my plan", needsImage: true, on: console)
            await say("is the order of steps sensible?", on: console)
        case .stale:
            await console.write(.text("Lisbon trip"), for: DemoConfig.topic)
            await console.write(.list(["passport expires in March"]), for: DemoConfig.notes)
            console.draft = "summarise my notes"
            async let pending: Void = console.send()
            // Timing-dependent on purpose: the switch lands 0.3 s into a 1.5 s capture answer.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await console.transition(to: "plan")
            await pending
            await say("make me a plan", on: console)
        case .eval:
            break // handled by EvalReport
        }
    }

    @MainActor
    private func say(_ text: String, needsImage: Bool = false, on console: AssistantConsoleModel) async {
        console.draft = text
        console.needsImageInput = needsImage
        await console.send()
    }
}

/// `-scenario eval`: the house eval on both platform profiles and a stability probe, run against
/// whichever on-device backend is active (pass `-systemModel` for Apple's model).
struct EvalReport {
    struct CaseRow: Identifiable {
        let id = UUID()
        let profile: String
        let result: EvalResult
    }

    let backend: String
    let cases: [CaseRow]
    let stability: StabilityReport

    /// Routing and state rules every graph change and model swap must keep. The expectations differ
    /// by platform only where the capability matrix differs (image input).
    static func houseEval(imageRunsOnDevice: Bool) -> EvalCase {
        let image: RouteExpectation = imageRunsOnDevice ? .onDevice : .escalated
        let privateImage: RouteExpectation = imageRunsOnDevice ? .onDevice : .refused(.modeForbidsEscalation)
        let noConsentImage: RouteExpectation = imageRunsOnDevice ? .onDevice : .refused(.noCloudConsent)
        return EvalCase(name: "privacy + carry-over", steps: [
            .write(DemoConfig.topic, .text("Lisbon trip"), expect: .succeeds),
            .write(DemoConfig.steps, .list(["x"]), expect: .fails),
            .send("note: passport expires in March", expect: .onDevice),
            .transition(to: "review", expect: .fails),
            .transition(to: "plan", expect: .succeeds),
            .expectState(DemoConfig.topic, .text("Lisbon trip")),
            .write(DemoConfig.steps, .list(["book flights"]), expect: .succeeds),
            .transition(to: "review", expect: .succeeds),
            .send("check the screenshot of my plan", needs: [.imageInput], expect: privateImage),
            .transition(to: "capture", expect: .succeeds),
            .expectState(DemoConfig.topic, nil),
            .send("read this receipt", needs: [.imageInput], expect: noConsentImage),
            .setCloudConsent(true),
            .send("read this receipt", needs: [.imageInput], expect: image),
            .send("   ", expect: .rejected),
        ])
    }

    static func run(backend: OnDeviceBackend) async throws -> EvalReport {
        var rows: [CaseRow] = []
        let profiles = [
            (PlatformProfile.iPhone(contextTokens: backend.contextTokens), true),
            (PlatformProfile.appleTV(contextTokens: backend.contextTokens), false),
        ]
        for (profile, imageOnDevice) in profiles {
            let engine = try AssistantEngine(graph: DemoConfig.graph(), profile: profile, onDevice: backend.model,
                                             escalation: DemoConfig.simulatedClaude, cloudConsent: false)
            let result = await EvalRunner.run(houseEval(imageRunsOnDevice: imageOnDevice), on: engine)
            rows.append(CaseRow(profile: profile.name, result: result))
        }
        let request = ModelRequest(
            mode: "plan",
            instructions: "You are in plan mode. Reply with exactly one word: the verb of the first step.",
            stateBlock: "[notes]\n  - passport expires in March\n  - flights cheaper on Tuesdays",
            history: [],
            prompt: "What is the first step?"
        )
        let model = backend.model
        let stability = await StabilityProbe.measure(runs: 10, request: request) { try await model.respond(to: $0) }
        return EvalReport(backend: backend.label, cases: rows, stability: stability)
    }
}

struct EvalReportView: View {
    let report: EvalReport

    /// `agreement` is always in 0...1 (StabilityReport guards runs > 0), so the conversion can't trap.
    private var agreementPercent: Int { Int((report.stability.agreement * 100).rounded()) }

    var body: some View {
        NavigationStack {
            List {
                Section("On-device backend") { Text(report.backend) }
                Section("House eval (routing + state rules)") {
                    ForEach(report.cases) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(row.profile): \(row.result.passed ? "PASS" : "FAIL") · \(row.result.stepsRun) steps",
                                  systemImage: row.result.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(row.result.passed ? .green : .red)
                            ForEach(row.result.failures, id: \.stepIndex) { failure in
                                Text("step \(failure.stepIndex): expected \(failure.expected), got \(failure.actual)")
                                    .font(.caption)
                            }
                        }
                    }
                }
                Section("Stability probe (same plan-mode request, \(report.stability.runs) runs)") {
                    LabeledContent("Agreement", value: "\(agreementPercent)%")
                    LabeledContent("Distinct answers", value: "\(report.stability.distinctOutputs)")
                    LabeledContent("Failed runs", value: "\(report.stability.failures)")
                }
            }
            .navigationTitle("Evals")
        }
    }
}
