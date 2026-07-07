# scribe-native Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native Swift menu-bar rewrite of scribe per `docs/superpowers/specs/2026-07-07-scribe-native-design.md` — same validated behavior, real `.app` TCC identity, native onboarding.

**Architecture:** SwiftUI MenuBarExtra app in `native/` (XcodeGen). Pure logic ported 1:1 from the Python reference (which stays at repo root as oracle). Adapters: FluidAudio (Parakeet v3), WhisperKit (large-v3-turbo), mlx-swift-lm (Gemma 3 4B QAT via ChatSession). Golden eval parity gate (10/10) before cutover.

**Tech Stack:** Swift 6 toolchain (Xcode 16.4+; language mode 5 for pragmatic Sendable), SwiftUI, XcodeGen, FluidAudio 0.15.4, argmax-oss-swift 1.0.0 (WhisperKit), mlx-swift-lm 3.31.4 + swift-huggingface 0.9 + swift-transformers 1.3, XCTest.

## Global Constraints

- Deployment target **macOS 15.0**, Apple Silicon only; bundle id `dev.esoto.scribe`; `LSUIElement = true` (menu-bar only, no Dock).
- No sandbox, no hardened runtime (dev); ad-hoc signing.
- Pure logic must match the Python reference exactly: energy gate default **0.0005**, min_words **4**, length band **0.5–1.3**, cleanup timeout **6 s**, clipboard restore **2.0 s**, hold threshold **0.3 s**, history **10**, idle unload **15 min**, keycodes right ⌘=54 / right ⌥=61 / F13=105, masks 0x100000 / 0x80000.
- Cleanup prompt + few-shots: copy **verbatim** from `src/scribe/cleanup/base.py` (SYSTEM_PROMPT and `_FEWSHOT`). Any change requires the golden eval.
- Dev hotkey default **right_option** until cutover (spec §8); the Python app keeps right ⌘.
- Test fixtures and golden set are the SHARED files at `tests_models/` — locate from tests via `#filePath` traversal, do not copy.
- **Verified API facts (2026-07-07 research, measured from tagged source — do not re-derive):**
  - FluidAudio: `AsrModels.downloadAndLoad(version: .v3)`; `AsrManager(config: .default)` is an **actor**; `try await manager.transcribe(samples, decoderState: &state)` — `decoderState: inout TdtDecoderState` is REQUIRED (`try TdtDecoderState()` default is correct for v3); use `AudioConverter().resampleBuffer(_:)` for AVAudioPCMBuffer→[Float]. README examples without decoderState are stale — trust this, not the README.
  - WhisperKit: package URL is now `https://github.com/argmaxinc/argmax-oss-swift` v1.0.0, module still `import WhisperKit`. `try await WhisperKit(WhisperKitConfig(model: "openai_whisper-large-v3-v20240930_turbo"))`; `try await pipe.transcribe(audioArray:decodeOptions:)` → `[TranscriptionResult]`; `DecodingOptions(task: .transcribe, language: nil, temperature: 0.0, usePrefillPrompt: false, detectLanguage: true, skipSpecialTokens: true, chunkingStrategy: .vad)`. No condition-on-previous-text exists; leave promptTokens nil.
  - mlx-swift-lm: `ModelConfiguration(id: "mlx-community/gemma-3-4b-it-qat-4bit")`; `let container = try await #huggingFaceLoadModelContainer(configuration: config)` (needs `import MLXLLM MLXLMCommon MLXHuggingFace HuggingFace Tokenizers`); `ChatSession(container, instructions: …, history: [.user(…), .assistant(…)…], generateParameters: GenerateParameters(maxTokens: …, temperature: 0.0))`; `try await session.respond(to: text)`. gemma3 text-only load from the multimodal QAT repo is supported by design (`Gemma3TextModel` sanitizes away vision weights). `ModelContainer` is Sendable and serializes GPU access internally (replaces Python's MlxThread). ChatSession is NOT reusable across dictations with prior state — create a fresh session per clean() call (history must stay = few-shots only).
  - HF cache: same `~/.cache/huggingface/hub` (non-sandboxed) — Gemma already cached from the Python app; FluidAudio caches under `~/Library/Application Support/FluidAudio/Models/`; WhisperKit under its downloadBase.

## File Structure

```
native/
├── project.yml
├── Sources/Scribe/
│   ├── ScribeApp.swift            # @main MenuBarExtra + wiring (adapter)
│   ├── Pipeline.swift             # DictationPipeline + State (pure)
│   ├── Gates.swift                # (pure)
│   ├── KeyStateMachine.swift      # (pure)
│   ├── History.swift              # (pure)
│   ├── CleanupPrompt.swift        # verbatim prompt + buildHistory + maxTokens (pure)
│   ├── PasteCore.swift            # Paster logic w/ injected pasteboard (pure)
│   ├── OnboardingState.swift      # (pure)
│   ├── AppSettings.swift          # UserDefaults + toml import (pure-ish)
│   ├── RingBuffer.swift           # (pure)
│   ├── Recorder.swift             # AVAudioEngine adapter
│   ├── HotkeyMonitor.swift        # CGEventTap adapter
│   ├── SttEngines.swift           # ParakeetEngine + WhisperEngine adapters + LazyModel
│   ├── GemmaBackend.swift         # mlx-swift-lm adapter
│   ├── PasteAdapters.swift        # NSPasteboard/CGEvent/SMAppService
│   ├── MenuBarView.swift          # SwiftUI menu + SettingsView
│   └── OnboardingWindow.swift     # SwiftUI window + TCC request adapters
├── Sources/ScribeSpike/main.swift # Task-1 validation CLI
└── Tests/
    ├── ScribeTests/               # unit (no models)
    └── ScribeModelTests/          # fixtures + golden eval (real models)
```

Protocols shared across tasks (defined in Task 3, used everywhere):

```swift
protocol SttEngine { var name: String { get }; func transcribe(_ pcm: [Float]) async throws -> String }
protocol CleanupBackend { func clean(_ text: String) async throws -> String }
protocol PasteboardLike { func get() -> String?; func set(_ s: String); func changeCount() -> Int }
```

---

### Task 1: Scaffold + validation spike (GO/NO-GO)

**Files:** Create `native/project.yml`, `native/Sources/Scribe/ScribeApp.swift` (walking skeleton), `native/Sources/ScribeSpike/main.swift`, `native/Tests/ScribeTests/ScaffoldTests.swift`.

**Interfaces — Produces:** a building app target `Scribe`, executable `ScribeSpike`, test target wired; the GO/NO-GO verdict for FluidAudio/WhisperKit/Gemma.

- [ ] **Step 1:** `native/project.yml`:

```yaml
name: Scribe
options:
  bundleIdPrefix: dev.esoto
  deploymentTarget:
    macOS: "15.0"
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: 0.15.4
  ArgmaxOSS:
    url: https://github.com/argmaxinc/argmax-oss-swift
    from: 1.0.0
  MLXSwiftLM:
    url: https://github.com/ml-explore/mlx-swift-lm
    from: 3.31.4
  SwiftHuggingFace:
    url: https://github.com/huggingface/swift-huggingface
    from: 0.9.0
  SwiftTransformers:
    url: https://github.com/huggingface/swift-transformers
    from: 1.3.0
settings:
  base:
    SWIFT_VERSION: "5.0"
    MACOSX_DEPLOYMENT_TARGET: "15.0"
targets:
  Scribe:
    type: application
    platform: macOS
    sources: [Sources/Scribe]
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: scribe
        LSUIElement: true
        NSMicrophoneUsageDescription: "scribe listens while you hold the dictation key."
    dependencies: &mlDeps
      - package: FluidAudio
        product: FluidAudio
      - package: ArgmaxOSS
        product: WhisperKit
      - package: MLXSwiftLM
        products: [MLXLLM, MLXLMCommon, MLXHuggingFace]
      - package: SwiftHuggingFace
        product: HuggingFace
      - package: SwiftTransformers
        product: Tokenizers
  ScribeSpike:
    type: tool
    platform: macOS
    sources: [Sources/ScribeSpike]
    dependencies: *mlDeps
  ScribeTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/ScribeTests, Sources/Scribe]
  ScribeModelTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/ScribeModelTests, Sources/Scribe]
    dependencies: *mlDeps
```

(If YAML anchors trip XcodeGen, inline the dependency list per target.)

- [ ] **Step 2:** Walking-skeleton `ScribeApp.swift`:

```swift
import SwiftUI

@main
struct ScribeApp: App {
    var body: some Scene {
        MenuBarExtra("scribe", systemImage: "circle") {
            Text("scribe (skeleton)")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

`ScaffoldTests.swift`: `func testTruth() { XCTAssertTrue(true) }`

- [ ] **Step 3:** `cd native && xcodegen generate && xcodebuild -project Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS' build` → BUILD SUCCEEDED. Run unit tests: `xcodebuild test -scheme ScribeTests -destination 'platform=macOS'` → 1 test passes.
- [ ] **Step 4:** Spike `main.swift` — loads all three stacks against the shared fixtures and prints verdicts:

```swift
import AVFoundation
import FluidAudio
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import WhisperKit

func repoRoot() -> URL {  // native/Sources/ScribeSpike/main.swift -> repo root
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

func loadPcm(_ name: String) throws -> [Float] {
    let url = repoRoot().appendingPathComponent("tests_models/fixtures/\(name)")
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return try AudioConverter().resampleBuffer(buf)
}

let SYSTEM_PROMPT = "PASTE VERBATIM FROM src/scribe/cleanup/base.py AT IMPLEMENTATION TIME"

Task {
    do {
        print("=== FluidAudio Parakeet v3 ===")
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        var state = try TdtDecoderState()
        let t0 = Date()
        let en = try await asr.transcribe(try loadPcm("en.wav"), decoderState: &state)
        print("en (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(en.text)")
        var state2 = try TdtDecoderState()
        let es = try await asr.transcribe(try loadPcm("es.wav"), decoderState: &state2)
        print("es: \(es.text)")

        print("=== MLX Gemma 3 4B QAT ===")
        let config = ModelConfiguration(id: "mlx-community/gemma-3-4b-it-qat-4bit")
        let container = try await #huggingFaceLoadModelContainer(configuration: config)
        let session = ChatSession(container, instructions: SYSTEM_PROMPT,
            generateParameters: GenerateParameters(maxTokens: 200, temperature: 0.0))
        let t1 = Date()
        let cleaned = try await session.respond(
            to: "<transcript>\nso um I think we should uh we should probably move the the meeting to Tuesday no wait Wednesday afternoon and uh tell tell marcos about it\n</transcript>")
        print("cleaned (\(Int(Date().timeIntervalSince(t1) * 1000)) ms): \(cleaned)")

        print("=== WhisperKit large-v3-turbo ===")
        let pipe = try await WhisperKit(WhisperKitConfig(model: "openai_whisper-large-v3-v20240930_turbo"))
        let opts = DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
            usePrefillPrompt: false, detectLanguage: true, skipSpecialTokens: true, chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioArray: try loadPcm("mixed.wav"), decodeOptions: opts)
        print("mixed: \(results.map(\.text).joined(separator: " "))")
        print("SPIKE: GO")
    } catch {
        print("SPIKE FAILED: \(error)")
        exit(1)
    }
    exit(0)
}
RunLoop.main.run()
```

(Paste the real SYSTEM_PROMPT string from `src/scribe/cleanup/base.py` when writing the file — the constant above is a build-time reminder, not a runtime placeholder.)

- [ ] **Step 5:** Run: `xcodebuild -scheme ScribeSpike build && ./build/.../ScribeSpike` (or `swift run` via generated scheme). **GO criteria:** Parakeet en contains "Wednesday"/es contains "deberíamos"; Gemma cleaned contains "Wednesday" not "Tuesday"; Whisper mixed contains "deploy". **NO-GO on Gemma:** retry with `mlx-community/Qwen3-4B-Instruct-…` class model; if that passes the 3 probe cases, adopt as cleanup model and note in spec.
- [ ] **Step 6:** Record verdict + measured latencies in `native/SPIKE-RESULTS.md`. Commit `feat(native): scaffold + ML stack spike (GO)`.

---

### Task 2: Gates (pure)

**Files:** Create `native/Sources/Scribe/Gates.swift`, `native/Tests/ScribeTests/GatesTests.swift`.

**Interfaces — Produces:** `enum Gates { static func rms(_ pcm: [Float]) -> Double; static func passesEnergyGate(_ pcm: [Float], threshold: Double) -> Bool; static func shouldClean(_ text: String, enabled: Bool, minWords: Int) -> Bool; static func lengthOk(raw: String, cleaned: String, band: (Double, Double)) -> Bool; static func languageConsistent(raw: String, cleaned: String) -> Bool; static func normalize(_ text: String) -> String }`

- [ ] **Step 1: failing tests** — port `tests/test_gates.py` cases exactly:

```swift
import XCTest
@testable import Scribe

final class GatesTests: XCTestCase {
    func testRmsSilenceVsTone() {
        XCTAssertEqual(Gates.rms([Float](repeating: 0, count: 1600)), 0.0)
        let tone = (0..<1600).map { Float(0.1 * sin(Double($0) * 100.0 / 1600.0)) }
        XCTAssertGreaterThan(Gates.rms(tone), 0.05)
    }
    func testEnergyGate() {
        XCTAssertFalse(Gates.passesEnergyGate([Float](repeating: 0, count: 100), threshold: 0.0005))
        XCTAssertFalse(Gates.passesEnergyGate([], threshold: 0.0005))
        XCTAssertTrue(Gates.passesEnergyGate([Float](repeating: 0.1, count: 100), threshold: 0.0005))
    }
    func testShouldClean() {
        XCTAssertTrue(Gates.shouldClean("one two three four", enabled: true, minWords: 4))
        XCTAssertFalse(Gates.shouldClean("one two three", enabled: true, minWords: 4))
        XCTAssertFalse(Gates.shouldClean("one two three four", enabled: false, minWords: 4))
    }
    func testLengthOk() {
        let band = (0.5, 1.3)
        XCTAssertTrue(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 80), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 20), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 200), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: "hello", cleaned: "", band: band))
    }
    func testNormalizePreservesSpanish() {
        XCTAssertEqual(Gates.normalize("  el  martes,\n antes del mediodía.  "), "el martes, antes del mediodía.")
    }
    func testLanguageConsistentSameLanguage() {
        XCTAssertTrue(Gates.languageConsistent(raw: "so um move the meeting to friday", cleaned: "Move the meeting to Friday."))
        XCTAssertTrue(Gates.languageConsistent(raw: "este el codigo esta listo segun el equipo", cleaned: "El código está listo según el equipo."))
    }
    func testLanguageConsistentDetectsTranslation() {
        XCTAssertFalse(Gates.languageConsistent(raw: "digamos que el deploy se hace el viernes antes de las cinco", cleaned: "The deploy is done on Friday or before five."))
        XCTAssertFalse(Gates.languageConsistent(raw: "do you think we should ship this on friday", cleaned: "¿Deberíamos enviar esto el viernes?"))
    }
    func testLanguageConsistentNeutralPasses() {
        XCTAssertTrue(Gates.languageConsistent(raw: "ok deploy prod 123", cleaned: "Ok, deploy prod 123."))
    }
}
```

- [ ] **Step 2:** run (`xcodebuild test -scheme ScribeTests …`) → compile FAIL.
- [ ] **Step 3: implement** — port `src/scribe/gates.py` line-for-line. Stopword sets copied EXACTLY from `_EN_STOPWORDS` / `_ES_STOPWORDS`; score = en-hits − es-hits on lowercased whitespace-split words; inconsistent iff `rawScore * cleanedScore < 0 && abs(rawScore - cleanedScore) >= 3`. `normalize` = split on whitespace/newlines, join with single space.
- [ ] **Step 4:** tests pass. **Step 5:** commit `feat(native): gates ported`.

---

### Task 3: Protocols, History, KeyStateMachine (pure)

**Files:** Create `native/Sources/Scribe/Protocols.swift` (the three protocols from File Structure), `History.swift`, `KeyStateMachine.swift`; tests `HistoryTests.swift`, `KeyStateMachineTests.swift`.

**Interfaces — Produces:**
`struct DictationRecord { let raw: String; let final: String; let engine: String; let cleaned: Bool; let at: Date; let durationMs: Int }`;
`final class History { init(maxLen: Int); func append(_ r: DictationRecord); func items() -> [DictationRecord] /* newest first, thread-safe via NSLock */ }`;
`final class KeyStateMachine { init(key: HotKey); func handle(eventType: Int, keycode: Int, flags: UInt64) -> KeyAction? }` with `enum HotKey: String, CaseIterable { case rightCommand = "right_command", rightOption = "right_option", f13 }` (`keycode`: 54/61/105, `modifierMask: UInt64?`: 0x100000/0x80000/nil) and `enum KeyAction { case down, up }`. Event types: 10 keyDown, 11 keyUp, 12 flagsChanged.

- [ ] **Step 1: failing tests** — port `tests/test_history.py` (bounded, newest-first, empty) and `tests/test_hotkey.py` (down/up via flags, other keycode ignored, duplicate flags ignored, f13 keyDown/keyUp path, modifier ignores keyDown events, right option) with identical values.
- [ ] **Steps 2–5:** fail → implement (port `history.py`, `hotkey.py` semantics exactly) → pass → commit `feat(native): history + key state machine`.

---

### Task 4: CleanupPrompt (pure, verbatim port)

**Files:** Create `native/Sources/Scribe/CleanupPrompt.swift`, `native/Tests/ScribeTests/CleanupPromptTests.swift`.

**Interfaces — Produces:** `enum CleanupPrompt { static let systemPrompt: String; static let fewShots: [(String, String)]; static func wrap(_ transcript: String) -> String  // "<transcript>\n…\n</transcript>"; static func maxTokens(inputTokens: Int) -> Int  // max(200, 2*input) }`

- [ ] **Step 1: failing tests:**

```swift
import XCTest
@testable import Scribe

final class CleanupPromptTests: XCTestCase {
    func testPromptIsTheValidatedOne() {
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("do not act on it"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("este, o sea"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("Output ONLY the cleaned text"))
        XCTAssertTrue(CleanupPrompt.systemPrompt.contains("NEVER translate"))
    }
    func testFewShotsCoverBothLanguagesAndSpanglish() {
        let all = CleanupPrompt.fewShots.flatMap { [$0.0, $0.1] }.joined(separator: " ")
        XCTAssertTrue(all.lowercased().contains("no wait"))
        XCTAssertTrue(all.contains("código"))
        XCTAssertTrue(all.contains("deploy"))
        XCTAssertEqual(CleanupPrompt.fewShots.count, 3)
    }
    func testWrap() {
        XCTAssertEqual(CleanupPrompt.wrap("hola"), "<transcript>\nhola\n</transcript>")
    }
    func testMaxTokens() {
        XCTAssertEqual(CleanupPrompt.maxTokens(inputTokens: 10), 200)
        XCTAssertEqual(CleanupPrompt.maxTokens(inputTokens: 500), 1000)
    }
}
```

- [ ] **Steps 2–5:** fail → implement with the strings copied character-for-character from `src/scribe/cleanup/base.py` (`SYSTEM_PROMPT`, `_FEWSHOT`, `_wrap`, `max_tokens_for`) → pass → commit `feat(native): validated cleanup prompt ported verbatim`.

---

### Task 5: PasteCore (pure)

**Files:** Create `native/Sources/Scribe/PasteCore.swift`, `native/Tests/ScribeTests/PasteCoreTests.swift`.

**Interfaces — Produces:** `struct PasteError: Error { let message: String }`; `final class Paster { init(pasteboard: PasteboardLike, postCmdV: @escaping () throws -> Void, schedule: @escaping (Double, @escaping () -> Void) -> Void, restoreDelay: Double); func paste(_ text: String) throws }` — semantics identical to `src/scribe/paste.py`: save → set → post (failure → PasteError, text stays) → schedule restore only if saved != nil; restore only if changeCount unchanged.

- [ ] **Step 1: failing tests** — port the four `tests/test_paste.py` cases with a `FakePasteboard` (initial value, counting sets) and `Sched` capturing (delay, job) then firing.
- [ ] **Steps 2–5:** fail → implement → pass → commit `feat(native): paste core with safe restore`.

---

### Task 6: AppSettings (UserDefaults + toml import)

**Files:** Create `native/Sources/Scribe/AppSettings.swift`, `native/Tests/ScribeTests/AppSettingsTests.swift`.

**Interfaces — Produces:** `final class AppSettings` with typed accessors backed by an injected `UserDefaults` (tests use `UserDefaults(suiteName: UUID)`): `hotkey: HotKey` (default `.rightOption` — dev binding per spec §8), `holdThreshold: Double = 0.3`, `engine: String = "parakeet"`, `cleanupEnabled: Bool = true`, `minWords: Int = 4`, `cleanupTimeout: Double = 6.0`, `lengthBand: (Double, Double) = (0.5, 1.3)`, `restoreDelay: Double = 2.0`, `energyGate: Double = 0.0005`, `sounds: Bool = true`, `historySize: Int = 10`, `idleUnloadMinutes: Double = 15`. Plus `static func importToml(_ text: String) -> [String: Any]` — a minimal line parser for `key = value` under `[section]` headers handling strings/bools/numbers/2-float arrays, mapping the known python keys (`hotkey.key`→hotkey, `audio.energy_gate_rms`→energyGate, etc.), ignoring unknown keys; and `func importFromPythonConfigOnce()` which reads `~/.config/scribe/config.toml` if a `didImportToml` flag is unset.

- [ ] **Step 1: failing tests:** defaults match the table above; round-trip set/get; `importToml` on a sample string (`"[hotkey]\nkey = \"f13\"\n[audio]\nenergy_gate_rms = 0.001\n[cleanup]\nlength_band = [0.4, 1.5]\nbanana = 1"`) maps keys, ignores `banana`, tolerates junk lines; import-once flag prevents second import.
- [ ] **Steps 2–5:** fail → implement → pass → commit `feat(native): settings with one-time toml import`.

---

### Task 7: DictationPipeline (pure — the core port)

**Files:** Create `native/Sources/Scribe/Pipeline.swift`, `native/Tests/ScribeTests/PipelineTests.swift`, `native/Tests/ScribeTests/Fakes.swift`.

**Interfaces — Consumes:** Gates, History, protocols, AppSettings values (passed as a plain `PipelineConfig` struct so the pipeline doesn't touch UserDefaults).
**Produces:**

```swift
enum PipelineState { case idle, recording, processing, error }
struct PipelineConfig {   // mirrors the Python cfg subset the pipeline reads
    var holdThreshold = 0.3; var energyGate = 0.0005; var minWords = 4
    var cleanupTimeout = 6.0; var lengthBand = (0.5, 1.3); var sampleRate = 16000.0
}
protocol RecorderLike { func arm() throws; func disarm() -> [Float] }
final class DictationPipeline {
    init(recorder: RecorderLike, stt: SttEngine, cleaner: CleanupBackend?, paster: Paster,
         history: History, config: PipelineConfig,
         clock: @escaping () -> Double,          // tests inject
         runner: @escaping (@escaping () async -> Void) -> Void,  // tests run inline
         onState: @escaping (PipelineState) -> Void,
         onNotice: @escaping (String) -> Void,
         saveFailedAudio: @escaping ([Float]) -> Void)
    var engineName: String
    var cleanupEnabled: Bool
    func keyDown()
    func keyUp()
    func setEngine(_ engine: SttEngine, name: String)
}
```

Processing (async, inside runner): identical order to `src/scribe/pipeline.py::_process` — energy gate (log-silently discard) → `try await stt.transcribe` (SttError → saveFailedAudio + notice + .error flash) → normalize/empty check → shouldClean → cleanup with timeout (race `cleaner.clean` against `Task.sleep(cleanupTimeout)` via `withThrowingTaskGroup`; timeout/throw/gate-fail/language-flip → raw) → `paster.paste` (PasteError → notice "Paste failed — press ⌘V to paste manually") → history append → .idle. Default `runner` enqueues onto a serial `AsyncStream`-drained worker Task (FIFO); tests pass a synchronous runner that `await`s inline.

- [ ] **Step 1: failing tests** — port ALL 18 `tests/test_pipeline.py` cases with Swift fakes (FakeRecorder voiced/silent, FakeStt text/error/counting, FakeCleaner out/error/delay via `try await Task.sleep`, FakePaster, FakeClock advanced manually). Timeout test: cleaner delay 0.2 s vs config timeout 0.01 s → raw pasted. Translation test: ES raw + EN cleaned → raw pasted.
- [ ] **Steps 2–5:** fail → implement → pass (18 tests) → commit `feat(native): dictation pipeline state machine ported`.

---

### Task 8: OnboardingState (pure)

**Files:** Create `native/Sources/Scribe/OnboardingState.swift`, `native/Tests/ScribeTests/OnboardingStateTests.swift`.

**Interfaces — Produces:**

```swift
enum Grant: String, CaseIterable { case microphone, accessibility, inputMonitoring }
struct GrantStatus { var microphone: Bool; var accessibility: Bool; var inputMonitoring: Bool }
enum OnboardingStep: Equatable { case request(Grant), done }
enum OnboardingState {
    static func missing(_ s: GrantStatus) -> [Grant]           // stable order: mic, ax, im
    static func nextStep(_ s: GrantStatus) -> OnboardingStep
    static func summary(_ s: GrantStatus) -> String             // "2 of 3 permissions granted"
    static func settingsUrl(for g: Grant) -> URL                // x-apple.systempreferences deep links
}
```

Deep links: mic `…?Privacy_Microphone`, accessibility `…?Privacy_Accessibility`, input monitoring `…?Privacy_ListenEvent` (base `x-apple.systempreferences:com.apple.preference.security`).

- [ ] **Step 1: failing tests:** all-false → missing = 3, nextStep = .request(.microphone); mic-only granted → nextStep .request(.accessibility); all granted → .done; summary strings; each URL contains its pane token.
- [ ] **Steps 2–5:** fail → implement → pass → commit `feat(native): onboarding state logic`.

---

### Task 9: RingBuffer + Recorder adapter

**Files:** Create `native/Sources/Scribe/RingBuffer.swift`, `Recorder.swift`; test `RingBufferTests.swift`.

**Interfaces — Produces:** `final class RingBuffer { init(maxSeconds: Double, sampleRate: Double); func append(_ chunk: [Float]); func drain() -> [Float]; func clear() }` (cap = drop appends past capacity; NSLock) — port `tests/test_recorder.py` ring-buffer + armed-capture cases against a `Recorder` core with injected stream. `final class Recorder: RecorderLike` — AVAudioEngine adapter: `installTap(onBus: 0, bufferSize: 1024, format: 16 kHz mono Float32)` on `inputNode` (use `AVAudioConverter` from the input's native format to 16 kHz mono — inputNode cannot be forced to 16 kHz directly), appends to RingBuffer only while armed; `arm()` restarts a dead engine (`AVAudioEngineConfigurationChange` handling); adapter body excluded from unit coverage.
- [ ] **Steps 1–5:** TDD the pure parts (RingBuffer + armed logic with a fake source), implement adapter, commit `feat(native): recorder with armed ring buffer`.

---

### Task 10: STT engine adapters + LazyModel

**Files:** Create `native/Sources/Scribe/SttEngines.swift`.

**Interfaces — Consumes:** spike-verified APIs (Global Constraints). **Produces:**

```swift
actor LazyModel<M> {           // idle-unloadable, replaces Python ThreadBound*
    init(label: String, factory: @escaping () async throws -> M)
    func get() async throws -> M          // loads on first use, logs load time
    func unload()                          // drops reference (+ MLX cache eval if applicable)
    var isLoaded: Bool { get }
    func preload() async
}
final class ParakeetEngine: SttEngine {   // name = "parakeet"
    // LazyModel<(AsrManager, AsrModels)>; transcribe: fresh `try TdtDecoderState()` per call,
    // try await manager.transcribe(pcm, decoderState: &state); join/trim -> String
}
final class WhisperEngine: SttEngine {    // name = "whisper"
    // LazyModel<WhisperKit>; transcribe with the DecodingOptions from Global Constraints;
    // results.map(\.text).joined(separator: " ").trimmed
}
```

Both throw `SttError(message:)` (define in this file) wrapping any underlying error.
- [ ] Steps: unit-test `LazyModel` with a counting fake factory (loads once, unload → reload, preload); adapters compile; commit `feat(native): STT adapters + lazy model lifecycle`.

---

### Task 11: GemmaBackend

**Files:** Create `native/Sources/Scribe/GemmaBackend.swift`.

**Interfaces — Produces:** `final class GemmaBackend: CleanupBackend` — `LazyModel<ModelContainer>` with factory `try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: "mlx-community/gemma-3-4b-it-qat-4bit"))`. `clean(_:)`: build a **fresh** `ChatSession(container, instructions: CleanupPrompt.systemPrompt, history: fewShots as [.user/.assistant], generateParameters: GenerateParameters(maxTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4), temperature: 0.0))` and `respond(to: CleanupPrompt.wrap(text))`. (Token estimate chars/4 replaces the Python tokenizer count — the 2× margin absorbs the imprecision.) Throws `CleanupError(message:)`.
- [ ] Steps: implement (no new pure logic — covered by golden eval in Task 14), build green, commit `feat(native): Gemma cleanup backend`.

---

### Task 12: OS adapters — HotkeyMonitor, PasteAdapters, sounds, login item

**Files:** Create `native/Sources/Scribe/HotkeyMonitor.swift`, `PasteAdapters.swift`.

**Interfaces — Produces:**
- `final class HotkeyMonitor { init(key: HotKey, onDown: @escaping () -> Void, onUp: @escaping () -> Void); func install() throws }` — CGEventTap (session, headInsert, **listenOnly**) over flagsChanged|keyDown|keyUp feeding `KeyStateMachine`; after `CGEvent.tapEnable`, **verify `CGEvent.tapIsEnabled` and throw if false** (macOS 26 silent-disable, spec §3); `func reinstall()` for onboarding live-activation.
- `final class MacPasteboard: PasteboardLike` (NSPasteboard.general: string get/set/changeCount); `func postCmdV() throws` (CGEvent keycode 9 + `.maskCommand`, post to `.cghidEventTap`); `func timerSchedule(_ delay: Double, _ fn: @escaping () -> Void)` (DispatchQueue.main.asyncAfter); `enum Sounds { static func play(_ name: String) }` (NSSound(named:)); `enum LoginItem { static func enable() throws; static func disable() throws; static var isEnabled: Bool }` (SMAppService.mainApp).
- [ ] Steps: implement (adapter-only), build, commit `feat(native): hotkey + paste + login-item adapters`.

---

### Task 13: Menu bar UI + app wiring

**Files:** Rewrite `native/Sources/Scribe/ScribeApp.swift`, create `MenuBarView.swift`.

**Interfaces — Consumes:** everything above. **Produces:** the assembled app:
- `AppModel: ObservableObject` (MainActor): holds settings, pipeline, engines dict, cleaner, history, `@Published state: PipelineState`, `@Published grants: GrantStatus`; glyph mapping ◦●⋯⚠ (port `menubar.glyph_for`); builds components at launch — engines lazy, `preload` of default engine + cleaner in a background Task ("models ready" log); wires pipeline callbacks (state → published + Pop/Basso sounds per settings, notice → `UNUserNotificationCenter` with fallback log).
- `MenuBarExtra(title: glyph)` menu: Engine picker (parakeet/whisper — switch = preload new, `setEngine`, unload other), Cleanup toggle, History submenu (click = copy via MacPasteboard), "Setup / Doctor…" (opens onboarding window), Settings (opens SwiftUI Settings scene with the AppSettings fields), Launch at Login toggle, Quit.
- Idle unload: a repeating 60 s Task checks an `IdleTracker` port (same due()/touch() semantics as `src/scribe/idle.py`, touched on keyDown) → `unload()` all LazyModels; keyDown pre-warms via `preload()` in a detached Task.
- Failed-audio writer: 16-bit WAV to `~/Library/Logs/scribe/last_failed.wav` (port `save_failed_audio`). Logging: `Logger(subsystem: "dev.esoto.scribe", …)` + file handler to `~/Library/Logs/scribe/scribe.log`.
- [ ] Steps: port `IdleTracker` with its 4 tests first (TDD), then wiring; `xcodegen && xcodebuild` green; manual smoke: app shows ◦, menu items present; commit `feat(native): menu bar app wiring`.

---

### Task 14: Onboarding window + TCC request adapters

**Files:** Create `native/Sources/Scribe/OnboardingWindow.swift`.

**Interfaces — Consumes:** OnboardingState, HotkeyMonitor.reinstall. **Produces:** SwiftUI window (also reachable from menu as Doctor): three rows (mic/accessibility/input monitoring) with live ✓/✗ from a 2 s poll of probes — `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`, `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`; per-row "Request" button firing `AVCaptureDevice.requestAccess`, `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)`, `CGRequestListenEventAccess()`; per-row "Open Settings" via `NSWorkspace.shared.open(OnboardingState.settingsUrl(for:))`. When inputMonitoring flips to granted → call `hotkey.reinstall()` (live activation, no restart). When all granted → show "Hold Right ⌥ and speak" + a test TextField. Auto-opens at launch when `OnboardingState.missing` is non-empty.
- [ ] Steps: implement; manual verification on THIS Mac is limited (grants already exist for python, not for the new bundle — first `xcodebuild` run WILL exercise the real flow: expect all three ✗ → click through → verify auto-added "scribe" entries appear in Settings); commit `feat(native): native onboarding window`.

---

### Task 15: Model integration tests + golden eval (parity gate)

**Files:** Create `native/Tests/ScribeModelTests/FixtureTests.swift`, `GoldenEvalTests.swift`, shared helper `ModelTestSupport.swift` (repoRoot via `#filePath`, `loadPcm` like the spike).

- [ ] `FixtureTests`: Parakeet en.wav contains "wednesday"+"marcos" (lowercased), es.wav contains "deberíamos"+"mediodía", silence.wav → trimmed empty; energy gate blocks silence fixture at 0.0005 and passes voiced fixtures (port `test_stt_fixtures.py`); Whisper en.wav "wednesday"; concurrency regression: transcribe from `Task.detached` twice concurrently → both succeed (ModelContainer/actor serialization).
- [ ] `GoldenEvalTests`: decode `tests_models/golden.json` (Codable: id, input, must_contain, must_not_contain, optional comment) → run each through `GemmaBackend.clean` + `Gates.normalize`, assert lowercased contains/not-contains. **All 10 must pass — this is the cutover parity gate.**
- [ ] Run `xcodebuild test -scheme ScribeModelTests` until green; record timings in SPIKE-RESULTS.md; commit `test(native): fixture + golden eval parity suite`.

---

### Task 16: Verification, docs, cutover prep

- [ ] Full pass: unit tests, model tests, eval — all green; `xcodebuild build` warning-free.
- [ ] README: new "Native app (scribe.app)" section — build (`xcodegen generate && xcodebuild`), first-run onboarding description, cutover steps from spec §8; mark the Python sections as "reference implementation".
- [ ] Update `docs/pending-validation.md`: native parity checklist (golden 10/10 ✓ recorded, rule-of-five human check pending, cutover steps).
- [ ] Update memory (`scribe-dictation-app.md`): native app exists, spike results, cutover state.
- [ ] Commit `docs: scribe-native ready for parity validation`; report to user with the rule-of-five instructions (5 EN + 5 ES on both apps, Right ⌥ vs Right ⌘).

## Self-Review

- **Spec coverage:** §3 components → Tasks 2–13 (each row mapped); §4 ML + risks → Tasks 1, 10, 11 (spike first ✓, Qwen plan B in Task 1 Step 5); §5 onboarding → Tasks 8, 14; §6 errors → Task 7 (all rows in pipeline tests) + Task 13 (failed-audio, notifications); §7 testing → Tasks 2–8 unit, 15 models+golden; §8 cutover → Task 16 + AppSettings dev default rightOption (Task 6). Settings window (§3) → Task 13. SMAppService → Task 12. ✓
- **Placeholder scan:** the spike's SYSTEM_PROMPT constant is explicitly a build-time copy instruction with source path — acceptable; no TBDs remain. ✓
- **Type consistency:** `SttEngine.transcribe` async throws everywhere; `PasteboardLike` shared by PasteCore/adapters; `HotKey` enum used by settings + monitor + state machine; `PipelineConfig` field names consistent between Tasks 6/7/13. ✓
