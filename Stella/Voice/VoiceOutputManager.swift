@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceOutputManager:
    ObservableObject
{
    @Published private(set)
    var isSpeaking = false

    @Published private(set)
    var spectrum:
        AudioSpectrum = .zero
    var onPlaybackStarted: (() -> Void)?
    private var speechGeneration = UUID()

    private let kokoro: KokoroTTSEngine
    
    init(
        sharedEngine: AVAudioEngine,
        audioPreprocessor: AudioPreprocessor? = nil
    ) {
        kokoro =
            KokoroTTSEngine(
                sharedEngine: sharedEngine,
                audioPreprocessor: audioPreprocessor
            )
        kokoro.onPlaybackStarted = {
                [weak self] in

                self?.onPlaybackStarted?()
            }
    }

    private let avSpeech =
        AVSpeechTTSEngine()

    private var kokoroReady =
        false

    // MARK: - Prepare

    func prepare() async {

        do {

            try await kokoro.prepare()

            kokoroReady = true

            print(
                "[TTS] Kokoro primary ready"
            )

        } catch {

            kokoroReady = false

            print(
                "[TTS] Kokoro unavailable — AVSpeech fallback active:",
                error.localizedDescription
            )
        }
    }

    // MARK: - Speak

    func speak(
        _ text: String,
        onFinished:
            (() -> Void)? = nil
    ) {

        let cleaned =
            text.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !cleaned.isEmpty else {
            onFinished?()
            return
        }

        guard !isSpeaking else {
            print(
                "[TTS] ignored overlapping speech request"
            )
            return
        }
        
        speechGeneration = UUID()
        let generation = speechGeneration

        isSpeaking = true

        if kokoroReady {

            kokoro.onSpectrum = {
                [weak self]
                spectrum in

                self?.spectrum =
                    spectrum
            }

            kokoro.speak(
                cleaned,
                speed: 1.04
            ) {
                [weak self] in

                guard let self,
                      self.speechGeneration == generation
                else {
                    return
                }

                self.spectrum =
                    .zero

                self.isSpeaking =
                    false

                onFinished?()
            }

        } else {

            avSpeech.speak(
                cleaned,
                onSpectrum: {
                    [weak self] spectrum in

                    self?.spectrum =
                        spectrum
                },
                onFinished: {
                    [weak self] in

                    guard let self,
                          self.speechGeneration == generation
                    else {
                        return
                    }

                    self.spectrum =
                        .zero

                    self.isSpeaking =
                        false

                    onFinished?()
                }
            )
        }
    }

    // MARK: - Spectrum

    func spectrumSnapshot()
        -> AudioSpectrum
    {
        spectrum
    }

    // MARK: - Stop

    func stop() {
        
        speechGeneration = UUID()
        
        kokoro.stop()

        avSpeech.stop()

        spectrum = .zero

        isSpeaking = false
    }
}
