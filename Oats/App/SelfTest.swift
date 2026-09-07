import Foundation
import AVFoundation
import CoreGraphics

// Debug hook: OATS_SELFTEST_AUDIO=/path/to/audio launches the app, runs the
// file through the exact transcription pipeline used for meetings, writes the
// result next to the input as <name>.transcript.txt, and quits. Lets CI and
// agents verify the pipeline without a microphone.
enum SelfTest {
    static func runIfRequested() {
        if ProcessInfo.processInfo.environment["OATS_SELFTEST_LOGIC"] != nil {
            runLogic()
            return
        }
        if let secs = ProcessInfo.processInfo.environment["OATS_SELFTEST_MIC"] {
            runMic(seconds: Double(secs) ?? 6)
            return
        }
        runFile()
    }

    // OATS_SELFTEST_LOGIC=1 exercises the pure logic the UI depends on (graph
    // build/parse, action parsing, layout, space storage, emoji detection),
    // writes PASS/FAIL lines to /tmp/oats-logic.txt, and exits non-zero if any
    // check fails. No microphone, no models, no GUI.
    static func runLogic() {
        Task { @MainActor in
            var lines: [String] = []
            var failures = 0
            func check(_ name: String, _ condition: Bool) {
                lines.append("\(condition ? "PASS" : "FAIL")  \(name)")
                if !condition { failures += 1 }
            }

            // Knowledge graph: two meetings that both mention Sarah must merge her
            // into one node (weight 2, in both meetings) with two meeting nodes.
            let n1 = UUID(), n2 = UUID()
            let g1 = NoteGraph(
                entities: [GraphEntity(name: "Sarah", kind: .person),
                           GraphEntity(name: "Apollo", kind: .project)],
                relations: [GraphRelation(from: "Sarah", to: "Apollo", type: "leads")])
            let g2 = NoteGraph(entities: [GraphEntity(name: "sarah", kind: .person)], relations: [])
            let kg = GraphBuilder.build(notes: [(id: n1, title: "M1", graph: g1),
                                                (id: n2, title: "M2", graph: g2)])
            let sarah = kg.nodes.first { $0.id == "person:sarah" }
            check("graph merges shared entity across meetings", sarah?.weight == 2 && sarah?.noteIDs.count == 2)
            let meetingNodes = kg.nodes.filter { if case .meeting = $0.kind { return true }; return false }
            check("graph has one node per meeting", meetingNodes.count == 2)
            check("graph has entity nodes", kg.nodes.contains { $0.id == "project:apollo" })

            // Tolerant JSON parses.
            let pg = GraphParsing.parse("sure: {\"entities\":[{\"name\":\"Acme\",\"kind\":\"org\"}],\"relations\":[]} ok")
            check("graph JSON parse tolerates surrounding prose", pg.entities.count == 1 && pg.entities.first?.kind == .org)
            let acts = ActionParsing.parse("Here you go [{\"text\":\"Send the deck\",\"owner\":\"Marcus\"},{\"text\":\"\",\"owner\":null}]")
            check("action parse keeps real items, drops empty", acts.count == 1 && acts.first?.owner == "Marcus")

            // Force layout must place every node at a finite, in-bounds point.
            let size = CGSize(width: 600, height: 400)
            let pos = ForceLayout.layout(nodes: kg.nodes, edges: kg.edges, size: size, iterations: 80)
            var layoutOK = pos.count == kg.nodes.count
            for (_, p) in pos where !(p.x.isFinite && p.y.isFinite && p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height) {
                layoutOK = false
            }
            check("force layout is finite and in-bounds", layoutOK)

            // Two meetings with nothing in common must not pile up: each
            // component keeps its own region and the layout uses the canvas
            // instead of huddling in one corner.
            let dm1 = UUID(), dm2 = UUID()
            let dg = GraphBuilder.build(notes: [
                (id: dm1, title: "D1", graph: NoteGraph(
                    entities: [GraphEntity(name: "A1", kind: .person),
                               GraphEntity(name: "A2", kind: .topic),
                               GraphEntity(name: "A3", kind: .project)], relations: [])),
                (id: dm2, title: "D2", graph: NoteGraph(
                    entities: [GraphEntity(name: "B1", kind: .person),
                               GraphEntity(name: "B2", kind: .topic),
                               GraphEntity(name: "B3", kind: .org)], relations: []))
            ])
            let dSize = CGSize(width: 800, height: 600)
            let dpos = ForceLayout.layout(nodes: dg.nodes, edges: dg.edges, size: dSize)
            func centroid(of noteID: UUID) -> CGPoint {
                let pts = dg.nodes.filter { $0.noteIDs.contains(noteID) }.compactMap { dpos[$0.id] }
                let n = CGFloat(max(1, pts.count))
                return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n)
            }
            let c1 = centroid(of: dm1), c2 = centroid(of: dm2)
            check("disconnected components separate", hypot(c1.x - c2.x, c1.y - c2.y) > 150)
            let xs = dpos.values.map { $0.x }, ys = dpos.values.map { $0.y }
            let spreadW = (xs.max() ?? 0) - (xs.min() ?? 0)
            let spreadH = (ys.max() ?? 0) - (ys.min() ?? 0)
            check("layout fills the canvas", spreadW > dSize.width * 0.5 || spreadH > dSize.height * 0.5)

            // Seconds-long recordings must never grow an invented summary:
            // below the word floor the summary is deterministic and verbatim.
            let tinySegs = [TranscriptSegment(t: 4, channel: "me", text: "All right.")]
            check("tiny transcript is under the summary floor",
                  MeetingRecorder.spokenWordCount(tinySegs) < MeetingRecorder.summaryWordFloor)
            let tinyOut = MeetingRecorder.tinySummary(segments: tinySegs, thoughts: "")
            check("tiny summary is verbatim with no invented sections",
                  tinyOut.contains("All right.") && !tinyOut.contains("Decisions") && !tinyOut.contains("Action items"))
            check("tiny title comes from the first words",
                  MeetingRecorder.tinyTitle(segments: tinySegs) == "All right")

            // Emoji vs SF Symbol detection for space icons.
            check("emoji detection", SpaceGlyph.isEmoji("📚") && !SpaceGlyph.isEmoji("folder") && !SpaceGlyph.isEmoji(""))

            // SpaceStore full round-trip on disk, self-cleaning (net-zero).
            let store = SpaceStore()
            let before = store.spaces.count
            let sp = store.create(name: "SelfTest Space", symbol: "🧪")
            check("space created with emoji icon", store.space(id: sp.id)?.symbol == "🧪")
            let reloaded = SpaceStore()
            check("space persists across reload", reloaded.space(id: sp.id)?.name == "SelfTest Space")
            store.rename(id: sp.id, to: "SelfTest Renamed", symbol: "🚀")
            check("space rename and icon change", store.space(id: sp.id)?.name == "SelfTest Renamed" && store.space(id: sp.id)?.symbol == "🚀")
            let noteID = UUID()
            store.add(noteID: noteID, to: sp.id)
            check("space add meeting", store.space(id: sp.id)?.noteIDs.contains(noteID) == true)
            store.toggle(noteID: noteID, in: sp.id)
            check("space toggle removes meeting", store.space(id: sp.id)?.noteIDs.contains(noteID) == false)
            store.delete(id: sp.id)
            let after = SpaceStore()
            check("space deleted and cleaned up", after.space(id: sp.id) == nil && after.spaces.count == before)

            check("updater points at the public repo feed",
                  UpdateChecker.defaultFeedURL.contains("leonickson1/oats") &&
                  URL(string: UpdateChecker.defaultFeedURL) != nil)
            check("update version compare", UpdateChecker.shared.isNewer("0.2.0", than: "0.1.0") &&
                  !UpdateChecker.shared.isNewer("0.2.0", than: "0.2.0") &&
                  UpdateChecker.shared.isNewer("0.10.0", than: "0.9.1"))

            // The call detector must be able to read the HAL process list at all
            // (an empty set is fine; an OS error path would also return empty,
            // so this mainly proves the query does not crash or hang).
            _ = MeetingDetector.selfTestProbe()
            check("call detector HAL probe returns", true)

            // Companion window geometry: docked to the trailing edge, inside
            // the visible frame, and never below its minimum usable width.
            let visible = NSRect(x: 0, y: 38, width: 1512, height: 907)
            let dock = WindowManager.companionFrame(in: visible)
            check("companion frame docks inside the screen",
                  visible.contains(dock) &&
                  abs(dock.maxX - (visible.maxX - 12)) < 0.5 &&
                  dock.width >= 400 && dock.width <= 480 &&
                  dock.height > visible.height * 0.9)
            let tiny = WindowManager.companionFrame(in: NSRect(x: 0, y: 0, width: 1280, height: 720))
            check("companion frame stays sane on a small screen",
                  tiny.width >= 400 && tiny.minX >= 0 && tiny.height <= 720)

            lines.append("INFO  Apple Intelligence: \(AppleModel.isAvailable ? "available" : (AppleModel.reason ?? "unavailable"))")

            let summary = failures == 0 ? "ALL \(lines.count - 1) CHECKS PASSED" : "\(failures) FAILURE(S) of \(lines.count - 1)"
            lines.insert(summary, at: 0)
            try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: "/tmp/oats-logic.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }

    // Records from the real mic for N seconds through the meeting pipeline and
    // writes /tmp/oats-mic.txt with peak level, buffer count, and transcript.
    static func runMic(seconds: Double) {
        Task { @MainActor in
            let outURL = URL(fileURLWithPath: "/tmp/oats-mic.txt")
            var log: [String] = []
            var lines: [String] = []
            var bufferCount = 0
            var peak: Float = 0
            do {
                let granted = await MicCapture.requestPermission()
                log.append("mic permission granted: \(granted)")
                guard granted else { throw NSError(domain: "selftest", code: 1) }

                let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
                try await TranscriberPipeline.ensureAssets(locale: locale)
                let pipe = TranscriberPipeline(label: "mic")
                pipe.onResult = { text, isFinal in
                    log.append("result final=\(isFinal): \(text)")
                    if isFinal { lines.append(text) }
                }
                try await pipe.start(locale: locale)

                let mic = MicCapture()
                mic.onBuffer = { buffer in
                    bufferCount += 1
                    pipe.feed(buffer)
                }
                mic.onLevel = { level in peak = max(peak, level) }
                try mic.start(echoCancellation: false)
                log.append("mic engine started, format: \(String(describing: pipe))")

                try? await Task.sleep(for: .seconds(seconds))
                mic.stop()
                await pipe.finishAndWait()
                try? await Task.sleep(for: .milliseconds(500))
                log.append("buffers: \(bufferCount), peak level: \(peak)")
                log.append("TRANSCRIPT: \(lines.joined(separator: " "))")
                try log.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                log.append("ERROR: \(String(reflecting: error))")
                try? log.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    static func runFile() {
        guard let path = ProcessInfo.processInfo.environment["OATS_SELFTEST_AUDIO"] else { return }
        Task { @MainActor in
            let outURL = URL(fileURLWithPath: path + ".transcript.txt")
            var lines: [String] = []
            var step = "start"
            do {
                step = "locale"
                let locale = await TranscriberPipeline.supportedLocale(matching: Locale.current) ?? Locale(identifier: "en-US")
                step = "assets (locale \(locale.identifier))"
                try await TranscriberPipeline.ensureAssets(locale: locale)
                step = "pipeline"
                let pipe = TranscriberPipeline(label: "selftest")
                pipe.onResult = { text, isFinal in
                    if isFinal { lines.append(text) }
                }
                step = "pipe.start"
                try await pipe.start(locale: locale)

                step = "open audio file"
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                step = "read audio chunks"
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    pipe.feed(buffer)
                }
                await pipe.finishAndWait()
                // Final results land on the main actor; give them a beat.
                try? await Task.sleep(for: .milliseconds(500))
                try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                try? "SELFTEST ERROR at \(step): \(String(reflecting: error))".write(to: outURL, atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }
}
