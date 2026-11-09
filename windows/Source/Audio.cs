using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace LocalMeetingNotes;

// Use WASAPI packet timestamps so silence in loopback does not move later speech earlier.
internal sealed class TimelineWriter : IDisposable
{
    private readonly WaveFileWriter writer;
    private readonly FileStream file;
    private long checkpointClock = AudioSession.Clock;
    private readonly byte[] silence = new byte[32000];
    private long frames;
    public TimelineWriter(string path)
    {
        file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        writer = new WaveFileWriter(new NAudio.Utils.IgnoreDisposeStream(file), new WaveFormat(AudioSession.Rate, 16, 1));
        Checkpoint();
    }
    public void CheckpointIfDue()
    {
        if (AudioSession.Clock - checkpointClock >= TimeSpan.FromSeconds(5).Ticks) Checkpoint();
    }
    public void Checkpoint()
    {
        writer.Flush(); // Update the WAV header before requesting a durable disk flush.
        file.Flush(true);
        checkpointClock = AudioSession.Clock;
    }
    public void Append(byte[] data, int count, long startFrame)
    {
        long skipped = Math.Min(count / 2, Math.Max(0, frames - startFrame));
        PadTo(Math.Max(0, startFrame));
        int offset = checked((int)skipped * 2);
        writer.Write(data, offset, count - offset);
        frames += (count - offset) / 2;
        CheckpointIfDue();
    }
    public void PadTo(long endFrame)
    {
        while (frames < endFrame)
        {
            int bytes = (int)Math.Min(silence.Length, (endFrame - frames) * 2);
            writer.Write(silence, 0, bytes);
            frames += bytes / 2;
        }
    }
    public void Dispose()
    {
        try { writer.Flush(); file.Flush(true); }
        finally { try { writer.Dispose(); } finally { file.Dispose(); } }
    }
}

internal sealed class AudioSession
{
    public const int Rate = 16000;
    public static long Clock => (long)(Stopwatch.GetTimestamp() * (10000000.0 / Stopwatch.Frequency));
    private readonly CancellationTokenSource stop = new();
    private readonly List<Track> tracks = new();
    private long endClock;
    public long StartClock { get; } = Clock;
    public TimeSpan Elapsed => TimeSpan.FromTicks((Volatile.Read(ref endClock) is long end && end > 0 ? end : Clock) - StartClock);
    public string Folder { get; }
    public float SystemPeak => tracks.FirstOrDefault(t => !t.Microphone)?.Peak ?? 0;
    public float MicPeak => tracks.FirstOrDefault(t => t.Microphone)?.Peak ?? 0;
    public Exception? Error => tracks.Select(t => t.Error).FirstOrDefault(e => e != null);
    public bool HasSignal => tracks.Any(t => t.HasSignal);
    public long Frames => (long)Math.Round(Elapsed.TotalSeconds * Rate);
    public long RequiredFreeBytes
    {
        get
        {
            long bytesPerTrack = Frames * 2;
            long unwrittenSilence = tracks.Sum(track => Math.Max(0, bytesPerTrack + 128 - new FileInfo(track.Path).Length));
            return bytesPerTrack + unwrittenSilence + 256L * 1024 * 1024;
        }
    }
    public AudioSession(string folder) => Folder = folder;

    public async Task StartAsync(string outputId, string? microphoneId)
    {
        RecordingFiles.SaveText(Path.Combine(Folder, "recording.inprogress"), DateTimeOffset.Now.ToString("O"));
        tracks.Add(new Track(this, outputId, false));
        if (microphoneId != null) tracks.Add(new Track(this, microphoneId, true));
        foreach (var track in tracks) track.Task = Task.Run(() => track.Run(stop.Token));
        try { await Task.WhenAll(tracks.Select(t => t.Ready.Task)); }
        catch { await StopAsync(); throw; }
    }

    public async Task StopAsync()
    {
        if (Interlocked.CompareExchange(ref endClock, Clock, 0) != 0) return;
        stop.Cancel();
        await Task.WhenAll(tracks.Select(t => t.Task));
        stop.Dispose();
        if (Error == null) File.Move(Path.Combine(Folder, "recording.inprogress"), Path.Combine(Folder, "recording.saved"), true);
    }

    public string Mix()
    {
        string destination = Path.Combine(Folder, "meeting.wav");
        RecordingFiles.Mix(tracks.Select(t => t.Path).ToArray(), destination);
        return destination;
    }

    private sealed class Track(AudioSession session, string deviceId, bool microphone)
    {
        public readonly bool Microphone = microphone;
        public readonly string Path = System.IO.Path.Combine(session.Folder, microphone ? "microphone.wav" : "system.wav");
        public readonly TaskCompletionSource Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task Task = Task.CompletedTask;
        public volatile float Peak;
        public volatile bool HasSignal;
        public volatile Exception? Error;

        public void Run(CancellationToken cancellation)
        {
            TimelineWriter? writer = null;
            try
            {
                writer = new TimelineWriter(Path);
                using var enumerator = new MMDeviceEnumerator();
                using var device = enumerator.GetDevice(deviceId);
                using var client = device.AudioClient;
                var flags = AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality;
                if (!Microphone) flags |= AudioClientStreamFlags.Loopback;
                client.Initialize(AudioClientShareMode.Shared, flags, 1000000, 0, new WaveFormat(Rate, 16, 1), Guid.Empty);
                using var capture = client.AudioCaptureClient;
                client.Start();
                Ready.TrySetResult();
                long lastPacket = Clock;
                try
                {
                    while (!cancellation.IsCancellationRequested)
                    {
                        while (capture.GetNextPacketSize() > 0 && !cancellation.IsCancellationRequested)
                        {
                            IntPtr pointer = capture.GetBuffer(out int frames, out var bufferFlags, out _, out long timestamp);
                            try
                            {
                                byte[] bytes = new byte[checked(frames * 2)];
                                if ((bufferFlags & AudioClientBufferFlags.Silent) == 0) Marshal.Copy(pointer, bytes, 0, bytes.Length);
                                if ((bufferFlags & AudioClientBufferFlags.TimestampError) != 0 || timestamp <= 0)
                                    timestamp = Clock - frames * 10000000L / Rate;
                                long startFrame = (long)Math.Round((timestamp - session.StartClock) * (Rate / 10000000.0));
                                // Discard invalid clock values rather than filling a corrupt multi-hour gap.
                                if (startFrame > (Clock - session.StartClock) * Rate / 10000000L + Rate)
                                    throw new InvalidOperationException("The audio device returned an invalid timestamp. Recording has been saved.");
                                writer.Append(bytes, bytes.Length, startFrame);
                                float peak = 0;
                                for (int i = 0; i < bytes.Length; i += 2) peak = Math.Max(peak, Math.Abs((int)BitConverter.ToInt16(bytes, i)) / 32768f);
                                Peak = peak;
                                if (peak > 0.002f) HasSignal = true;
                                lastPacket = Clock;
                            }
                            finally { capture.ReleaseBuffer(frames); }
                        }
                        if (Clock - lastPacket > 2000000) Peak = 0;
                        writer.CheckpointIfDue();
                        Thread.Sleep(15);
                    }
                }
                finally { client.Stop(); }
            }
            catch (Exception ex) { Error = ex; Ready.TrySetException(ex); }
            finally
            {
                try { if (writer != null) writer.PadTo(session.Frames); }
                catch (Exception ex) { Error ??= ex; }
                try { writer?.Dispose(); }
                catch (Exception ex) { Error ??= ex; }
                Ready.TrySetResult();
            }
        }
    }
}



