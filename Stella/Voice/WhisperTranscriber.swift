import Foundation
import whisper

actor WhisperTranscriber {
    
    enum WhisperError: Error, LocalizedError {
        case modelNotFound
        case contextCreationFailed
        case transcriptionFailed(Int32)
        
        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Whisper model could not be found in the app bundle."
                
            case .contextCreationFailed:
                return "Whisper context could not be created."
                
            case .transcriptionFailed(let code):
                return "Whisper transcription failed with code \(code)."
            }
        }
    }
    
    private var context: OpaquePointer?
    
    init() throws {
        guard let modelURL = Bundle.main.url(
            forResource: "ggml-base.en",
            withExtension: "bin"
        ) else {
            throw WhisperError.modelNotFound
        }
        
        var contextParams = whisper_context_default_params()
        
        // Use the fast Metal path we benchmarked.
        contextParams.use_gpu = true
        
        let ctx = modelURL.path.withCString { path in
            whisper_init_from_file_with_params(
                path,
                contextParams
            )
        }
        
        guard let ctx else {
            throw WhisperError.contextCreationFailed
        }
        
        self.context = ctx
        
        print("[WHISPER] model loaded")
    }
    
    deinit {
        if let context {
            whisper_free(context)
        }
        
    }
    func shutdown() {
        guard let context else { return }

        // Clear ownership so deinit cannot free this twice.
        self.context = nil

        whisper_free(context)

        print("[WHISPER] native context released")
    }
    // MARK: - Completed Utterance

    /// New Stella voice pipeline entry point.
    ///
    /// TurnDetector owns speech segmentation.
    /// Whisper receives exactly one completed utterance.
    ///
    /// The microphone may run at 44.1 kHz, 48 kHz, or another
    /// hardware-native rate, so the completed utterance is converted
    /// to Whisper's required 16 kHz format here.
    func transcribe(
        utterance: TurnDetector.Utterance
    ) throws -> String {
        
        try Task.checkCancellation()
        let whisperSamples =
            try WhisperAudioResampler.resample(
                samples: utterance.samples,
                from: utterance.sampleRate
            )

        print(
            String(
                format:
                    "[WHISPER] input %.0fHz → 16000Hz, %d → %d samples",
                utterance.sampleRate,
                utterance.samples.count,
                whisperSamples.count
            )
        )

        return try transcribe(
            samples: whisperSamples
        )
    }
    
    func transcribe(samples: [Float]) throws -> String {
        
        try Task.checkCancellation()
        guard let context else {
            throw WhisperError.contextCreationFailed
        }
        
        guard !samples.isEmpty else {
            return ""
        }
        
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // MARK: - Output
        
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        
        params.translate = false
        
        
        // MARK: - Conversation decoding
        
        // Each Stella utterance is independent.
        params.no_context = true
        
        // VoiceConversationManager already segments one user
        // utterance at a time, so this is appropriate here.
        params.single_segment = true
        
        params.n_threads = 4
        
        
        // MARK: - Accuracy
        
        // Beam search is slower than greedy but generally
        // better for short ambiguous conversational phrases.
//        params.beam_search.beam_size = 8
//        params.beam_search.patience = 1.2
        params.greedy.best_of = 3
        
        // Deterministic initial decoding.
        params.temperature = 0.0
        
        // Reduce blank / non-speech output.
        params.suppress_blank = true
        params.suppress_nst = true
        
        
        whisper_reset_timings(context)
        
        let started =
        CFAbsoluteTimeGetCurrent()
        
        
        // Keep these C strings alive for the entire whisper_full()
        // call. Do not assign temporary Swift strings directly
        // to params.language / params.initial_prompt.
        
        let language = "en"
        
        let prompt =
            """
            Stella is a macOS desktop AI assistant.

            The user speaks conversational English and may occasionally
            give short macOS commands.

            Important names and technical terms:
            Stella, 
            macOS,
            SwiftUI,
            Xcode,
            Finder,
            Safari,
            Spotify,
            Ollama,
            Whisper,
            RAG,
            Retrieval-Augmented Generation,
            LLM,
            AI,
            machine learning,
            embeddings,
            vector database,
            ChromaDB,
            FastAPI,
            Python.
            """
        
        let result: Int32 =
        language.withCString { languagePointer in
            
            prompt.withCString { promptPointer in
                
                params.language =
                languagePointer
                
                params.initial_prompt =
                promptPointer
                
                return samples.withUnsafeBufferPointer {
                    buffer in
                    
                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return -1
                    }
                    
                    return whisper_full(
                        context,
                        params,
                        baseAddress,
                        Int32(buffer.count)
                    )
                }
            }
        }
        
        guard result == 0 else {
            throw WhisperError.transcriptionFailed(
                result
            )
        }
        
        
        // MARK: - Result
        
        let segmentCount = whisper_full_n_segments(context)
        var transcript = ""
        var maxNoSpeechProb: Float = 0

        for index in 0..<segmentCount {
            maxNoSpeechProb = max(maxNoSpeechProb, whisper_full_get_segment_no_speech_prob(context, index))
            guard let text = whisper_full_get_segment_text(context, index) else { continue }
            transcript += String(cString: text)
        }

        guard maxNoSpeechProb < 0.5 else {
            print("[WHISPER] rejected, no_speech_prob=\(maxNoSpeechProb)")
            return ""
        }
        
        let elapsed =
        (
            CFAbsoluteTimeGetCurrent()
            - started
        ) * 1000
        
        print(
            "[WHISPER] transcription \(String(format: "%.1f", elapsed))ms"
        )
        
        return transcript
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }
}
