import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MicrophoneChoice: Identifiable { let id: String; let name: String }

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Phase: Equatable { case idle, starting, recording, saving, transcribing, recovering }
    @Published var phase = Phase.idle
    @Published var language = "de"
    @Published var microphoneID = ""
    @Published var microphones: [MicrophoneChoice] = []
    @Published var status = "Ready. Recording and transcription stay on this Mac."
    @Published var transcript = ""
    @Published var systemPeak: Float = 0
    @Published var microphonePeak: Float = 0
    @Published var errorMessage: String?
    @Published var confirmDeletion = false
    @Published var currentFolder: URL?
    @Published var selectedModel: URL?
    private var capture: Capture?
    private var process: Process?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var hasSignal = false, cancelled = false
    private var nextCheck = 0.0
    var busy: Bool { phase != .idle }
    var canDelete: Bool { phase == .idle && currentFolder.map { Storage.transcriptComplete($0) && Storage.hasAudio($0) } == true }
    var model: URL? { selectedModel ?? Bundle.main.url(forResource: "ggml-small-q5_1", withExtension: "bin", subdirectory: "Models") }
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        try? FileManager.default.createDirectory(at: Storage.meetings, withIntermediateDirectories: true)
        if let folders = try? FileManager.default.contentsOfDirectory(at: Storage.meetings, includingPropertiesForKeys: nil), folders.contains(where: {
            Storage.exists($0.appendingPathComponent("system.wav")) && !Storage.exists($0.appendingPathComponent("transcript.srt"))
        }) { status = "A saved recording has no completed transcript. Use Recover recording to continue." }
    }
    func chooseModel() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.canChooseDirectories = false
        panel.message = "Choose a compatible Whisper GGML .bin model."
        if panel.runModal() == .OK, let url = panel.url { selectedModel = url }
    }
    func refreshMicrophones() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { MicrophoneChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    private func keepAwake() {
        if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording or transcribing a local meeting") }
    }
    private func releaseActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }
    private func fail(_ error: Error) { errorMessage = error.localizedDescription; status = "Could not finish. Saved audio is kept. " + error.localizedDescription }
    func start() async {
        guard !busy else { return }
        phase = .starting; hasSignal = false; status = "Requesting audio capture access..."; keepAwake()
        do {
            guard model != nil else { throw issue("The bundled speech model is missing. Rebuild or replace the app bundle.") }
            guard try Storage.freeBytes(Storage.meetings) >= 1_024 * 1_024 * 1_024 else { throw issue("Keep at least 1 GB free before starting a long meeting.") }
            let folder = try Storage.newMeeting(); currentFolder = folder
            try Storage.saveText("Started: \(Date())\nLanguage: \(language)\nMicrophone: \(microphoneID.isEmpty ? "Default" : microphoneID)\n", to: folder.appendingPathComponent("meeting-info.txt"))
            let recorder = Capture(folder: folder, microphoneID: microphoneID); capture = recorder
            recorder.onMeters = { [weak self] system, mic, signal in Task { @MainActor in
                self?.systemPeak = min(1, system); self?.microphonePeak = min(1, mic)
                if signal { self?.hasSignal = true }
            } }
            recorder.onFailure = { [weak self] error in Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                await self.stop(transcribe: false); self.fail(error)
            } }
            try await recorder.start()
            transcript = ""; phase = .recording; nextCheck = ProcessInfo.processInfo.systemUptime + 5
        } catch {
            try? await capture?.stop(); capture = nil; phase = .idle; releaseActivity(); fail(error)
        }
    }
    private func tick() {
        guard phase == .recording, let capture else { return }
        if let error = capture.failure { Task { await stop(transcribe: false); fail(error) }; return }
        let seconds = Int(capture.duration)
        status = String(format: "Recording locally  %02d:%02d:%02d  |  Saving continuously", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        if capture.duration >= 8 * 3_600 { Task { await stop() }; return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextCheck {
            nextCheck = now + 5; capture.checkpoint()
            do {
                if try Storage.freeBytes(capture.folder) < capture.requiredFreeBytes() {
                    Task { await stop(); errorMessage = "Recording stopped because disk space is low. Available audio and completed transcripts are kept." }
                }
            } catch { Task { await stop(transcribe: false); fail(error) } }
        }
    }
    func stop(transcribe: Bool = true) async {
        guard phase == .recording, let recorder = capture else { return }
        phase = .saving; status = "Finalizing audio on disk..."
        defer { capture = nil; phase = .idle; systemPeak = 0; microphonePeak = 0; releaseActivity() }
        do {
            try await recorder.stop()
            if !transcribe { status = "Recording interrupted. Use Recover recording to continue."; return }
            let folder = recorder.folder, paths = recorder.sourceFiles
            let wav = folder.appendingPathComponent("meeting.wav")
            try await Task.detached(priority: .userInitiated) { try Storage.mix(paths, to: wav) }.value
            if !hasSignal { status = "Audio saved, but no audible signal was detected. Check permissions and devices before retrying."; return }
            try await runTranscription(wav, folder: folder)
        } catch { fail(error) }
    }
    func importWAV() async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a local WAV file. The original will stay untouched."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        phase = .saving; status = "Preparing audio locally..."; keepAwake()
        defer { phase = .idle; releaseActivity() }
        do {
            let folder = try Storage.newMeeting(); currentFolder = folder; let destination = folder.appendingPathComponent("meeting.wav")
            try await Task.detached(priority: .userInitiated) { try AudioImport.normalize(source, to: destination) }.value
            try await runTranscription(destination, folder: folder)
        } catch { fail(error) }
    }
    func recover() async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = Storage.meetings; panel.message = "Choose a saved meeting folder containing system.wav and optional microphone.wav. Originals will be kept."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        phase = .recovering; status = "Recovering copies of the saved audio..."; keepAwake()
        defer { phase = .idle; releaseActivity() }
        do {
            let sourceBytes = try ["system.wav", "microphone.wav"].map { source.appendingPathComponent($0) }.filter(Storage.exists).reduce(Int64(0)) {
                $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard sourceBytes > 0 else { throw issue("No saved recording tracks were found in that folder.") }
            guard try Storage.freeBytes(Storage.meetings) > sourceBytes * 2 + 256 * 1_024 * 1_024 else { throw issue("Free disk space for copies of the tracks and combined audio before recovering.") }
            let folder = try Storage.newMeeting(); currentFolder = folder
            try await Task.detached(priority: .userInitiated) { try Storage.recover(source, to: folder) }.value
            try await runTranscription(folder.appendingPathComponent("meeting.wav"), folder: folder)
        } catch { fail(error) }
    }
    private func runTranscription(_ wav: URL, folder: URL) async throws {
        guard let model, let helper = Bundle.main.url(forAuxiliaryExecutable: "transcribe-helper") else { throw issue("The bundled transcription helper or model is missing. Rebuild the app.") }
        phase = .transcribing; cancelled = false; transcript = ""; status = "Transcribing on this Mac. A long meeting may take several minutes or longer..."
        let prefix = folder.appendingPathComponent("transcript-pending")
        let logURL = folder.appendingPathComponent("transcription.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw issue("Could not create the transcription log.") }
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.synchronize(); try? log.close() }
        let task = Process(); task.executableURL = helper; task.arguments = [model.path, wav.path, language, prefix.path]
        task.standardOutput = log; task.standardError = log; process = task; defer { process = nil }
        let exit: Int32 = try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { task in continuation.resume(returning: task.terminationStatus) }
            do { try task.run() } catch { task.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        if cancelled { status = "Transcription cancelled. Audio is kept; use Transcribe a WAV to retry."; return }
        guard exit == 0 else { throw issue("Transcription failed. Audio is kept. See transcription.log in the meeting folder.") }
        let text = try String(contentsOf: prefix.appendingPathExtension("txt"), encoding: .utf8)
        let subtitles = try String(contentsOf: prefix.appendingPathExtension("srt"), encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !subtitles.isEmpty else { throw issue("No speech was transcribed. Audio is kept so you can retry.") }
        try Storage.saveText(text, to: folder.appendingPathComponent("transcript.txt"))
        try Storage.saveText(subtitles, to: folder.appendingPathComponent("transcript.srt"))
        try Storage.saveText(Date().description, to: folder.appendingPathComponent("transcription.complete"))
        transcript = subtitles; status = "Transcript saved. Review it, then choose Delete audio if you no longer need the recordings."
    }
    func cancel() { cancelled = true; if process?.isRunning == true { process?.terminate() }; status = "Cancelling transcription. Audio is kept..." }
    func openFolder() { NSWorkspace.shared.open(currentFolder ?? Storage.meetings) }
    func deleteAudio() {
        guard canDelete, let folder = currentFolder else { return }
        do { let count = try Storage.deleteAudio(folder); status = "Deleted \(count) audio file(s). Transcript, subtitles and logs are kept."; objectWillChange.send() }
        catch { fail(error) }
    }
}

@MainActor struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local Meeting Notes").font(.largeTitle.bold())
            Text("Record now. Transcribe after Stop. Everything stays on your Mac.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow { Text("System audio"); Text("All apps • system audio only, no video saved").foregroundStyle(.secondary) }
                GridRow {
                    Text("Microphone")
                    Picker("Microphone", selection: $model.microphoneID) {
                        Text("Default Mac microphone").tag("")
                        Text("Off — system audio only").tag("off")
                        ForEach(model.microphones) { choice in Text(choice.name).tag(choice.id) }
                    }.labelsHidden().disabled(model.busy)
                }
                GridRow {
                    Text("Meeting language")
                    Picker("Meeting language", selection: $model.language) { Text("German").tag("de"); Text("English").tag("en") }.labelsHidden().disabled(model.busy)
                }
            }
            HStack {
                Text("System"); ProgressView(value: Double(model.systemPeak)).frame(maxWidth: .infinity)
                Text("Microphone"); ProgressView(value: Double(model.microphonePeak)).frame(maxWidth: .infinity)
            }
            HStack { Text("Model: " + (model.model?.lastPathComponent ?? "Missing")).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Choose model…") { model.chooseModel() }.disabled(model.busy) }
            Text("Use headphones to avoid capturing other participants twice through your microphone.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Start recording") { Task { await model.start() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                Button("Stop and transcribe") { Task { await model.stop() } }.disabled(model.phase != .recording)
                Button("Transcribe a WAV…") { Task { await model.importWAV() } }.disabled(model.busy)
                Button("Cancel transcription") { model.cancel() }.disabled(model.phase != .transcribing)
            }
            HStack {
                Button("Open meeting folder") { model.openFolder() }
                Button("Recover recording…") { Task { await model.recover() } }.disabled(model.busy)
                Button("Delete audio…", role: .destructive) { model.confirmDeletion = true }.disabled(!model.canDelete)
            }
            HStack {
                if model.busy && model.phase != .recording { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).textSelection(.enabled)
            }.frame(minHeight: 36, alignment: .leading)
            Text("Audio is kept by default. Delete audio requires a completed transcript and your confirmation.").font(.caption).foregroundStyle(.secondary)
            Text("TRANSCRIPT").font(.caption.bold())
            ScrollView {
                Text(model.transcript.isEmpty ? "Your transcript will appear here after transcription." : model.transcript)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(NSColor.textBackgroundColor)).overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        }.padding(24).frame(minWidth: 820, minHeight: 690)
            .onAppear { model.refreshMicrophones() }
            .alert("Local Meeting Notes", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .confirmationDialog("Permanently delete this meeting's audio?", isPresented: $model.confirmDeletion, titleVisibility: .visible) {
                Button("Delete audio permanently", role: .destructive) { model.deleteAudio() }
                Button("Keep audio", role: .cancel) { }
            } message: { Text("The current meeting's WAV files will be permanently removed. Transcript, subtitles and logs stay. Imported or recovered originals in other folders stay. This cannot be undone.") }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Local Meeting Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; mainMenu.addItem(appItem); NSApp.mainMenu = mainMenu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Local Meeting Notes"; window.minSize = NSSize(width: 840, height: 730)
        window.contentView = NSHostingView(rootView: ContentView(model: AppModel.shared)); window.delegate = self
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    private func canClose() -> Bool {
        if !AppModel.shared.busy { return true }
        let alert = NSAlert(); alert.messageText = "Finish the current operation before closing."
        alert.informativeText = AppModel.shared.phase == .recording ? "Press Stop and transcribe to save your recording." : "Wait for the operation, or cancel transcription. Saved audio is kept."
        alert.runModal(); return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { canClose() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main @MainActor enum LocalMeetingNotesMain {
    static func main() {
        let app = NSApplication.shared, delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}



