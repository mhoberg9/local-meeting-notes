using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace LocalMeetingNotes;

internal static class Program
{
#if PORTABLE_PACKAGE
    public static string Root => Path.Combine(AppContext.BaseDirectory, "LocalMeetingNotes-data");
#else
    public static string Root => AppContext.BaseDirectory;
#endif
    public static string Executable => string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase)
        ? Path.Combine(AppContext.BaseDirectory, "LocalMeetingNotes.exe") : Environment.ProcessPath!;
    public static string Engine => Path.Combine(Root, "engine", "whisper-cli.exe");
    public static string DefaultModel => Path.Combine(Root, "models", "ggml-small-q5_1.bin");
    public static string Meetings => Path.Combine(Root, "Meetings");

    [STAThread]
    static void Main(string[] args)
    {
#if PORTABLE_PACKAGE
        try { PortablePayload.EnsureOfflineFiles(); }
        catch (Exception ex)
        {
            if (args.Length == 0) MessageBox.Show("Could not prepare the portable app. Copy the executable to a writable local folder with enough free space.\n\n" + ex.Message, "Local Meeting Notes");
            else Console.Error.WriteLine(ex);
            Environment.ExitCode = 1;
            return;
        }
#endif
        if (args.Length > 0)
        {
            try { SelfTest.RunAsync(args).GetAwaiter().GetResult(); }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(Root, "self-test-error.txt"), ex.ToString());
                Environment.ExitCode = 1;
            }
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "Local Meeting Notes");
        Application.Run(new MainForm());
    }

    public static string NewMeeting()
    {
        string folder = Path.Combine(Meetings, DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss") + "_" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(folder);
        return folder;
    }
}

internal static class Transcriber
{
    public static async Task<string> RunAsync(string wav, string folder, string model, string language,
        IProgress<string>? progress, CancellationToken cancellation)
    {
        if (!File.Exists(Program.Engine)) throw new FileNotFoundException("The local whisper.cpp engine is missing. Run Setup.ps1.");
        if (!File.Exists(model)) throw new FileNotFoundException("Select a downloaded Whisper GGML model (.bin).");
        string prefix = Path.Combine(folder, "transcript-pending");
        var start = new ProcessStartInfo(Program.Engine)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Path.GetDirectoryName(Program.Engine)!
        };
        foreach (string arg in new[] { "-m", model, "-f", wav, "-l", language,
            "-otxt", "-osrt", "-of", prefix, "-pp", "-ng", "-t",
            Math.Clamp(Environment.ProcessorCount - 2, 1, 8).ToString() }) start.ArgumentList.Add(arg);
        using var log = new StreamWriter(Path.Combine(folder, "transcription.log"), false, Encoding.UTF8) { AutoFlush = true };
        object logLock = new();
        using var process = new Process { StartInfo = start };
        void OnLine(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == null) return;
            lock (logLock) log.WriteLine(e.Data);
            var match = Regex.Match(e.Data, @"progress\s*=\s*(\d+)%");
            if (match.Success) progress?.Report("Transcribing locally: " + match.Groups[1].Value + "%");
        }
        process.OutputDataReceived += OnLine;
        process.ErrorDataReceived += OnLine;
        cancellation.ThrowIfCancellationRequested();
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        using var registration = cancellation.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        });
        await process.WaitForExitAsync();
        process.WaitForExit(); // Drain redirected output before closing the log.
        cancellation.ThrowIfCancellationRequested();
        if (process.ExitCode != 0 || !File.Exists(prefix + ".srt") || !File.Exists(prefix + ".txt"))
            throw new InvalidOperationException("Transcription failed. Your audio is saved. See transcription.log in the meeting folder.");
        string result = await File.ReadAllTextAsync(prefix + ".srt", Encoding.UTF8, cancellation);
        if (string.IsNullOrWhiteSpace(result) || new FileInfo(prefix + ".txt").Length == 0)
            throw new InvalidOperationException("No speech was transcribed. Audio is kept so you can retry with another language or model.");
        foreach (string extension in new[] { ".txt", ".srt" })
        {
            RecordingFiles.FlushFile(prefix + extension);
            File.Move(prefix + extension, Path.Combine(folder, "transcript" + extension), true);
        }
        RecordingFiles.SaveText(Path.Combine(folder, "transcription.complete"), DateTimeOffset.Now.ToString("O"));
        return result;
    }

    public static void Normalize(string source, string destination)
    {
        using var reader = new WaveFileReader(source);
        ISampleProvider samples = reader.ToSampleProvider();
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        if (samples.WaveFormat.Channels != 1) throw new InvalidOperationException("Please use a mono or stereo WAV file.");
        if (samples.WaveFormat.SampleRate != AudioSession.Rate) samples = new WdlResamplingSampleProvider(samples, AudioSession.Rate);
        WaveFileWriter.CreateWaveFile16(destination, samples);
    }
}




