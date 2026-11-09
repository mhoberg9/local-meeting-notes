using System.Diagnostics;
using System.Security.Cryptography;
using NAudio.Wave;

namespace LocalMeetingNotes;

internal static class ReliabilityChecks
{
    private static byte[] Tone()
    {
        byte[] tone = new byte[AudioSession.Rate * 2];
        for (int i = 0; i < AudioSession.Rate; i++) BitConverter.GetBytes((short)8192).CopyTo(tone, i * 2);
        return tone;
    }
    public static void CrashFixture(string folder)
    {
        Directory.CreateDirectory(folder);
        var writer = new TimelineWriter(Path.Combine(folder, "system.wav"));
        byte[] tone = Tone();
        writer.Append(tone, tone.Length, 0);
        writer.Checkpoint();
        writer.Append(tone, tone.Length, AudioSession.Rate);
        // Exit without disposing the writer: simulate a process terminating before WAV finalization.
        Environment.Exit(0);
    }
    public static async Task RunAsync(string folder, Action<bool, string> check)
    {
        byte[] tone = Tone();
        string live = Path.Combine(folder, "live.wav");
        using (var writer = new TimelineWriter(live))
        {
            writer.Append(tone, tone.Length, 0);
            writer.Checkpoint();
            using var reader = new WaveFileReader(new FileStream(live, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
            check(reader.TotalTime == TimeSpan.FromSeconds(1), "A disk checkpoint is a readable WAV before normal shutdown");
        }
        string crash = Path.Combine(folder, "interrupted");
        var start = new ProcessStartInfo(Program.Executable) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--crash-fixture"); start.ArgumentList.Add(crash);
        using (var child = Process.Start(start)!) { await child.WaitForExitAsync(); check(child.ExitCode == 0, "Interruption fixture exited without running WAV cleanup"); }
        string original = Path.Combine(crash, "system.wav");
        byte[] originalHash = SHA256.HashData(await File.ReadAllBytesAsync(original));
        string recovered = Path.Combine(folder, "recovered");
        RecordingFiles.Recover(crash, recovered);
        using (var reader = new WaveFileReader(Path.Combine(recovered, "meeting.wav")))
            check(reader.TotalTime == TimeSpan.FromSeconds(2), "Recovery includes audio beyond the last checkpoint's stale WAV header");
        check(originalHash.SequenceEqual(SHA256.HashData(await File.ReadAllBytesAsync(original))), "Recovery leaves the original interrupted recording byte-for-byte unchanged");
        bool blocked = false;
        try { RecordingFiles.DeleteAudio(recovered); } catch (InvalidOperationException) { blocked = true; }
        check(blocked && File.Exists(Path.Combine(recovered, "meeting.wav")), "Audio deletion is blocked without a completed transcript");
        RecordingFiles.SaveText(Path.Combine(recovered, "transcript.txt"), "Keep these notes.");
        RecordingFiles.SaveText(Path.Combine(recovered, "transcript.srt"), "1\n00:00:00,000 --> 00:00:02,000\nKeep these notes.\n");
        RecordingFiles.SaveText(Path.Combine(recovered, "transcription.complete"), "complete");
        RecordingFiles.SaveText(Path.Combine(recovered, "unrelated.txt"), "Keep this file too.");
        int removed = RecordingFiles.DeleteAudio(recovered);
        check(removed == 2 && !RecordingFiles.HasAudio(recovered) && RecordingFiles.HasTranscript(recovered) &&
            File.Exists(Path.Combine(recovered, "unrelated.txt")) && File.Exists(original), "Audio cleanup preserves transcripts, other files and original recordings outside the current folder");
        string longFolder = Path.Combine(folder, "two-hour");
        Directory.CreateDirectory(longFolder);
        string system = Path.Combine(longFolder, "system.wav"), mic = Path.Combine(longFolder, "microphone.wav"), mix = Path.Combine(longFolder, "meeting.wav");
        using (var writer = new TimelineWriter(system)) { writer.Append(tone, tone.Length, AudioSession.Rate * 7199L); }
        using (var writer = new TimelineWriter(mic)) { writer.PadTo(AudioSession.Rate * 7200L); }
        RecordingFiles.Mix([system, mic], mix);
        using (var reader = new WaveFileReader(mix))
        {
            check(reader.TotalTime == TimeSpan.FromHours(2), "Two-hour recording tracks combine to the exact expected duration");
            reader.Position = reader.Length - tone.Length;
            byte[] lastSecond = new byte[tone.Length]; reader.ReadExactly(lastSecond);
            check(Math.Abs(BitConverter.ToInt16(lastSecond, 0) - 4096) <= 1, "Speech at the end of a two-hour recording remains present and aligned");
        }
        // Only remove the three generated long-duration fixtures, never meeting recordings.
        foreach (string path in new[] { system, mic, mix }) File.Delete(path);
    }
}


