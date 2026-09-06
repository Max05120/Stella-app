# ✦ Stella (macOS app)

> Mac's local personal assistant, living in your menu bar.

Stella-app is a native **SwiftUI menu bar and voice companion** for macOS. It's the client half of the Stella project — the actual thinking happens in the [Stella](https://github.com/Max05120/Stella) Python backend (RAG, tool calling, memory); this app is the window, the voice, and the floating on-screen presence.

## Features

- **Menu bar app** — lives quietly in the menu bar with quick access to chat, settings, and quit.
- **Chat window** — a full conversation view (`ContentView` / `ChatView`) with a conversation list on the side, streamed answers, and an expandable "Sources" section showing which documents backed each answer.
- **Voice conversations** — a full spoken interaction loop:
  - Wake word detection ("Stella" / "Hey Stella") using Apple's on-device `SFSpeechRecognizer`.
  - Speech-to-text via a bundled **Whisper.cpp** transcriber.
  - Text-to-speech via **Kokoro**, running on-device and MLX-accelerated on Apple Silicon (with `AVSpeechSynthesizer` available as a fallback engine).
  - A visible state machine (`loading → idle → greeting → listening → transcribing → thinking → speaking`) so the UI always reflects what Stella is doing.
- **Floating desktop companion** — an animated "orb" (`StellaOrbView` / `StellaPlasmaOrb`) that lives on the desktop, reacts to audio while speaking, and tracks global mouse position.
- **Quick Ask panel** — a small floating, non-activating panel for firing off a question without opening the full chat window.
- **Settings** — shows live backend status, lets you restart the Python backend, and toggle whether Stella speaks her replies aloud.
- **Backend lifecycle management** — `BackendManager` launches, health-checks, and shuts down the Python backend automatically alongside the app.

## Architecture

```
┌─────────────────────────────┐        HTTP (localhost:8000)        ┌──────────────────────────┐
│         Stella-app          │ ───────────────────────────────────▶│      Stella backend       │
│  SwiftUI menu bar / voice    │ ◀───────────────────────────────────│  FastAPI + Ollama + RAG   │
└─────────────────────────────┘         /chat, /conversations        └──────────────────────────┘
```

On launch, `AppDelegate` starts `BackendManager`, which spawns the Python backend (`uvicorn api:app`) as a subprocess and polls `/health` until it's ready. All chat, conversation history, and memory operations go through `APIClient` talking to that local API.

## Project structure

```
Stella-app/
├── Stella.xcodeproj
├── Packages/
│   └── kokoro-swift/                # On-device TTS (Kokoro, MLX-accelerated)
└── Stella/
    ├── StellaApp.swift              # App entry point, menu bar scene, lifecycle
    ├── BackendManager.swift         # Launches/monitors the Python backend subprocess
    ├── APIClient.swift              # Talks to the FastAPI backend
    ├── ContentView.swift            # Chat window (split view)
    ├── ChatView.swift                # Message list, input, sources
    ├── ConversationListView.swift   # Sidebar of past conversations
    ├── QuickAskPanel(View).swift    # Floating quick-ask panel
    ├── SettingsView.swift           # Backend status + voice toggle
    ├── StellaDesktopController.swift / StellaDesktopView.swift
    │                                 # Floating desktop companion window
    ├── GlobalHotKey.swift            # Carbon-based global hotkey helper
    ├── GlobalMouseTracker.swift      # Tracks cursor for the desktop orb
    └── Voice/
        ├── WakeWordListener.swift    # "Stella" / "Hey Stella" detection
        ├── MicrophoneRecorder.swift
        ├── WhisperTranscriber.swift  # Speech-to-text
        ├── KokoroTTSEngine.swift / AVSpeechTTSEngine.swift / TTSEngine.swift
        ├── VoiceConversationManager.swift  # Orchestrates the voice state machine
        ├── VoiceOutputManager.swift
        ├── AudioSpectrumAnalyzer.swift      # Drives the orb's audio-reactive visuals
        └── StellaOrbView/                    # The animated desktop orb
```

## Requirements

- macOS 14+ (Apple Silicon strongly recommended — Kokoro TTS uses MLX)
- Xcode 15 or newer, Swift 5.9+
- The [Stella backend](https://github.com/Max05120/Stella) set up and runnable locally
- Swift Package dependencies (resolved automatically by Xcode): `mlx-swift`, `swift-numerics`, plus the bundled `whisper` and `Kokoro` packages

## Setup

1. **Set up the backend first.** Clone and configure [Stella](https://github.com/Max05120/Stella) per its README (Python venv, `pip install`, Ollama models pulled).

2. **Point the app at your backend.** `BackendManager.swift` currently launches the backend with a **hardcoded path**:

   ```swift
   private let projectPath = "/Users/max/Desktop/project_stella"
   private let pythonPath = "/Users/max/Desktop/project_stella/venv/bin/python3"
   ```

   Either clone the backend to exactly that path, or edit these two constants to point at wherever you cloned it and created its virtual environment.

3. **Open `Stella.xcodeproj` in Xcode** and let it resolve Swift Package dependencies.

4. **Build and run.** On first launch, macOS will prompt for:
   - Microphone access (voice input)
   - Speech recognition access (wake word + transcription)

   Grant both under **System Settings → Privacy & Security** if you're asked again later.

5. Stella appears as a ✦ icon in the menu bar. Use **Open Stella** for the chat window, or let the desktop orb greet you.

## Known limitations

- The backend path in `BackendManager.swift` is hardcoded to a specific developer machine — it needs to be edited (or made configurable) for other setups.
- `GlobalHotKey.swift` and the Quick Ask panel exist but aren't currently wired to an actual key combination or menu item — invoking Quick Ask isn't yet reachable from the running app.
- No code signing / notarization or distribution setup is included; this is built and run from source via Xcode.
- Versioned as `0.1` — an early, actively-evolving personal project.

## Related project

[**Stella**](https://github.com/Max05120/Stella) — the Python RAG/agent backend this app depends on.

## License

Personal project — no license has been specified yet.
