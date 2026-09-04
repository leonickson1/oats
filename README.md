# Earshot

Meeting notes and dictation that never leave your Mac.

No bot joins your calls. No audio goes to a server. No subscription. Your notes are plain markdown files on disk, and the AI brain is whatever you already have installed: Claude Code, Codex, or Ollama.

## What it does

- **Notetaker**: press the record pill (or Opt+M). Earshot captures your mic and the system audio of your call directly on-device, transcribes both sides live with Apple's on-device speech models, and writes a structured summary when you stop.
- **Dictation**: press Opt+Period anywhere, speak, press it again. Your words are transcribed on-device and typed into whatever app you were using.
- **Ask anything**: during or after a meeting, ask questions ("What did I miss?", "What were the action items?"). Earshot feeds the transcript to your local agent CLI and shows the answer.

## Why it exists

The popular notetakers either send a bot into your call or upload your audio to their cloud (often both). Earshot uses the same endpoint-capture trick that made bot-free notetakers popular, but keeps the entire pipeline on your machine:

| | Bot | Cloud ASR | Cloud LLM | Your notes |
|---|---|---|---|---|
| Typical notetaker | sometimes | yes | yes | their database |
| Earshot | never | never | never | markdown files you own |

## How it works

```
mic ──── AVAudioEngine (echo cancelled) ──┐
                                          ├── SpeechAnalyzer (on-device) ── transcript.jsonl
system audio ── Core Audio process tap ───┘         │
                                                    ▼
                                     your agent CLI (claude -p / codex / ollama)
                                                    │
                                                    ▼
                                        summary.md + chat answers
```

- System audio capture uses Core Audio process taps (macOS 14.2+ API). It needs the "System Audio Recording" permission once. Nothing else sees your call.
- Both audio channels feed Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+), fully on-device. The mic channel is labeled "Me", the system channel "Them".
- Summaries and Q&A run through the first agent found: `claude` (Claude Code), `codex`, or a local Ollama server. You can pick in Settings. If none is installed, you still get full transcripts.
- Notes live in `~/Library/Application Support/Earshot/notes/<id>/` as `meta.json`, `transcript.jsonl`, `note.md`, `summary.md`, `chat.jsonl`. Grep them, sync them, back them up. They are yours.

## Build

Requires macOS 26+, Xcode 26+, and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Earshot.app
```

On first run, grant:

1. **Microphone** (prompted on first recording)
2. **System Audio Recording** (prompted on first meeting note)
3. **Accessibility** (only needed for dictation auto-insert; System Settings > Privacy & Security > Accessibility)

## Permissions and consent

Earshot records only on your explicit action and shows a visible recording state at all times. Recording other people without their consent is illegal in many places. Always get consent when transcribing others.

## License

MIT
