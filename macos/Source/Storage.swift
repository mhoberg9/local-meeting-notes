import Foundation
import Darwin

func issue(_ message: String) -> NSError {
    NSError(domain: "LocalMeetingNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8) }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | (UInt32(u16(offset + 2)) << 16) }
    mutating func put16(_ value: UInt16, _ offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value); self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    mutating func put32(_ value: UInt32, _ offset: Int) {
        put16(UInt16(truncatingIfNeeded: value), offset); put16(UInt16(truncatingIfNeeded: value >> 16), offset + 2)
    }
    func tag(_ offset: Int) -> String { String(decoding: self[offset..<offset + 4], as: UTF8.self) }
}

struct WAVHeader {
    let dataStart: UInt64
    let sizeOffset: UInt64
    let bytes: UInt64
    static func read(_ file: FileHandle, usePhysicalSize: Bool = false) throws -> WAVHeader {
        let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        let head = try file.read(upToCount: Int(min(size, 1_048_576))) ?? Data()
        guard head.count >= 12, head.tag(0) == "RIFF", head.tag(8) == "WAVE" else { throw issue("Not a readable WAV recording.") }
        var offset = 12, valid = false
        while offset + 8 <= head.count {
            let name = head.tag(offset), count = Int(head.u32(offset + 4)), start = offset + 8
            if name == "fmt ", count >= 16, start + 16 <= head.count {
                valid = head.u16(start) == 1 && head.u16(start + 2) == 1 && head.u32(start + 4) == 16_000 && head.u16(start + 12) == 2 && head.u16(start + 14) == 16
            }
            if name == "data" {
                guard valid, UInt64(start) <= size else { throw issue("Recovery requires a 16 kHz mono PCM recording track from this app.") }
                let available = (size - UInt64(start)) / 2 * 2
                let length = usePhysicalSize ? available : min(UInt64(count), available) / 2 * 2
                return WAVHeader(dataStart: UInt64(start), sizeOffset: UInt64(offset + 4), bytes: length)
            }
            guard count <= head.count - start else { break }
            offset = start + count + (count & 1)
        }
        throw issue("No WAV audio data was found.")
    }
}

final class WAVWriter {
    static let rate = 16_000
    private let file: FileHandle
    private(set) var frames: Int64 = 0
    private var lastCheckpoint = ProcessInfo.processInfo.systemUptime
    private var closed = false
    init(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil) else { throw issue("Could not create a new audio track.") }
        file = try FileHandle(forUpdating: url)
        guard flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { try? file.close(); throw issue("The audio track is already in use.") }
        var header = Data(repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Data("RIFF".utf8)); header.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        header.replaceSubrange(12..<16, with: Data("fmt ".utf8)); header.put32(16, 16); header.put16(1, 20); header.put16(1, 22)
        header.put32(16_000, 24); header.put32(32_000, 28); header.put16(2, 32); header.put16(16, 34)
        header.replaceSubrange(36..<40, with: Data("data".utf8))
        try file.write(contentsOf: header); try checkpoint()
    }
    func append(_ samples: [Float], at start: Int64) throws {
        let skipped = Int(min(Int64(samples.count), max(0, frames - start)))
        try pad(to: max(0, start))
        var data = Data(repeating: 0, count: (samples.count - skipped) * 2)
        for i in skipped..<samples.count {
            let value = samples[i].isFinite ? max(-1, min(1, samples[i])) : 0
            data.put16(UInt16(bitPattern: Int16((value * 32_767).rounded())), (i - skipped) * 2)
        }
        try file.write(contentsOf: data); frames += Int64(samples.count - skipped); try checkpointIfDue()
    }
    func pad(to end: Int64) throws {
        let silence = Data(repeating: 0, count: 32_000)
        while frames < end {
            let count = Int(min(16_000, end - frames))
            try file.write(contentsOf: silence.prefix(count * 2)); frames += Int64(count)
        }
    }
    func checkpointIfDue() throws {
        if ProcessInfo.processInfo.systemUptime - lastCheckpoint >= 5 { try checkpoint() }
    }
    func checkpoint() throws {
        guard frames * 2 + 36 <= Int64(UInt32.max) else { throw issue("The WAV recording has reached its size limit.") }
        var size = Data(repeating: 0, count: 4)
        size.put32(UInt32(frames * 2 + 36), 0); try file.seek(toOffset: 4); try file.write(contentsOf: size)
        size.put32(UInt32(frames * 2), 0); try file.seek(toOffset: 40); try file.write(contentsOf: size)
        try file.synchronize(); try file.seek(toOffset: UInt64(44 + frames * 2)); lastCheckpoint = ProcessInfo.processInfo.systemUptime
    }
    func close(at end: Int64? = nil) throws {
        if closed { return }
        defer { closed = true; try? file.close() }
        if let end { try pad(to: end) }
        try checkpoint()
    }
    deinit { try? close() }
}

private final class WAVReader {
    let file: FileHandle
    var remaining: UInt64
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        let header = try WAVHeader.read(file); remaining = header.bytes; try file.seek(toOffset: header.dataStart)
    }
    func read(_ frames: Int) throws -> [Float] {
        let count = Int(min(remaining, UInt64(frames * 2)))
        var data = Data()
        while data.count < count {
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { throw issue("An audio track ended unexpectedly.") }
            data.append(part)
        }
        remaining -= UInt64(count)
        return stride(from: 0, to: data.count, by: 2).map { Float(Int16(bitPattern: data.u16($0))) / 32_768 }
    }
    deinit { try? file.close() }
}

enum Storage {
    static let audioNames = ["system.wav", "microphone.wav", "meeting.wav"]
    static var meetings: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMeetingNotes/Meetings", isDirectory: true)
    }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func newMeeting() throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = meetings.appendingPathComponent(formatter.string(from: Date()) + "_" + String(UUID().uuidString.prefix(6)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func saveText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
    }
    static func freeBytes(_ folder: URL) throws -> Int64 {
        let info = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        guard let free = info[.systemFreeSize] as? NSNumber else { throw issue("Could not check free disk space.") }
        return free.int64Value
    }
    static func hasAudio(_ folder: URL) -> Bool { audioNames.contains { exists(folder.appendingPathComponent($0)) } }
    static func transcriptComplete(_ folder: URL) -> Bool {
        exists(folder.appendingPathComponent("transcription.complete")) && ["transcript.txt", "transcript.srt"].allSatisfy {
            let value = try? folder.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]); return (value?.fileSize ?? 0) > 0
        }
    }
    static func mix(_ paths: [URL], to destination: URL) throws {
        guard !paths.isEmpty else { throw issue("No saved audio tracks were found.") }
        let readers = try paths.map { try WAVReader($0) }, writer = try WAVWriter(destination)
        defer { try? writer.close() }
        while true {
            let tracks = try readers.map { try $0.read(16_000) }
            let count = tracks.map(\.count).max() ?? 0
            if count == 0 { break }
            var mixed = [Float](repeating: 0, count: count)
            for track in tracks { for i in track.indices { mixed[i] += track[i] / Float(readers.count) } }
            try writer.append(mixed, at: writer.frames)
        }
        try writer.close()
    }
    static func recover(_ original: URL, to folder: URL) throws {
        var copies = [URL]()
        for name in ["system.wav", "microphone.wav"] {
            let source = original.appendingPathComponent(name); if !exists(source) { continue }
            guard (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw issue("Cannot recover linked recording tracks.") }
            let lock = try FileHandle(forReadingFrom: source); defer { try? lock.close() }
            guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw issue("This recording is still active. Stop it before recovery.") }
            let copy = folder.appendingPathComponent(name); try FileManager.default.copyItem(at: source, to: copy)
            let file = try FileHandle(forUpdating: copy); defer { try? file.close() }
            let header = try WAVHeader.read(file, usePhysicalSize: true)
            guard header.dataStart + header.bytes - 8 <= UInt64(UInt32.max) else { throw issue("The interrupted track is too large to recover as WAV.") }
            try file.truncate(atOffset: header.dataStart + header.bytes)
            var size = Data(repeating: 0, count: 4)
            size.put32(UInt32(header.bytes), 0); try file.seek(toOffset: header.sizeOffset); try file.write(contentsOf: size)
            size.put32(UInt32(header.dataStart + header.bytes - 8), 0); try file.seek(toOffset: 4); try file.write(contentsOf: size); try file.synchronize()
            copies.append(copy)
        }
        try mix(copies, to: folder.appendingPathComponent("meeting.wav"))
        try saveText(original.path, to: folder.appendingPathComponent("recovered-from.txt"))
    }
    @discardableResult static func deleteAudio(_ folder: URL) throws -> Int {
        guard transcriptComplete(folder) else { throw issue("Audio deletion requires a complete saved transcript and subtitle file.") }
        guard (try folder.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw issue("Cannot delete audio through a linked folder.") }
        let paths = audioNames.map { folder.appendingPathComponent($0) }.filter(exists)
        for path in paths {
            guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw issue("Cannot delete linked audio files.") }
        }
        for path in paths { try FileManager.default.removeItem(at: path) }
        return paths.count
    }
}

