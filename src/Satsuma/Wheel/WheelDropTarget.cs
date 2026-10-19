using System.Runtime.InteropServices;
using Satsuma.Core;
using Satsuma.Native;
using IComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace Satsuma.Wheel;

/// <summary>
/// OLE drop target registered on the wheel window. OLE calls it on the overlay thread (our STA) while a
/// drag from Explorer or any other app hovers the wheel. It also keeps the shell drag image visible over
/// the wheel and sets the "Convert to PNG" text under it.
/// </summary>
[ComVisible(true)]
public sealed class WheelDropTarget : IDropTarget
{
    readonly WheelController _wheel;
    readonly IntPtr _hwnd;
    IDropTargetHelper? _helper;
    IComDataObject? _data;
    string _lastDescription = "";

    public WheelDropTarget(WheelController wheel, IntPtr hwnd)
    {
        _wheel = wheel;
        _hwnd = hwnd;
        try { _helper = (IDropTargetHelper)new DragDropHelper(); }
        catch (Exception ex) { Log.Warn("DragDropHelper unavailable: " + ex.Message); }
    }

    public int DragEnter(IComDataObject pDataObj, int grfKeyState, Win32.POINT pt, ref int pdwEffect)
    {
        try
        {
            _data = pDataObj;
            _lastDescription = "";
            int allowed = pdwEffect;
            pdwEffect = _wheel.OnDragEnter(pDataObj, pt, allowed);
            UpdateDescription();
            try { _helper?.DragEnter(_hwnd, pDataObj, ref pt, pdwEffect); } catch { }
        }
        catch (Exception ex) { Log.Error("DragEnter", ex); pdwEffect = DropEffects.None; }
        return 0;
    }

    public int DragOver(int grfKeyState, Win32.POINT pt, ref int pdwEffect)
    {
        try
        {
            pdwEffect = _wheel.OnDragOver(pt, pdwEffect);
            UpdateDescription();
            try { _helper?.DragOver(ref pt, pdwEffect); } catch { }
        }
        catch (Exception ex) { Log.Error("DragOver", ex); pdwEffect = DropEffects.None; }
        return 0;
    }

    public int DragLeave()
    {
        try
        {
            OleData.SetDropDescription(_data, OleData.DropImageInvalid, "");
            try { _helper?.DragLeave(); } catch { }
            _wheel.OnDragLeave();
        }
        catch (Exception ex) { Log.Error("DragLeave", ex); }
        _data = null;
        return 0;
    }

    public int Drop(IComDataObject pDataObj, int grfKeyState, Win32.POINT pt, ref int pdwEffect)
    {
        try
        {
            int allowed = pdwEffect;
            OleData.SetDropDescription(pDataObj, OleData.DropImageInvalid, "");
            pdwEffect = _wheel.OnDrop(pDataObj, pt, allowed);
            try { _helper?.Drop(pDataObj, ref pt, pdwEffect); } catch { }
        }
        catch (Exception ex) { Log.Error("Drop", ex); pdwEffect = DropEffects.None; }
        _data = null;
        return 0;
    }

    void UpdateDescription()
    {
        var (type, message, insert) = _wheel.CurrentDropDescription();
        string key = $"{type}|{message}|{insert}";
        if (key == _lastDescription) return;
        _lastDescription = key;
        OleData.SetDropDescription(_data, type, message, insert);
    }
}
