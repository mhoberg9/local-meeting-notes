using System.Runtime.InteropServices;
using System.Text;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace LocalMeetingNotes;

internal static class RecordingFiles
{
    private static readonly string[] AudioNames = ["system.wav", "microphone.wav", "meeting.wav"];
    public static long FreeBytes(string folder) => new DriveInfo(Path.GetPathRoot(Path.GetFullPath(folder))!).AvailableFreeSpace;
    public static bool HasAudio(string folder) => AudioNames.Any(name => File.Exists(Path.Combine(folder, name)));
    public static bool HasTranscript(string folder) => File.Exists(Path.Combine(folder, "transcription.complete")) &&
        new[] { "transcript.txt", "transcript.srt" }.All(name => File.Exists(Path.Combine(folder, name)) && new FileInfo(Path.Combine(folder, name)).Length > 0);
    public static void FlushFile(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
        file.Flush(true);
    }
    public static void SaveText(string path, string text)
    {
        using var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        file.Write(Encoding.UTF8.GetBytes(text));
        file.Flush(true);
    }
    public static void Mix(string[] paths, string destination)
    {
        var readers = new List<WaveFileReader>();
        try
        {
            foreach (string path in paths) readers.Add(new WaveFileReader(path));
            if (readers.Count == 0) throw new InvalidOperationException("No recording tracks were found.");
            var sources = readers.Select(r => (ISampleProvider)new VolumeSampleProvider(r.ToSampleProvider()) { Volume = readers.Count > 1 ? 0.5f : 1f });
            WaveFileWriter.CreateWaveFile16(destination, new MixingSampleProvider(sources) { ReadFully = false });
            FlushFile(destination);
        }
        finally { foreach (var reader in readers) reader.Dispose(); }
    }
    public static void Recover(string sourceFolder, string destinationFolder)
    {
        Directory.CreateDirectory(destinationFolder);
        var copies = new List<string>();
        foreach (string name in new[] { "system.wav", "microphone.wav" })
        {
            string source = Path.Combine(sourceFolder, name);
            if (!File.Exists(source)) continue;
            string copy = Path.Combine(destinationFolder, name);
            // Never repair or overwrite the original. An active recording cannot be opened exclusively.
            using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.None))
            using (var output = new FileStream(copy, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output);
                output.Flush(true);
            }
            RepairCopy(copy);
            copies.Add(copy);
        }
        Mix(copies.ToArray(), Path.Combine(destinationFolder, "meeting.wav"));
        SaveText(Path.Combine(destinationFolder, "recovered-from.txt"), Path.GetFullPath(sourceFolder));
    }
    private static void RepairCopy(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        using var reader = new BinaryReader(file, Encoding.ASCII, true);
        string Tag() => Encoding.ASCII.GetString(reader.ReadBytes(4));
        if (Tag() != "RIFF") throw new InvalidDataException("The saved track is not a WAV recording.");
        reader.ReadUInt32();
        if (Tag() != "WAVE") throw new InvalidDataException("The saved track is not a WAV recording.");
        bool validFormat = false;
        while (file.Position + 8 <= file.Length)
        {
            string tag = Tag();
            long sizePosition = file.Position;
            uint length = reader.ReadUInt32();
            long start = file.Position;
            if (tag == "fmt " && length >= 16 && start + length <= file.Length)
            {
                ushort encoding = reader.ReadUInt16(), channels = reader.ReadUInt16();
                int rate = reader.ReadInt32();
                reader.ReadInt32();
                ushort alignment = reader.ReadUInt16(), bits = reader.ReadUInt16();
                validFormat = encoding == 1 && channels == 1 && rate == AudioSession.Rate && alignment == 2 && bits == 16;
            }
            if (tag == "data")
            {
                if (!validFormat) throw new InvalidDataException("Recovery expects this app's 16 kHz mono PCM recording tracks.");
                long bytes = (file.Length - start) / 2 * 2;
                file.SetLength(start + bytes);
                using var writer = new BinaryWriter(file, Encoding.ASCII, true);
                file.Position = sizePosition; writer.Write(checked((uint)bytes));
                file.Position = 4; writer.Write(checked((uint)(file.Length - 8)));
                writer.Flush(); file.Flush(true);
                return;
            }
            if (start + length + (length & 1) > file.Length) break;
            file.Position = start + length + (length & 1);
        }
        throw new InvalidDataException("No recoverable audio data was found.");
    }
    public static int DeleteAudio(string folder)
    {
        if (!HasTranscript(folder)) throw new InvalidOperationException("Audio can only be deleted after a complete transcript has been saved.");
        if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) throw new IOException("Cannot delete audio through a linked meeting folder.");
        string[] paths = AudioNames.Select(name => Path.Combine(Path.GetFullPath(folder), name)).Where(File.Exists).ToArray();
        foreach (string path in paths)
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Cannot delete linked audio files.");
        foreach (string path in paths) File.Delete(path);
        return paths.Length;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint flags);
    public static void KeepAwake(bool enabled)
    {
        if (SetThreadExecutionState(enabled ? 0x80000001u : 0x80000000u) == 0 && enabled)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Windows could not keep the computer awake for recording.");
    }
}
