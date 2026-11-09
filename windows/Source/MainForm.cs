using System.Diagnostics;
using NAudio.CoreAudioApi;

namespace LocalMeetingNotes;

internal sealed class MainForm : Form
{
    private readonly ComboBox output = Selector("System audio device");
    private readonly ComboBox microphone = Selector("Microphone device");
    private readonly ComboBox language = Selector("Meeting language");
    private readonly TextBox model = new() { Dock = DockStyle.Fill, ReadOnly = true, Text = Program.DefaultModel, AccessibleName = "Local speech model" };
    private readonly Button browse = ActionButton("Choose model...");
    private readonly Button refresh = ActionButton("Refresh devices");
    private readonly Button record = ActionButton("Start recording");
    private readonly Button stop = ActionButton("Stop and transcribe");
    private readonly Button import = ActionButton("Transcribe a WAV...");
    private readonly Button open = ActionButton("Open meeting folder");
    private readonly Button cancel = ActionButton("Cancel transcription");
    private readonly Button recover = ActionButton("Recover recording...");
    private readonly Button deleteAudio = ActionButton("Delete audio...");
    private long nextDiskCheck;
    private readonly ProgressBar systemMeter = new() { Dock = DockStyle.Fill, Maximum = 100, AccessibleName = "System audio level" };
    private readonly ProgressBar micMeter = new() { Dock = DockStyle.Fill, Maximum = 100, AccessibleName = "Microphone level" };
    private readonly Label status = new() { Text = "Ready. Choose the output device used by your meeting.", AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(0, 9, 0, 9), AccessibleName = "Status" };
    private readonly RichTextBox transcript = new() { Dock = DockStyle.Fill, ReadOnly = true, BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle, Font = new Font("Segoe UI", 11), AccessibleName = "Timestamped transcript", DetectUrls = false };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 150 };
    private AudioSession? session;
    private CancellationTokenSource? transcriptionCancellation;
    private bool busy;
    private bool recording;
    private string? currentFolder;
    private string selectedLanguage = "de";

    public MainForm()
    {
        Text = "Local Meeting Notes";
        ClientSize = new Size(1040, 800);
        MinimumSize = new Size(960, 760);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10);
        BackColor = Color.FromArgb(246, 248, 248);
        Padding = new Padding(24);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 10 };
        for (int row = 0; row < 10; row++) layout.RowStyles.Add(new RowStyle(row == 9 ? SizeType.Percent : SizeType.AutoSize, row == 9 ? 100 : 0));
        Controls.Add(layout);
        layout.Controls.Add(new Label { Text = "Local Meeting Notes", Font = new Font("Segoe UI", 23, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 6) });
        layout.Controls.Add(new Label { Text = "Record your meeting. Transcribe on your computer after Stop. No uploads or account.", AutoSize = true, Margin = new Padding(0, 0, 0, 18) });
        var settings = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3 };
        settings.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170));
        settings.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        settings.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        AddSetting(settings, "System audio", output, refresh);
        AddSetting(settings, "Microphone", microphone, null);
        AddSetting(settings, "Meeting language", language, null);
        AddSetting(settings, "Speech model", model, browse);
        layout.Controls.Add(settings);
        var meters = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 4, Margin = new Padding(0, 12, 0, 12) };
        meters.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 100));
        meters.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        meters.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        meters.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        meters.Controls.Add(new Label { Text = "System level", AutoSize = true }); meters.Controls.Add(systemMeter);
        meters.Controls.Add(new Label { Text = "Mic level", AutoSize = true, Padding = new Padding(12, 0, 0, 0) }); meters.Controls.Add(micMeter);
        layout.Controls.Add(meters);
        layout.Controls.Add(new Label { Text = "Use headphones to avoid recording other participants twice through your microphone.", AutoSize = true, ForeColor = Color.FromArgb(65, 80, 80), Margin = new Padding(0, 0, 0, 14) });
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Margin = Padding.Empty, WrapContents = true };
        foreach (var button in new[] { record, stop, import, cancel, open, recover, deleteAudio }) buttons.Controls.Add(button);
        record.BackColor = Color.FromArgb(15, 105, 91); record.ForeColor = Color.White; record.FlatStyle = FlatStyle.Flat;
        layout.Controls.Add(buttons);
        layout.Controls.Add(status);
        layout.Controls.Add(new Label { Text = "Files stay in the Meetings folder. After reviewing a completed transcript, you can choose Delete audio.", AutoSize = true, ForeColor = Color.FromArgb(65, 80, 80), Margin = new Padding(0, 0, 0, 12) });
        layout.Controls.Add(new Label { Text = "TRANSCRIPT", AutoSize = true, Font = new Font("Segoe UI", 9, FontStyle.Bold), Margin = new Padding(0, 0, 0, 7) });
        layout.Controls.Add(transcript);
        language.Items.AddRange(new object[] { new Choice("de", "German"), new Choice("en", "English") });
        language.SelectedIndex = 0;
        refresh.Click += (_, _) => LoadDevices();
        browse.Click += (_, _) =>
        {
            using var dialog = new OpenFileDialog { Filter = "Whisper GGML models (*.bin)|*.bin", Title = "Choose a downloaded multilingual Whisper model" };
            if (dialog.ShowDialog(this) == DialogResult.OK) model.Text = dialog.FileName;
        };
        record.Click += async (_, _) => await StartAsync();
        stop.Click += async (_, _) => await FinishAsync(true);
        import.Click += async (_, _) => await ImportAsync();
        recover.Click += async (_, _) => await RecoverAsync();
        deleteAudio.Click += (_, _) => DeleteAudio();
        cancel.Click += (_, _) => { cancel.Enabled = false; status.Text = "Cancelling transcription. Audio will be kept."; transcriptionCancellation?.Cancel(); };
        open.Click += (_, _) =>
        {
            try { Directory.CreateDirectory(Program.Meetings); Process.Start(new ProcessStartInfo(currentFolder ?? Program.Meetings) { UseShellExecute = true }); }
            catch (Exception ex) { ShowError(ex); }
        };
        timer.Tick += async (_, _) =>
        {
            if (session == null || !recording) return;
            systemMeter.Value = Math.Clamp((int)(session.SystemPeak * 100), 0, 100);
            micMeter.Value = Math.Clamp((int)(session.MicPeak * 100), 0, 100);
            status.Text = "Recording locally  " + session.Elapsed.ToString(@"hh\:mm\:ss") + "  |  Press Stop to save and transcribe.";
            if (session.Error != null) await FinishAsync(false);
            else if (session.Elapsed.TotalHours >= 8) await FinishAsync(true);
            else if (AudioSession.Clock >= nextDiskCheck)
            {
                nextDiskCheck = AudioSession.Clock + TimeSpan.FromSeconds(5).Ticks;
                try
                {
                    long reserve = session.RequiredFreeBytes;
                    if (RecordingFiles.FreeBytes(session.Folder) < reserve)
                    {
                        await FinishAsync(true);
                        MessageBox.Show(this, "Recording was stopped because disk space is low. The saved audio and any completed transcript are kept.", Text);
                    }
                }
                catch (Exception ex) { await FinishAsync(false); ShowError(ex); }
            }
        };
        FormClosing += (_, e) =>
        {
            if (!busy && !recording) return;
            e.Cancel = true;
            MessageBox.Show(this, recording ? "Press Stop to save this recording before closing." : "Wait for the current operation, or cancel transcription before closing.", Text);
        };
        Shown += (_, _) =>
        {
            LoadDevices(); timer.Start();
            try
            {
                if (Directory.Exists(Program.Meetings) && Directory.EnumerateDirectories(Program.Meetings).Any(folder =>
                    (File.Exists(Path.Combine(folder, "recording.inprogress")) || !File.Exists(Path.Combine(folder, "transcript.srt"))) &&
                    File.Exists(Path.Combine(folder, "system.wav"))))
                    status.Text = "A saved recording has no completed transcript. Use Recover recording to continue.";
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        };
        FormClosed += (_, _) => timer.Dispose();
        SetControls();
    }

    private static ComboBox Selector(string name) => new() { Dock = DockStyle.Fill, DropDownStyle = ComboBoxStyle.DropDownList, AccessibleName = name, Margin = new Padding(3, 6, 3, 6) };
    private static Button ActionButton(string text) => new() { Text = text, AutoSize = true, MinimumSize = new Size(0, 36), Margin = new Padding(0, 0, 9, 6), Padding = new Padding(8, 0, 8, 0) };
    private static void AddSetting(TableLayoutPanel panel, string title, Control input, Control? action)
    {
        int row = panel.RowCount++;
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        panel.Controls.Add(new Label { Text = title, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
        panel.Controls.Add(input, 1, row);
        if (action != null) { action.AutoSize = false; action.Dock = DockStyle.Fill; panel.Controls.Add(action, 2, row); }
    }
    private sealed record Choice(string Id, string Name) { public override string ToString() => Name; }
    private void LoadDevices()
    {
        try
        {
            string? oldOutput = (output.SelectedItem as Choice)?.Id;
            string? oldMic = (microphone.SelectedItem as Choice)?.Id;
            using var devices = new MMDeviceEnumerator();
            output.Items.Clear(); microphone.Items.Clear();
            microphone.Items.Add(new Choice("", "Off — system audio only"));
            string defaultOutput = DefaultId(devices, DataFlow.Render);
            string defaultMic = DefaultId(devices, DataFlow.Capture);
            FillDevices(devices, output, DataFlow.Render, oldOutput ?? defaultOutput);
            FillDevices(devices, microphone, DataFlow.Capture, oldMic ?? defaultMic);
            if (microphone.SelectedIndex < 0) microphone.SelectedIndex = 0;
            status.Text = output.Items.Count == 0 ? "No audio output found. Connect your headset or speakers, then refresh." : "Ready. Match System audio to the output used by your meeting.";
        }
        catch (Exception ex) { ShowError(ex); }
        SetControls();
    }
    private static string DefaultId(MMDeviceEnumerator devices, DataFlow flow)
    {
        try { using var device = devices.GetDefaultAudioEndpoint(flow, Role.Multimedia); return device.ID; }
        catch { return ""; }
    }
    private static void FillDevices(MMDeviceEnumerator devices, ComboBox combo, DataFlow flow, string selected)
    {
        foreach (var device in devices.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            using (device)
            {
                int index = combo.Items.Add(new Choice(device.ID, device.FriendlyName));
                if (device.ID == selected) combo.SelectedIndex = index;
            }
        }
        if (combo.SelectedIndex < 0 && combo.Items.Count > 0) combo.SelectedIndex = 0;
    }
    private bool CheckModel()
    {
        if (File.Exists(model.Text) && File.Exists(Program.Engine)) return true;
        MessageBox.Show(this, "The local engine or speech model is missing. Run Setup.ps1, or choose an existing model.", Text);
        return false;
    }
    private async Task StartAsync()
    {
        if (busy || recording || output.SelectedItem is not Choice device || !CheckModel()) return;
        busy = true; SetControls();
        try
        {
            currentFolder = Program.NewMeeting();
            selectedLanguage = ((Choice)language.SelectedItem!).Id;
            string? micId = (microphone.SelectedItem as Choice)?.Id;
            File.WriteAllText(Path.Combine(currentFolder, "meeting-info.txt"), $"Started locally: {DateTimeOffset.Now:O}\nSystem audio: {device.Name}\nMicrophone: {microphone.Text}\nLanguage: {selectedLanguage}\nModel: {Path.GetFileName(model.Text)}\n");
            if (RecordingFiles.FreeBytes(currentFolder) < 1024L * 1024 * 1024)
                throw new IOException("Keep at least 1 GB free before starting, to leave room for a long meeting and its combined audio.");
            RecordingFiles.KeepAwake(true);
            nextDiskCheck = AudioSession.Clock + TimeSpan.FromSeconds(5).Ticks;
            session = new AudioSession(currentFolder);
            await session.StartAsync(device.Id, string.IsNullOrEmpty(micId) ? null : micId);
            transcript.Clear(); recording = true;
        }
        catch (Exception ex) { session = null; RecordingFiles.KeepAwake(false); ShowError(ex); }
        finally { busy = false; SetControls(); }
    }
    private async Task FinishAsync(bool transcribe)
    {
        if (!recording || busy || session == null) return;
        recording = false; busy = true; SetControls();
        var finished = session;
        status.Text = "Saving recording...";
        try
        {
            await finished.StopAsync();
            session = null; systemMeter.Value = micMeter.Value = 0;
            if (finished.Error != null) throw new InvalidOperationException("Recording was interrupted. Available audio tracks are saved; use Recover recording to combine and transcribe them. " + finished.Error.Message);
            string wav = await Task.Run(finished.Mix);
            if (!finished.HasSignal) { status.Text = "Saved, but no audible signal was detected. Check your devices before recording again."; return; }
            if (transcribe) await TranscribeAsync(wav);
            else status.Text = "Recording saved.";
        }
        catch (Exception ex) { ShowError(ex); }
        finally { session = null; RecordingFiles.KeepAwake(false); busy = false; SetControls(); }
    }
    private async Task ImportAsync()
    {
        if (busy || recording || !CheckModel()) return;
        using var dialog = new OpenFileDialog { Filter = "WAV recordings (*.wav)|*.wav", Title = "Transcribe an existing local recording" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        busy = true; SetControls();
        try
        {
            currentFolder = Program.NewMeeting();
            selectedLanguage = ((Choice)language.SelectedItem!).Id;
            string wav = Path.Combine(currentFolder, "meeting.wav");
            status.Text = "Preparing audio locally...";
            await Task.Run(() => Transcriber.Normalize(dialog.FileName, wav));
            await TranscribeAsync(wav);
        }
        catch (Exception ex) { ShowError(ex); }
        finally { busy = false; SetControls(); }
    }
    private async Task TranscribeAsync(string wav)
    {
        RecordingFiles.KeepAwake(true);
        transcriptionCancellation = new CancellationTokenSource();
        cancel.Enabled = true;
        status.Text = "Transcribing locally. A long meeting may take several minutes or longer...";
        transcript.Clear();
        try
        {
            transcript.Text = await Transcriber.RunAsync(wav, currentFolder!, model.Text, selectedLanguage,
                new Progress<string>(message => status.Text = message), transcriptionCancellation.Token);
            status.Text = "Transcript saved. Review it, then choose Delete audio if you no longer need the recordings.";
        }
        catch (OperationCanceledException) { status.Text = "Transcription cancelled. Audio is saved; use Transcribe a WAV to retry."; }
        finally { transcriptionCancellation.Dispose(); transcriptionCancellation = null; cancel.Enabled = false; RecordingFiles.KeepAwake(false); }
    }
    private async Task RecoverAsync()
    {
        if (busy || recording || !CheckModel()) return;
        using var dialog = new FolderBrowserDialog
        {
            Description = "Select the saved meeting folder containing system.wav and, if enabled, microphone.wav.",
            UseDescriptionForTitle = true, SelectedPath = Program.Meetings, ShowNewFolderButton = false
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        string source = dialog.SelectedPath;
        busy = true; SetControls();
        try
        {
            long sourceBytes = new[] { "system.wav", "microphone.wav" }.Select(name => Path.Combine(source, name)).Where(File.Exists).Sum(path => new FileInfo(path).Length);
            if (sourceBytes == 0) throw new InvalidOperationException("No saved recording tracks were found in that folder.");
            if (RecordingFiles.FreeBytes(Program.Root) < sourceBytes * 2 + 256L * 1024 * 1024)
                throw new IOException("Recovery needs room for copies of the saved tracks and combined audio. Free some disk space first.");
            currentFolder = Program.NewMeeting();
            selectedLanguage = ((Choice)language.SelectedItem!).Id;
            status.Text = "Recovering saved audio into a new folder. Originals are kept...";
            await Task.Run(() => RecordingFiles.Recover(source, currentFolder));
            await TranscribeAsync(Path.Combine(currentFolder, "meeting.wav"));
        }
        catch (Exception ex) { ShowError(ex); }
        finally { busy = false; SetControls(); }
    }
    private void DeleteAudio()
    {
        if (busy || recording || currentFolder == null || !RecordingFiles.HasTranscript(currentFolder)) return;
        if (MessageBox.Show(this,
            "Permanently delete the audio files in this meeting folder?\n\n" + currentFolder +
            "\n\nThe text transcript, subtitles and logs will stay. Imported originals or recordings in other folders will stay.\n\nThis cannot be undone.",
            "Delete audio and keep transcript?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        try
        {
            int deleted = RecordingFiles.DeleteAudio(currentFolder);
            status.Text = $"Deleted {deleted} audio file(s). The transcript and subtitles are kept.";
        }
        catch (Exception ex) { ShowError(ex); }
        finally { SetControls(); }
    }
    private void SetControls()
    {
        bool idle = !busy && !recording;
        foreach (var control in new Control[] { output, microphone, language, model, browse, refresh }) control.Enabled = idle;
        record.Enabled = idle && output.SelectedItem != null;
        import.Enabled = idle;
        recover.Enabled = idle;
        deleteAudio.Enabled = idle && currentFolder != null && RecordingFiles.HasTranscript(currentFolder) && RecordingFiles.HasAudio(currentFolder);
        stop.Enabled = recording && !busy;
        cancel.Enabled = transcriptionCancellation != null;
        open.Enabled = true;
    }
    private void ShowError(Exception ex)
    {
        status.Text = "Could not finish: " + ex.Message;
        MessageBox.Show(this, ex.Message + (currentFolder != null ? "\n\nMeeting folder:\n" + currentFolder : ""), Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}



