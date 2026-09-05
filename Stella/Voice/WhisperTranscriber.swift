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
        params.greedy.best_of = 1
        
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
            Stella is a macOS desktop voice assistant.

            The user may speak short commands to control their Mac.

            Common command phrases include:
            open Spotify,
            open Safari,
            open Finder,
            open Terminal,
            open Xcode,
            open Music,
            open Notes,
            open Calendar,
            open Messages,
            open Mail,
            open Discord,
            open Visual Studio Code,
            open System Settings,
            open Downloads,
            open Desktop,
            open Documents,
            open Applications,
            launch Spotify,
            launch Safari,
            launch Xcode,
            show Downloads,
            show Desktop,
            go idle,
            Hey Stella,
            reveal file in Finder.

            Common command words:
            open, launch, start, show, reveal, create, make,
            move, copy, duplicate, rename, delete, remove, trash.

            Important names and terms:
            Stella, Spotify, Safari, Finder, Terminal, Xcode,
            SwiftUI, macOS, Ollama, Whisper, Downloads,
            Desktop, Documents, Applications.

            The user may also speak normal conversational English.
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
