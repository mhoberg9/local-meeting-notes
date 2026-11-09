#if PORTABLE_PACKAGE
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;

namespace LocalMeetingNotes;

internal static class PortablePayload
{
    private const string ModelHash = "AE85E4A935D7A567BD102FE55AFC16BB595BDB618E11B2FC7591BC08120411BB";
    public static void EnsureOfflineFiles()
    {
        Directory.CreateDirectory(Program.Root);
        if ((File.GetAttributes(Program.Root) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Move the app to a normal writable local folder before running it.");
        using var preparationLock = new FileStream(Path.Combine(Program.Root, ".preparing"), FileMode.OpenOrCreate, FileAccess.Write, FileShare.None);
        using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("LocalMeetingNotes.OfflinePayload.zip")
            ?? throw new InvalidDataException("The bundled offline components are missing.");
        string fingerprint = Convert.ToHexString(SHA256.HashData(resource));
        resource.Position = 0;
        string versionFile = Path.Combine(Program.Root, ".offline-bundle-version");
        bool currentBundle = File.Exists(versionFile) && File.ReadAllText(versionFile) == fingerprint;
        using var archive = new ZipArchive(resource, ZipArchiveMode.Read);
        foreach (var entry in archive.Entries)
        {
            if (entry.FullName.EndsWith('/')) continue;
            if (!(entry.FullName.StartsWith("engine/", StringComparison.Ordinal) ||
                entry.FullName.StartsWith("models/", StringComparison.Ordinal) ||
                entry.FullName.StartsWith("Licenses/", StringComparison.Ordinal)))
                throw new InvalidDataException("Unexpected file in the portable package.");
            string path = Path.GetFullPath(Path.Combine(Program.Root, entry.FullName));
            if (!path.StartsWith(Program.Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("A portable component path is invalid.");
            string parent = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(parent);
            for (string? current = parent; current != null && current.Length >= Program.Root.Length; current = Path.GetDirectoryName(current))
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Cannot unpack offline components through a linked folder.");
            if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Cannot replace a linked component file.");
            bool ready = currentBundle && File.Exists(path) && new FileInfo(path).Length == entry.Length;
            if (ready && entry.FullName.StartsWith("models/", StringComparison.Ordinal))
            {
                using var model = File.OpenRead(path);
                ready = Convert.ToHexString(SHA256.HashData(model)) == ModelHash;
            }
            if (ready) continue;
            string temporary = path + ".unpacking";
            using (var input = entry.Open())
            using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                input.CopyTo(output); output.Flush(true);
            }
            if (new FileInfo(temporary).Length != entry.Length) throw new InvalidDataException("An offline component could not be unpacked completely.");
            File.Move(temporary, path, true);
        }
        using var verifiedModel = File.OpenRead(Program.DefaultModel);
        if (Convert.ToHexString(SHA256.HashData(verifiedModel)) != ModelHash)
            throw new InvalidDataException("The bundled speech model failed verification.");
        RecordingFiles.SaveText(versionFile, fingerprint);
    }
}
#endif

