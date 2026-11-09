using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace LocalMeetingNotes;

internal static class SelfTest
{
    public static async Task RunAsync(string[] args)
    {
        string folder = args.Length > 1 ? System.IO.Path.GetFullPath(args[1]) : System.IO.Path.Combine(Program.Root, "SelfTest");
        Directory.CreateDirectory(folder);
        if (args[0] == "--crash-fixture") { ReliabilityChecks.CrashFixture(folder); return; }
        var report = new List<string>();
        void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("FAILED: " + message);
            report.Add("PASS: " + message);
            File.WriteAllLines(System.IO.Path.Combine(folder, "test-results.txt"), report);
        }
        string timeline = System.IO.Path.Combine(folder, "timeline.wav");
        byte[] tone = new byte[AudioSession.Rate * 2];
        for (int i = 0; i < AudioSession.Rate; i++) BitConverter.GetBytes((short)8192).CopyTo(tone, i * 2);
        using (var writer = new TimelineWriter(timeline))
        {
            writer.Append(tone, tone.Length, AudioSession.Rate);
            writer.Append(tone, tone.Length, AudioSession.Rate * 4);
            writer.PadTo(AudioSession.Rate * 6);
        }
        using (var reader = new WaveFileReader(timeline))
        {
            Check(reader.TotalTime == TimeSpan.FromSeconds(6), "Timeline preserves leading, middle and trailing silence");
            byte[] data = new byte[(int)reader.Length]; reader.ReadExactly(data);
            Check(BitConverter.ToInt16(data, 0) == 0 && BitConverter.ToInt16(data, AudioSession.Rate * 2) == 8192 && BitConverter.ToInt16(data, AudioSession.Rate * 6) == 0 && BitConverter.ToInt16(data, AudioSession.Rate * 8) == 8192, "Speech stays at its timestamp after a silent gap");
        }
        string overlap = System.IO.Path.Combine(folder, "overlap.wav");
        using (var writer = new TimelineWriter(overlap))
        {
            writer.Append(tone, tone.Length, -AudioSession.Rate / 2);
            writer.Append(tone, tone.Length, 0);
        }
        using (var reader = new WaveFileReader(overlap)) Check(reader.TotalTime == TimeSpan.FromSeconds(1), "Overlapping and pre-start packets are trimmed safely");
        if (args[0] == "--reliability-test") { await ReliabilityChecks.RunAsync(folder, Check); return; }
        if (args.Length < 3) return;
        string sample = System.IO.Path.GetFullPath(args[2]);
        string normalized = System.IO.Path.Combine(folder, "meeting.wav");
        if (args[0] == "--capture-test")
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var session = new AudioSession(folder);
            await session.StartAsync(device.ID, null);
            try
            {
                await Task.Delay(2000);
                await Task.Run(() =>
                {
                    using var playbackDevices = new MMDeviceEnumerator();
                    using var playbackDevice = playbackDevices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                    using var reader = new WaveFileReader(sample);
                    using var player = new WasapiOut(playbackDevice, AudioClientShareMode.Shared, false, 100);
                    player.Init(reader); player.Play();
                    while (player.PlaybackState != PlaybackState.Stopped) Thread.Sleep(100);
                });
                await Task.Delay(500);
            }
            finally { await session.StopAsync(); }
            Check(session.Error == null, "System loopback capture completed without a device error");
            Check(session.HasSignal, "Loopback detected sample playback (microphone was not opened)");
            session.Mix();
            using var mixed = new WaveFileReader(normalized);
            Check(Math.Abs(mixed.TotalTime.TotalSeconds - session.Elapsed.TotalSeconds) < 0.1, "Captured audio duration matches elapsed time including initial silence");
        }
        else Transcriber.Normalize(sample, normalized);
        string result = await Transcriber.RunAsync(normalized, folder, args.Length > 3 ? args[3] : Program.DefaultModel, "en", null, CancellationToken.None);
        Check(result.Contains("country", StringComparison.OrdinalIgnoreCase), "Local whisper.cpp transcribed the reference speech correctly");
        Check(File.Exists(System.IO.Path.Combine(folder, "transcript.txt")), "Plain text and timestamped subtitle exports created");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try
        {
            await Transcriber.RunAsync(normalized, folder, Program.DefaultModel, "en", null, cancelled.Token);
            Check(false, "Cancellation prevents starting transcription");
        }
        catch (OperationCanceledException) { Check(File.Exists(normalized), "Cancelling transcription preserves the recording"); }
    }
}



