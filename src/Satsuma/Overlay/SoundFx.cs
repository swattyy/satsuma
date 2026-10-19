using System.Runtime.InteropServices;
using Satsuma.Core;
using static Satsuma.Native.Win32;

namespace Satsuma.Overlay;

/// <summary>Tiny synthesized UI sounds (no audio assets). Played asynchronously from memory.</summary>
public static class SoundFx
{
    public sealed class Sound
    {
        readonly GCHandle _handle;
        public Sound(byte[] wav) { _handle = GCHandle.Alloc(wav, GCHandleType.Pinned); }
        public IntPtr Ptr => _handle.AddrOfPinnedObject();
    }

    public static readonly Sound Open = Make(0.07, 0.11, t => Tone(t, 520 + 300 * t / 0.07) * Env(t, 0.003, 0.05));
    public static readonly Sound Tick = Make(0.016, 0.06, t => Tone(t, 2600) * Env(t, 0.0008, 0.006));
    public static readonly Sound Switch = Make(0.05, 0.08, t => Tone(t, 680 + 260 * t / 0.05) * Env(t, 0.002, 0.03));
    public static readonly Sound Commit = Make(0.11, 0.11, t => (Tone(t, 880) * 0.6 + Tone(t, 1320) * 0.4) * Env(t, 0.002, 0.06));
    public static readonly Sound Done = Make(0.26, 0.11, t =>
        (t < 0.11 ? Tone(t, 784) * Env(t, 0.003, 0.07) : Tone(t, 1175) * Env(t - 0.11, 0.003, 0.1)));
    public static readonly Sound Error = Make(0.18, 0.1, t => (Tone(t, 220) + 0.4 * Tone(t, 330)) * Env(t, 0.004, 0.09));

    public static void Play(Sound sound)
    {
        if (!Settings.Current.Sounds) return;
        try { PlaySound(sound.Ptr, IntPtr.Zero, SND_MEMORY | SND_ASYNC | SND_NODEFAULT); } catch { }
    }

    static double Tone(double t, double hz) => Math.Sin(2 * Math.PI * hz * t);

    static double Env(double t, double attack, double decay)
    {
        if (t < 0) return 0;
        if (t < attack) return t / attack;
        return Math.Exp(-(t - attack) / decay);
    }

    static Sound Make(double seconds, double volume, Func<double, double> wave)
    {
        const int rate = 44100;
        int n = (int)(seconds * rate);
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8.ToArray()); w.Write(36 + n * 2); w.Write("WAVE"u8.ToArray());
        w.Write("fmt "u8.ToArray()); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8.ToArray()); w.Write(n * 2);
        for (int i = 0; i < n; i++)
        {
            double t = (double)i / rate;
            double fadeOut = Math.Min(1.0, (n - i) / (rate * 0.004)); // avoid clicks at the end
            double v = Math.Clamp(wave(t) * volume * fadeOut, -1, 1);
            w.Write((short)(v * short.MaxValue));
        }
        w.Flush();
        return new Sound(ms.ToArray());
    }
}
