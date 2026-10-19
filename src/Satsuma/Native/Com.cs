using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using IComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Satsuma.Native;

[ComImport, Guid("00000122-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDropTarget
{
    [PreserveSig] int DragEnter([In, MarshalAs(UnmanagedType.Interface)] IComDataObject pDataObj, [In] int grfKeyState, [In] Win32.POINT pt, [In, Out] ref int pdwEffect);
    [PreserveSig] int DragOver([In] int grfKeyState, [In] Win32.POINT pt, [In, Out] ref int pdwEffect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop([In, MarshalAs(UnmanagedType.Interface)] IComDataObject pDataObj, [In] int grfKeyState, [In] Win32.POINT pt, [In, Out] ref int pdwEffect);
}

[ComImport, Guid("4657278B-411B-11D2-839A-00C04FD918D0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDropTargetHelper
{
    void DragEnter([In] IntPtr hwndTarget, [In, MarshalAs(UnmanagedType.Interface)] IComDataObject pDataObject, [In] ref Win32.POINT ppt, [In] int dwEffect);
    void DragLeave();
    void DragOver([In] ref Win32.POINT ppt, [In] int dwEffect);
    void Drop([In, MarshalAs(UnmanagedType.Interface)] IComDataObject pDataObject, [In] ref Win32.POINT ppt, [In] int dwEffect);
    void Show([In] bool fShow);
}

[ComImport, Guid("4657278A-411B-11D2-839A-00C04FD918D0"), ClassInterface(ClassInterfaceType.None)]
public class DragDropHelper { }

[ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemArray
{
    [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppvOut);
}

[ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDataTransferManagerInterop
{
    IntPtr GetForWindow([In] IntPtr appWindow, [In] ref Guid riid);
    void ShowShareUIForWindow(IntPtr appWindow);
}

public static class DropEffects
{
    public const int None = 0, Copy = 1, Move = 2, Link = 4;
}

/// <summary>Helpers for reading/writing OLE data objects (file lists, drop descriptions, virtual files).</summary>
public static class OleData
{
    public const short CF_HDROP = 15;
    static readonly short CfDropDescription = unchecked((short)Win32.RegisterClipboardFormat("DropDescription"));
    static readonly short CfFileGroupDescriptorW = unchecked((short)Win32.RegisterClipboardFormat("FileGroupDescriptorW"));
    static readonly short CfFileContents = unchecked((short)Win32.RegisterClipboardFormat("FileContents"));

    // DROPIMAGETYPE
    public const int DropImageInvalid = -1, DropImageNone = 0, DropImageCopy = 1, DropImageMove = 2, DropImageLink = 4, DropImageLabel = 6, DropImageWarning = 7, DropImageNoImage = 8;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DROPDESCRIPTION
    {
        public int type;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szMessage;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szInsert;
    }

    static FORMATETC Fmt(short cf, TYMED tymed = TYMED.TYMED_HGLOBAL, int lindex = -1) =>
        new() { cfFormat = cf, dwAspect = DVASPECT.DVASPECT_CONTENT, lindex = lindex, ptd = IntPtr.Zero, tymed = tymed };

    public static bool HasFileDrop(IComDataObject data)
    {
        try { var f = Fmt(CF_HDROP); return data.QueryGetData(ref f) == 0; } catch { return false; }
    }

    public static List<string> GetFilePaths(IComDataObject data)
    {
        var result = new List<string>();
        try
        {
            var fmt = Fmt(CF_HDROP);
            if (data.QueryGetData(ref fmt) != 0) return result;
            data.GetData(ref fmt, out var med);
            try
            {
                uint n = Win32.DragQueryFile(med.unionmember, 0xFFFFFFFF, null, 0);
                for (uint i = 0; i < n; i++)
                {
                    uint len = Win32.DragQueryFile(med.unionmember, i, null, 0);
                    var sb = new StringBuilder((int)len + 1);
                    Win32.DragQueryFile(med.unionmember, i, sb, sb.Capacity);
                    result.Add(sb.ToString());
                }
            }
            finally { Win32.ReleaseStgMedium(ref med); }
        }
        catch (Exception ex) { Core.Log.Warn("GetFilePaths failed: " + ex.Message); }
        return result;
    }

    /// <summary>Names of "virtual" files (dragged from browsers, mail clients, archives) without materializing them.</summary>
    public static List<string> GetVirtualFileNames(IComDataObject data)
    {
        var names = new List<string>();
        try
        {
            var fmt = Fmt(CfFileGroupDescriptorW);
            if (data.QueryGetData(ref fmt) != 0) return names;
            data.GetData(ref fmt, out var med);
            try
            {
                IntPtr p = Win32.GlobalLock(med.unionmember);
                try
                {
                    int count = Marshal.ReadInt32(p);
                    const int descSize = 592, nameOffset = 72;
                    for (int i = 0; i < count; i++)
                    {
                        IntPtr d = p + 4 + i * descSize;
                        uint attrs = (uint)Marshal.ReadInt32(d + 36);
                        if ((attrs & 0x10) != 0) continue; // directory entries
                        string? name = Marshal.PtrToStringUni(d + nameOffset);
                        if (!string.IsNullOrEmpty(name)) names.Add(name);
                    }
                }
                finally { Win32.GlobalUnlock(med.unionmember); }
            }
            finally { Win32.ReleaseStgMedium(ref med); }
        }
        catch (Exception ex) { Core.Log.Warn("GetVirtualFileNames failed: " + ex.Message); }
        return names;
    }

    /// <summary>Writes virtual file contents to <paramref name="dir"/>. Must be called while the drag is still alive (inside Drop).</summary>
    public static List<string> MaterializeVirtualFiles(IComDataObject data, string dir)
    {
        var written = new List<string>();
        var fgd = Fmt(CfFileGroupDescriptorW);
        if (data.QueryGetData(ref fgd) != 0) return written;
        Directory.CreateDirectory(dir);
        var all = new List<(int index, string name)>();
        data.GetData(ref fgd, out var med);
        try
        {
            IntPtr p = Win32.GlobalLock(med.unionmember);
            int count = Marshal.ReadInt32(p);
            for (int i = 0; i < count; i++)
            {
                IntPtr d = p + 4 + i * 592;
                uint attrs = (uint)Marshal.ReadInt32(d + 36);
                if ((attrs & 0x10) != 0) continue;
                all.Add((i, Marshal.PtrToStringUni(d + 72) ?? $"file{i}"));
            }
            Win32.GlobalUnlock(med.unionmember);
        }
        finally { Win32.ReleaseStgMedium(ref med); }

        foreach (var (index, rawName) in all)
        {
            string name = string.Join("_", Path.GetFileName(rawName).Split(Path.GetInvalidFileNameChars()));
            string target = Path.Combine(dir, name);
            try
            {
                var fc = Fmt(CfFileContents, TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL, index);
                data.GetData(ref fc, out var cm);
                try
                {
                    using var fs = File.Create(target);
                    if (cm.tymed == TYMED.TYMED_ISTREAM)
                    {
                        var stream = (IStream)Marshal.GetObjectForIUnknown(cm.unionmember);
                        var buf = new byte[81920];
                        IntPtr readPtr = Marshal.AllocHGlobal(4);
                        try
                        {
                            while (true)
                            {
                                stream.Read(buf, buf.Length, readPtr);
                                int read = Marshal.ReadInt32(readPtr);
                                if (read <= 0) break;
                                fs.Write(buf, 0, read);
                            }
                        }
                        finally { Marshal.FreeHGlobal(readPtr); }
                    }
                    else if (cm.tymed == TYMED.TYMED_HGLOBAL)
                    {
                        int size = (int)Win32.GlobalSize(cm.unionmember);
                        IntPtr src = Win32.GlobalLock(cm.unionmember);
                        var bytes = new byte[size];
                        Marshal.Copy(src, bytes, 0, size);
                        Win32.GlobalUnlock(cm.unionmember);
                        fs.Write(bytes);
                    }
                }
                finally { Win32.ReleaseStgMedium(ref cm); }
                written.Add(target);
            }
            catch (Exception ex) { Core.Log.Warn($"Virtual file '{name}' failed: {ex.Message}"); }
        }
        return written;
    }

    /// <summary>Sets the text shown under the shell drag image ("Convert to PNG").</summary>
    public static void SetDropDescription(IComDataObject? data, int type, string message, string insert = "")
    {
        if (data == null) return;
        IntPtr h = IntPtr.Zero;
        try
        {
            var fmt = Fmt(CfDropDescription);
            var dd = new DROPDESCRIPTION { type = type, szMessage = message, szInsert = insert };
            int size = Marshal.SizeOf<DROPDESCRIPTION>();
            h = Win32.GlobalAlloc(Win32.GMEM_MOVEABLE | Win32.GMEM_ZEROINIT, (UIntPtr)size);
            IntPtr p = Win32.GlobalLock(h);
            Marshal.StructureToPtr(dd, p, false);
            Win32.GlobalUnlock(h);
            var med = new STGMEDIUM { tymed = TYMED.TYMED_HGLOBAL, unionmember = h, pUnkForRelease = null };
            data.SetData(ref fmt, ref med, true);
            h = IntPtr.Zero; // ownership transferred
        }
        catch { }
        finally { if (h != IntPtr.Zero) Win32.GlobalFree(h); }
    }
}

/// <summary>Starts an Explorer-style drag (with the native drag image) for files we own, e.g. from the Float shelf.</summary>
public static class ShellDrag
{
    [DllImport("shell32.dll")] static extern int SHCreateShellItemArrayFromIDLists(uint cidl, IntPtr[] rgpidl, out IShellItemArray ppsiItemArray);
    [DllImport("shell32.dll")] static extern int SHDoDragDrop(IntPtr hwnd, IComDataObject pdtobj, IntPtr pdsrc, int dwEffect, out int pdwEffect);

    static Guid BHID_DataObject = new("B8C0BD9F-ED24-455c-83E6-D5390C4FE8C4");
    static Guid IID_IDataObject = new("0000010e-0000-0000-C000-000000000046");

    public static IComDataObject? CreateDataObject(IReadOnlyList<string> paths)
    {
        var pidls = new List<IntPtr>();
        try
        {
            foreach (var p in paths)
            {
                var pidl = Win32.ILCreateFromPath(p);
                if (pidl != IntPtr.Zero) pidls.Add(pidl);
            }
            if (pidls.Count == 0) return null;
            if (SHCreateShellItemArrayFromIDLists((uint)pidls.Count, pidls.ToArray(), out var arr) != 0) return null;
            if (arr.BindToHandler(IntPtr.Zero, ref BHID_DataObject, ref IID_IDataObject, out var ptr) != 0 || ptr == IntPtr.Zero) return null;
            var obj = (IComDataObject)Marshal.GetObjectForIUnknown(ptr);
            Marshal.Release(ptr);
            return obj;
        }
        finally { foreach (var p in pidls) Win32.ILFree(p); }
    }

    /// <summary>Blocking modal drag loop; call from an STA UI thread while the mouse button is down.</summary>
    public static int DoDragDrop(IntPtr hwnd, IReadOnlyList<string> paths, int allowed = DropEffects.Copy | DropEffects.Move | DropEffects.Link)
    {
        var data = CreateDataObject(paths);
        if (data == null) return DropEffects.None;
        SHDoDragDrop(hwnd, data, IntPtr.Zero, allowed, out int effect);
        return effect;
    }
}
