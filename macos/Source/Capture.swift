import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Foundation

final class TrackConverter {
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        if sourceFormat != input.format {
            sourceFormat = input.format; converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { throw issue("This audio device format could not be converted.") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw issue("Could not allocate an audio conversion buffer.") }
        var supplied = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard result != .error, let channel = output.floatChannelData?[0] else { throw issue("Audio conversion failed.") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let folder: URL
    let microphoneID: String
    let queue = DispatchQueue(label: "LocalMeetingNotes.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var system: WAVWriter?
    private var microphone: WAVWriter?
    private let systemConverter = TrackConverter(), microphoneConverter = TrackConverter()
    private var origin = 0.0, stopping = false
    private var capturedError: Error?
    private var lastMeterUpdate = 0.0
    private var systemPeak: Float = 0, microphonePeak: Float = 0
    private var sawSignal = false
    private(set) var startTime = 0.0
    var onMeters: ((Float, Float, Bool) -> Void)?
    var onFailure: ((Error) -> Void)?
    init(folder: URL, microphoneID: String) { self.folder = folder; self.microphoneID = microphoneID }
    var failure: Error? { queue.sync { capturedError } }
    var duration: Double { startTime > 0 ? max(0, ProcessInfo.processInfo.systemUptime - startTime) : 0 }
    var sourceFiles: [URL] {
        ["system.wav", "microphone.wav"].map { folder.appendingPathComponent($0) }.filter(Storage.exists)
    }
    func start() async throws {
        if microphoneID != "off" {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw issue("Microphone access was denied. Allow it in System Settings, or choose Microphone Off.") }
        }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw issue("System audio access could not start. Allow Local Meeting Notes in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen it.\n\n" + error.localizedDescription) }
        guard let display = content.displays.first else { throw issue("No active display is available for system audio capture.") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphoneID != "off"
        configuration.microphoneCaptureDeviceID = microphoneID.isEmpty ? nil : (microphoneID == "off" ? nil : microphoneID)
        configuration.sampleRate = 16_000; configuration.channelCount = 1
        configuration.width = 2; configuration.height = 2; configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if configuration.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try queue.sync {
            system = try WAVWriter(folder.appendingPathComponent("system.wav"))
            if configuration.captureMicrophone { microphone = try WAVWriter(folder.appendingPathComponent("microphone.wav")) }
        }
        try Storage.saveText(Date().description, to: folder.appendingPathComponent("recording.inprogress"))
        origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        startTime = ProcessInfo.processInfo.systemUptime; self.stream = stream
        do { try await stream.startCapture() }
        catch { try? await stop(); throw error }
    }
    func stop() async throws {
        queue.sync { stopping = true }
        var stopError: Error?
        if let stream { do { try await stream.stopCapture() } catch { stopError = error } }
        self.stream = nil
        let end = Int64((duration * 16_000).rounded())
        let fileError: Error? = queue.sync {
            var error = capturedError
            for writer in [system, microphone].compactMap({ $0 }) {
                do { try writer.close(at: end) } catch let failure { if error == nil { error = failure } }
            }
            system = nil; microphone = nil
            return error
        }
        if let error = fileError ?? stopError { throw error }
        try Storage.saveText(Date().description, to: folder.appendingPathComponent("recording.saved"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("recording.inprogress"))
    }
    func checkpoint() {
        queue.async { [weak self] in
            guard let self, !self.stopping, self.capturedError == nil else { return }
            do { try self.system?.checkpoint(); try self.microphone?.checkpoint() }
            catch { self.fail(error) }
        }
    }
    func requiredFreeBytes() throws -> Int64 {
        let bytes = Int64(duration * 32_000)
        let missing = try sourceFiles.reduce(Int64(0)) { sum, path in
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return sum + max(0, bytes + 44 - Int64(size))
        }
        return bytes + missing + 256 * 1_024 * 1_024
    }
    private func fail(_ error: Error) {
        if capturedError != nil || stopping { return }
        capturedError = error; onFailure?(error)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(error) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, capturedError == nil, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample), type == .audio || type == .microphone else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description), let format = AVAudioFormat(streamDescription: asbd) else { throw issue("An audio device supplied an invalid sample format.") }
            try sample.withAudioBufferList { buffers, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer) else { throw issue("Could not read a captured audio buffer.") }
                let converter = type == .audio ? systemConverter : microphoneConverter
                let values = try converter.convert(pcm)
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let relative = timestamp.isFinite ? timestamp - origin : duration - Double(values.count) / 16_000
                guard relative <= duration + 1 else { throw issue("An audio device returned an invalid recording timestamp.") }
                let writer = type == .audio ? system : microphone
                try writer?.append(values, at: Int64((relative * 16_000).rounded()))
                let peak = values.reduce(Float(0)) { max($0, $1.isFinite ? abs($1) : 0) }
                if peak > 0.002 { sawSignal = true }
                if type == .audio { systemPeak = peak } else { microphonePeak = peak }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastMeterUpdate > 0.2 { lastMeterUpdate = now; onMeters?(systemPeak, microphonePeak, sawSignal) }
            }
        } catch { fail(error) }
    }
}

enum AudioImport {
    static func normalize(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard Double(input.length) / input.processingFormat.sampleRate <= 8 * 3_600 else { throw issue("Choose a recording no longer than eight hours.") }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let block = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_000) else { throw issue("This audio format could not be converted.") }
        let writer = try WAVWriter(destination); defer { try? writer.close() }
        while true {
            var error: NSError?, readError: Error?
            let result = converter.convert(to: output, error: &error) { _, state in
                do {
                    try input.read(into: block)
                    if block.frameLength == 0 { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return block
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let error = readError ?? error { throw error }
            guard result != .error else { throw issue("Audio conversion failed.") }
            if let samples = output.floatChannelData?[0], output.frameLength > 0 {
                try writer.append(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))), at: writer.frames)
            }
            if result == .endOfStream { break }
        }
        try writer.close()
    }
}


