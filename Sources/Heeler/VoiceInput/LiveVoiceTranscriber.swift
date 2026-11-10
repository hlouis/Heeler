@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

/// Why the device's own recognition could not start.
enum LiveVoiceTranscriberError: Error, Equatable, Sendable {
    /// Before iOS 26, or no dictation model for this device.
    case unavailable
    case languageUnsupported
    /// The language's model is not on the device yet; Settings downloads it.
    case modelNotInstalled
    case failed

    var failure: VoiceInputFailure {
        switch self {
        case .unavailable:
            VoiceInputFailure(
                message: String(localized: "This device can't transcribe speech on its own. Choose a speech service."),
                opensVoiceInputSettings: true)
        case .languageUnsupported:
            VoiceInputFailure(
                message: String(localized: "This device can't transcribe the chosen language."),
                opensVoiceInputSettings: true)
        case .modelNotInstalled:
            VoiceInputFailure(
                message: String(localized: "Download the speech model for this language in Voice Input settings."),
                opensVoiceInputSettings: true)
        case .failed:
            VoiceInputFailure(message: String(localized: "Speech recognition stopped unexpectedly."))
        }
    }
}

/// Speech turned into text on this device as it is heard (ADR 0043).
@MainActor
protocol LiveVoiceTranscriber: AnyObject {
    /// Loads `locale`'s model, biased toward `keywords`, and returns where
    /// the recorder sends audio. `onText` gets the whole text so far each
    /// time it changes: settled words, then those still being revised.
    func start(
        locale: String, keywords: [String], onText: @escaping @MainActor (String) -> Void
    ) async throws -> VoiceAudioSink
    /// Settles the rest of what was heard and returns the whole text.
    func finish() async throws -> String
    /// Stops at once and drops what was not settled.
    func cancel()
}

/// Whether a language's on-device model is ready.
enum VoiceInputModelStatus: Equatable, Sendable {
    case unsupported
    case notInstalled
    case installed
}

/// `DictationTranscriber`, the model behind the keyboard's dictation, with
/// its short-dictation preset: punctuation, and words that are revised as
/// more is heard. One language per recording; English words inside Chinese
/// speech come through, and Keywords bias it toward the user's terms.
@available(iOS 26.0, *)
@MainActor
final class DeviceVoiceTranscriber: LiveVoiceTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<String, any Error>?

    init() {}

    func start(
        locale identifier: String, keywords: [String], onText: @escaping @MainActor (String) -> Void
    ) async throws -> VoiceAudioSink {
        let module = try await Self.module(for: identifier)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw LiveVoiceTranscriberError.modelNotInstalled
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LiveVoiceTranscriberError.failed
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if !keywords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = keywords
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.input = input
        results = Task { @MainActor in
            var settled = ""
            var revising = ""
            for try await result in module.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    settled += text
                    revising = ""
                } else {
                    revising = text
                }
                onText(settled + revising)
            }
            return settled + revising
        }
        let converter = VoicePCMConverter(to: format)
        return { buffer in
            guard let converted = converter.convert(buffer) else { return }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async throws -> String {
        input?.finish()
        input = nil
        guard let analyzer, let results else { return "" }
        self.analyzer = nil
        self.results = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    func cancel() {
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    /// The languages this device can transcribe, as BCP 47 identifiers.
    static func supportedLanguages() async -> [String] {
        await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
    }

    /// The supported language nearest `identifier`, as listed by
    /// `supportedLanguages()`.
    static func supportedLanguage(equivalentTo identifier: String) async -> String? {
        await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))?
            .identifier(.bcp47)
    }

    static func modelStatus(for identifier: String) async -> VoiceInputModelStatus {
        guard let module = try? await module(for: identifier) else { return .unsupported }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .supported, .downloading: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads `identifier`'s model, reporting progress from 0 to 1.
    static func downloadModel(
        for identifier: String, progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let module = try await module(for: identifier)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return
        }
        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    /// The transcriber for the supported locale nearest `identifier`.
    private static func module(for identifier: String) async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { throw LiveVoiceTranscriberError.languageUnsupported }
        return DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }
}
