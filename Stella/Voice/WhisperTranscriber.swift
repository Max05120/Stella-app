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
    
    func transcribe(samples: [Float]) throws -> String {
        
        guard let context else {
            throw WhisperError.contextCreationFailed
        }
        
        guard !samples.isEmpty else {
            return ""
        }
        
        var params = whisper_full_default_params(
            WHISPER_SAMPLING_BEAM_SEARCH
        )
        
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
        params.beam_search.beam_size = 5
        params.beam_search.patience = 1.0
        
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
            Stella is a personal desktop AI assistant running on macOS.
            The user is speaking conversational English to Stella.
            Common terms include Stella, macOS, Whisper, Ollama, SwiftUI,
            calendar, weather, reminder, music, application, window,
            microphone, backend, voice, listening, thinking, speaking,
            go idle, stop listening, we're done Stella, and hey Stella.
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
        
        let segmentCount =
        whisper_full_n_segments(
            context
        )
        
        var transcript = ""
        
        for index in 0..<segmentCount {
            
            guard let text =
                    whisper_full_get_segment_text(
                        context,
                        index
                    )
            else {
                continue
            }
            
            transcript +=
            String(
                cString: text
            )
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
