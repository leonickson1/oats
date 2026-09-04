# Earshot

Meeting notes that never leave your Mac.

No bot joins your calls. No audio goes to a server. No subscription. Your notes are plain markdown files on disk, and the AI brain is whatever you already have installed: Claude Code, Codex, or Ollama.

## What it does

- **Live meeting notes**: press Record (or Opt+M). Earshot captures your mic and the system audio of your call directly on-device, transcribes both sides live ("Me" and "Them") with Apple's on-device speech models, pauses and resumes, and names the note automatically once the conversation has shape.
- **Summaries with your own AI**: when you stop, the transcript is piped into the first agent found on your Mac (`claude`, `codex`, or a local Ollama server) and comes back as a structured summary with decisions and action items. No Earshot server, no API keys.
- **Ask anything**: during or after a meeting, ask questions ("What did I miss?", "What were the action items?"). Answers come from your local agent, grounded in the transcript.
- **Capture slides and screens**: a capture button grabs any region of your screen (a slide in Zoom, a chart in a video) into the note. Right-click a capture to read its text on-device (Vision OCR); that text feeds the summary too.
- **Real notes, not a text box**: the My thoughts editor is rich text (bold, italic, underline, strikethrough), takes dropped images, and links get native previews.

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
                                                    │      screen captures ── Vision OCR
                                                    ▼            ▼
                                     your agent CLI (claude -p / codex / ollama)
                                                    │
                                                    ▼
                                   summary.md, live titles, chat answers
```

- System audio capture uses Core Audio process taps (macOS 14.2+ API). It needs the "System Audio Recording" permission once. Nothing else sees your call.
- Both audio channels feed Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+), fully on-device.
- The UI is native SwiftUI with Liquid Glass; a small floating lozenge shows recording state and expands on hover.
- Notes live in `~/Library/Application Support/Earshot/notes/<id>/` as `meta.json`, `transcript.jsonl`, `note.md` (plus `thoughts.json` for formatting), `summary.md`, `chat.jsonl`, and `assets/` for captures. Grep them, sync them, back them up. They are yours.

## Build

Requires macOS 26+, Xcode 26+, and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Earshot.xcodeproj -scheme Earshot -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Earshot.app
```

Set your own `DEVELOPMENT_TEAM` in `project.yml` (a plain Apple Development certificate is enough; no paid account needed for local use).

On first run, grant:

1. **Microphone** (prompted on first recording)
2. **System Audio Recording** (prompted on first meeting note)
3. **Screen Recording** (only if you use the capture button)

The first recording also downloads Apple's on-device speech model for your language; Earshot pre-warms this at launch.

### Testing the pipeline without a microphone

```sh
say -o /tmp/test.wav --data-format=LEI16@22050 "Hello from the test rig."
EARSHOT_SELFTEST_AUDIO=/tmp/test.wav ./build/Build/Products/Debug/Earshot.app/Contents/MacOS/Earshot
cat /tmp/test.wav.transcript.txt
```

## Permissions and consent

Earshot records only on your explicit action and shows a visible recording state at all times. Recording other people without their consent is illegal in many places. Always get consent when transcribing others.

## License

MIT
