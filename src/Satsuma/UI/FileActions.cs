using System.Collections.Specialized;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Satsuma.Core;
using Satsuma.Native;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using WinRT;
using Clipboard = System.Windows.Clipboard;

namespace Satsuma.UI;

/// <summary>The Actions wheel: share, float, copy, move, copy path, terminal, open with.</summary>
public static class FileActions
{
    public static Task SetClipboardTextAsync(string text) => Ui.Run(() =>
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try { Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), true); return; }
            catch (COMException) { Thread.Sleep(60); } // clipboard briefly locked by another app
        }
        throw new Ops.OpException("The clipboard is busy; try again.");
    });

    public static Task CopyFilesAsync(IReadOnlyList<string> files) => Ui.Run(() =>
    {
        var list = new StringCollection();
        list.AddRange(files.ToArray());
        var data = new DataObject();
        data.SetFileDropList(list);
        data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(DropEffects.Copy)));
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try { Clipboard.SetDataObject(data, true); return; }
            catch (COMException) { Thread.Sleep(60); }
        }
        throw new Ops.OpException("The clipboard is busy; try again.");
    });

    /// <summary>Asks for a folder and moves the items there. Returns the new paths, or null if canceled.</summary>
    public static Task<List<string>?> MoveAsync(IReadOnlyList<string> files) => Ui.RunAsync<List<string>?>(async () =>
    {
        var start = Path.GetDirectoryName(files[0].TrimEnd('\\'));
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = files.Count == 1 ? $"Move “{Path.GetFileName(files[0].TrimEnd('\\'))}” to…" : $"Move {files.Count} items to…", InitialDirectory = start };
        var owner = HelperWindow.Open();
        try
        {
            if (dialog.ShowDialog(owner) != true) return null;
        }
        finally { owner.Close(); }
        string dest = dialog.FolderName;
        return await Task.Run(() =>
        {
            var moved = new List<string>();
            foreach (var f in files)
            {
                var src = f.TrimEnd('\\');
                if (string.Equals(Path.GetDirectoryName(src), dest, StringComparison.OrdinalIgnoreCase)) { moved.Add(src); continue; }
                string target = Path.Combine(dest, Path.GetFileName(src));
                if (File.Exists(target) || Directory.Exists(target))
                    target = Ops.OutputPaths.Unique(dest, Path.GetFileNameWithoutExtension(src), Directory.Exists(src) ? "" : Path.GetExtension(src).TrimStart('.'));
                // VB's FileSystem shows Windows' own progress dialog for slow cross-drive moves.
                if (Directory.Exists(src)) Microsoft.VisualBasic.FileIO.FileSystem.MoveDirectory(src, target, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs);
                else Microsoft.VisualBasic.FileIO.FileSystem.MoveFile(src, target, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs);
                moved.Add(target);
            }
            return moved;
        });
    });

    public static void OpenTerminal(string path)
    {
        string dir = Directory.Exists(path) ? path : Path.GetDirectoryName(path.TrimEnd('\\'))!;
        var wt = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\wt.exe");
        try
        {
            if (File.Exists(wt)) Process.Start(new ProcessStartInfo(wt, $"-d \"{dir.TrimEnd('\\')}\\.\"") { UseShellExecute = true });
            else Process.Start(new ProcessStartInfo("powershell.exe", "-NoExit") { WorkingDirectory = dir, UseShellExecute = true });
        }
        catch (Exception ex) { throw new Ops.OpException("Couldn't open a terminal: " + ex.Message); }
    }

    public static Task OpenWithAsync(string file) => Ui.Run(() =>
    {
        var owner = HelperWindow.Open();
        try
        {
            var info = new Win32.OPENASINFO { pcszFile = file, oaifInFlags = 0x1 | 0x4 }; // ALLOW_REGISTRATION | EXEC
            Win32.SHOpenWithDialog(new WindowInteropHelper(owner).Handle, ref info);
        }
        finally { owner.Close(); }
    });

    public static Task FloatAsync(IReadOnlyList<string> files, Win32.POINT anchor) => Ui.Run(() => FloatShelf.Add(files, anchor));

    // ------------------------------------------------------------------ Windows share sheet

    static readonly Guid DataTransferManagerIid = new(0xa5caee9b, 0x8708, 0x49d1, 0x8d, 0x36, 0x67, 0xd2, 0x5a, 0x8d, 0xa0, 0x0c);

    public static Task ShareAsync(IReadOnlyList<string> files) => Ui.RunAsync(async () =>
    {
        var items = new List<IStorageItem>();
        foreach (var f in files)
        {
            var p = f.TrimEnd('\\');
            items.Add(Directory.Exists(p) ? await StorageFolder.GetFolderFromPathAsync(p) : await StorageFile.GetFileFromPathAsync(p));
        }
        var owner = HelperWindow.Open(visibleAnchor: true);
        var hwnd = new WindowInteropHelper(owner).Handle;
        var interop = DataTransferManager.As<IDataTransferManagerInterop>();
        var iid = DataTransferManagerIid;
        var dtm = MarshalInterface<DataTransferManager>.FromAbi(interop.GetForWindow(hwnd, ref iid));
        dtm.DataRequested += (s, e) =>
        {
            var data = e.Request.Data;
            data.Properties.Title = files.Count == 1 ? Path.GetFileName(files[0].TrimEnd('\\')) : $"{files.Count} items";
            data.Properties.Description = "Shared from Satsuma";
            data.SetStorageItems(items);
        };
        dtm.TargetApplicationChosen += (s, e) => owner.Dispatcher.BeginInvoke(owner.Close);
        interop.ShowShareUIForWindow(hwnd);
        // Close the anchor window eventually even if the sheet was dismissed without choosing a target.
        _ = Task.Delay(TimeSpan.FromMinutes(3)).ContinueWith(_ => owner.Dispatcher.BeginInvoke(owner.Close));
        return true;
    });

    /// <summary>A tiny, invisible top-level window used as the owner for system dialogs.</summary>
    sealed class HelperWindow : Window
    {
        public static HelperWindow Open(bool visibleAnchor = false)
        {
            Win32.GetCursorPos(out var pt);
            var w = new HelperWindow
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = System.Windows.Media.Brushes.Transparent,
                ShowInTaskbar = false, Topmost = true, Width = 1, Height = 1, ResizeMode = ResizeMode.NoResize,
            };
            var dip = Ui.ToDips(pt);
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = dip.X; w.Top = dip.Y;
            w.Show();
            Ui.ForceForeground(w);
            return w;
        }
    }
}
