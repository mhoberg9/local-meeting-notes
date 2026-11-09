import Foundation
import Darwin

@main enum StorageTests {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--crash-fixture" {
            let folder = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let writer = try WAVWriter(folder.appendingPathComponent("system.wav"))
            let samples = [Float](repeating: 0.25, count: 16_000)
            try writer.append(samples, at: 0); try writer.checkpoint(); try writer.append(samples, at: 16_000)
            _exit(0) // Terminate without finalizing the WAV header.
        }
        guard args.count >= 2 else { throw issue("Supply an empty test directory.") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            let passed = try condition(); if !passed { throw issue("FAILED: " + message) }; print("PASS: " + message)
        }
        let samples = [Float](repeating: 0.25, count: 16_000), timeline = root.appendingPathComponent("timeline.wav")
        let writer = try WAVWriter(timeline)
        try writer.append(samples, at: 16_000); try writer.append(samples, at: 64_000); try writer.pad(to: 96_000); try writer.checkpoint()
        do {
            let reader = try FileHandle(forReadingFrom: timeline); defer { try? reader.close() }
            let header = try WAVHeader.read(reader)
            try check(header.bytes == 192_000, "A live checkpoint retains six seconds including silent gaps")
        }
        try writer.close()
        let active = root.appendingPathComponent("active", isDirectory: true), activeCopy = root.appendingPathComponent("active-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activeCopy, withIntermediateDirectories: true)
        let activeWriter = try WAVWriter(active.appendingPathComponent("system.wav"))
        try activeWriter.append(samples, at: 0); try activeWriter.checkpoint()
        var activeRefused = false
        do { try Storage.recover(active, to: activeCopy) } catch { activeRefused = true }
        try check(activeRefused, "Recovery refuses a track while its recording lock is held")
        try activeWriter.close()
        let crash = root.appendingPathComponent("interrupted", isDirectory: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = ["--crash-fixture", crash.path]; try process.run(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "An interrupted-writer fixture exits without cleanup")
        let original = crash.appendingPathComponent("system.wav"), originalBytes = try Data(contentsOf: original)
        let recovered = root.appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
        try Storage.recover(crash, to: recovered)
        try check(try Data(contentsOf: original) == originalBytes, "Recovery leaves original audio unchanged")
        do {
            let file = try FileHandle(forReadingFrom: recovered.appendingPathComponent("meeting.wav")); defer { try? file.close() }
            let header = try WAVHeader.read(file)
            try check(header.bytes == 64_000, "Recovery includes audio after the last WAV-header checkpoint")
        }
        var refused = false
        do { try Storage.deleteAudio(recovered) } catch { refused = true }
        try check(refused && Storage.hasAudio(recovered), "Audio cleanup is refused without a completed transcript")
        try Storage.saveText("Keep these notes.", to: recovered.appendingPathComponent("transcript.txt"))
        try Storage.saveText("1\n00:00:00,000 --> 00:00:02,000\nKeep these notes.\n", to: recovered.appendingPathComponent("transcript.srt"))
        try Storage.saveText("complete", to: recovered.appendingPathComponent("transcription.complete"))
        let removed = try Storage.deleteAudio(recovered)
        try check(removed == 2 && Storage.transcriptComplete(recovered) && Storage.exists(original), "Audio cleanup preserves notes and the original recording")
        if args.contains("--long") {
            let system = root.appendingPathComponent("long-system.wav"), mic = root.appendingPathComponent("long-mic.wav"), mix = root.appendingPathComponent("long-mix.wav")
            let a = try WAVWriter(system); try a.append(samples, at: 7_199 * 16_000); try a.close()
            let b = try WAVWriter(mic); try b.pad(to: 7_200 * 16_000); try b.close()
            try Storage.mix([system, mic], to: mix)
            let file = try FileHandle(forReadingFrom: mix), header = try WAVHeader.read(file)
            try check(header.bytes == 7_200 * 32_000, "Two-hour tracks retain their exact duration")
            try file.seek(toOffset: header.dataStart + header.bytes - 32_000)
            let ending = try file.read(upToCount: 2) ?? Data(); try file.close()
            try check(ending.count == 2 && ending.contains(where: { $0 != 0 }), "Speech at the end of a two-hour recording remains present")
            for path in [system, mic, mix] { try FileManager.default.removeItem(at: path) }
        }
    }
}

