using Satsuma.Core;
using Satsuma.Overlay;
using SkiaSharp;

namespace Satsuma.Wheel;

public sealed class SegmentState
{
    public required WheelItem Item;
    public readonly Spring Appear = new(0, 0.44f, 0.76f);
    public readonly Spring Hover = new(0, 0.2f, 0.8f);
    public readonly Spring Press = new(0, 0.16f, 0.55f);
    public SKPath? Path;
    public float LabelSize;
}

public sealed class WheelState
{
    public WheelLayout Layout = new(1, true);
    public Backdrop.Snapshot? Backdrop;
    public bool Dark;
    public readonly Spring Open = new(0, 0.36f, 0.72f);
    public readonly Spring Fade = new(0, 0.14f, 1f);
    public readonly Spring HubPop = new(0, 0.34f, 0.6f);
    public readonly Spring Spin = new(0, 0.55f, 0.82f);
    public readonly List<SegmentState> Segments = new();
    public readonly List<SegmentState> Leaving = new();
    public int Hover = -1;
    public WheelKind Kind;
    public WheelContent? Content;
    public bool Loading = true;

    public (string Caption, string Title, bool Accent) HubFrom = ("", "", false), HubTo = ("", "", false);
    public readonly Spring HubFade = new(1, 0.2f, 1f);
    public readonly Spring ChipX = new(0, 0.32f, 0.78f);
    public readonly Spring Dim = new(0, 0.2f, 1f); // 1 while the drag has left the wheel

    public IEnumerable<Spring> AllSprings()
    {
        yield return Open; yield return Fade; yield return HubPop; yield return Spin;
        yield return HubFade; yield return ChipX; yield return Dim;
        foreach (var s in Segments) { yield return s.Appear; yield return s.Hover; yield return s.Press; }
        foreach (var s in Leaving) { yield return s.Appear; yield return s.Hover; yield return s.Press; }
    }
}

/// <summary>Draws the radial wheel. Stateless apart from cached fonts and paints.</summary>
public sealed class WheelRenderer
{
    public static readonly SKColor Accent = new(0xFF, 0x7A, 0x1A);
    public static readonly SKColor AccentLight = new(0xFF, 0xB0, 0x52);
    public static readonly SKColor AccentDeep = new(0xFF, 0x5A, 0x14);

    public static readonly Fonts Type = new();

    public sealed class Fonts
    {
        public readonly SKTypeface Regular, Semibold, Bold, Icons;
        public Fonts()
        {
            Regular = Load(SKFontStyleWeight.Normal);
            Semibold = Load(SKFontStyleWeight.SemiBold);
            Bold = Load(SKFontStyleWeight.Bold);
            Icons = SKTypeface.FromFamilyName("Segoe Fluent Icons") is { } fi && fi.FamilyName == "Segoe Fluent Icons"
                ? fi : SKTypeface.FromFamilyName("Segoe MDL2 Assets");
        }
        static SKTypeface Load(SKFontStyleWeight weight)
        {
            foreach (var family in new[] { "Segoe UI Variable Display", "Segoe UI Variable Text", "Segoe UI" })
            {
                var tf = SKTypeface.FromFamilyName(family, weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
                if (tf != null && tf.FamilyName.StartsWith("Segoe UI", StringComparison.OrdinalIgnoreCase)) return tf;
            }
            return SKTypeface.Default;
        }
    }

    readonly SKPaint _fill = new() { IsAntialias = true, Style = SKPaintStyle.Fill };
    readonly SKPaint _stroke = new() { IsAntialias = true, Style = SKPaintStyle.Stroke };
    readonly SKPaint _text = new() { IsAntialias = true };
    readonly SKSamplingOptions _linear = new(SKFilterMode.Linear, SKMipmapMode.None);

    public void Draw(SKCanvas c, WheelState st)
    {
        var L = st.Layout;
        float open = st.Open.Value;
        float fade = Ease.Clamp01(st.Fade.Value) * (1f - 0.35f * st.Dim.Value);
        if (fade <= 0.002f) return;
        float plateScale = 0.8f + 0.2f * open;
        bool dark = st.Dark;

        // Invisible "magnetic" halo: alpha-1 pixels keep the whole zone hit-testable for OLE drops.
        _fill.Shader = null;
        _fill.Color = new SKColor(0, 0, 0, 1);
        c.DrawCircle(L.Cx, L.Cy, L.HitRadius, _fill);

        int layer = c.SaveLayer(new SKPaint { Color = SKColors.White.WithAlpha((byte)(255 * fade)) });

        DrawShadow(c, L, plateScale, dark);
        DrawPlate(c, st, L.RPlate * plateScale, dark);

        c.Save();
        c.Translate(L.Cx, L.Cy);
        foreach (var seg in st.Leaving) DrawSegment(c, st, seg, st.Leaving, plateScale, dark);
        foreach (var seg in st.Segments) DrawSegment(c, st, seg, st.Segments, plateScale, dark);
        c.Restore();

        DrawHub(c, st, plateScale, dark);
        if (L.ShowHints) DrawHints(c, st, dark);

        c.RestoreToCount(layer);
    }

    void DrawShadow(SKCanvas c, WheelLayout L, float scale, bool dark)
    {
        float r = L.RPlate * scale;
        float outer = r + 34 * L.S;
        float k = dark ? 1.7f : 1f;
        var colors = new[]
        {
            new SKColor(0, 0, 0, (byte)(58 * k)), new SKColor(0, 0, 0, (byte)(44 * k)), new SKColor(0, 0, 0, (byte)(20 * k)),
            new SKColor(0, 0, 0, (byte)(6 * k)), SKColors.Transparent,
        };
        float[] pos = { (r - 24 * L.S) / outer, (r - 4 * L.S) / outer, (r + 8 * L.S) / outer, (r + 20 * L.S) / outer, 1f };
        _fill.Shader = SKShader.CreateRadialGradient(new SKPoint(L.Cx, L.Cy + 10 * L.S), outer, colors, pos, SKShaderTileMode.Clamp);
        c.DrawCircle(L.Cx, L.Cy + 10 * L.S, outer, _fill);
        _fill.Shader = null;
    }

    void DrawGlass(SKCanvas c, WheelState st, SKPath clip, bool dark, float tintBoost = 0)
    {
        var L = st.Layout;
        c.Save();
        c.ClipPath(clip, SKClipOperation.Intersect, true);
        if (st.Backdrop != null)
        {
            c.DrawImage(st.Backdrop.Image, new SKRect(0, 0, L.Width, L.Height), _linear, null);
        }
        byte a = (byte)Math.Clamp((dark ? 168 : 150) + tintBoost, 0, 255);
        _fill.Shader = null;
        _fill.Color = dark ? new SKColor(26, 25, 30, a) : new SKColor(251, 249, 246, a);
        c.DrawPaint(_fill);
        var b = clip.Bounds;
        _fill.Shader = SKShader.CreateLinearGradient(new SKPoint(0, b.Top), new SKPoint(0, b.Bottom),
            new[] { SKColors.White.WithAlpha((byte)(dark ? 18 : 70)), SKColors.White.WithAlpha(0) }, SKShaderTileMode.Clamp);
        c.DrawPaint(_fill);
        _fill.Shader = null;
        c.Restore();
    }

    void DrawPlate(SKCanvas c, WheelState st, float r, bool dark)
    {
        var L = st.Layout;
        using var plate = new SKPath();
        plate.AddCircle(L.Cx, L.Cy, r);
        DrawGlass(c, st, plate, dark);

        // Hairlines: a bright inner rim and a faint outer edge for definition on any wallpaper.
        _stroke.StrokeWidth = 1.2f * L.S;
        _stroke.Shader = SKShader.CreateLinearGradient(new SKPoint(0, L.Cy - r), new SKPoint(0, L.Cy + r),
            dark ? new[] { SKColors.White.WithAlpha(46), SKColors.White.WithAlpha(12) }
                 : new[] { SKColors.White.WithAlpha(235), SKColors.White.WithAlpha(110) }, SKShaderTileMode.Clamp);
        c.DrawCircle(L.Cx, L.Cy, r - 0.6f * L.S, _stroke);
        _stroke.Shader = null;
        _stroke.StrokeWidth = 1f * L.S;
        _stroke.Color = dark ? new SKColor(0, 0, 0, 90) : new SKColor(0, 0, 0, 20);
        c.DrawCircle(L.Cx, L.Cy, r + 0.5f * L.S, _stroke);
    }

    void DrawSegment(SKCanvas c, WheelState st, SegmentState seg, List<SegmentState> list, float plateScale, bool dark)
    {
        var L = st.Layout;
        int n = list.Count;
        int i = list.IndexOf(seg);
        if (n == 0 || i < 0) return;
        float appear = seg.Appear.Value;
        if (appear <= 0.003f) return;
        float hover = Ease.Clamp01(seg.Hover.Value);
        float press = seg.Press.Value;
        float span = 360f / n;
        float mid = WheelLayout.MidAngle(i, n);

        seg.Path ??= WheelGeometry.Segment(-span / 2f, span / 2f, L.RIn, L.R, L.Gap, L.FilletOuter, L.FilletInner);

        c.Save();
        float spin = st.Spin.Value + (1f - appear) * -16f;
        float scale = plateScale * (0.78f + 0.22f * Ease.Clamp01(appear)) * (1f + 0.035f * press);
        c.Scale(scale);
        c.RotateDegrees(mid + spin);
        float pop = (5f * hover + 3f * press) * L.S;
        c.Translate(pop, 0);

        float alpha = Ease.Clamp01(appear);
        // Soft accent glow behind the hovered segment.
        if (hover > 0.01f)
        {
            _fill.Shader = null;
            _fill.Color = Accent.WithAlpha((byte)(120 * hover * alpha));
            _fill.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 9f * L.S);
            c.DrawPath(seg.Path, _fill);
            _fill.MaskFilter = null;
        }

        // Idle frosted fill (gradient runs along the radius, lighter towards the rim).
        _fill.Shader = SKShader.CreateLinearGradient(new SKPoint(L.R, 0), new SKPoint(L.RIn, 0),
            dark ? new[] { SKColors.White.WithAlpha((byte)(34 * alpha)), SKColors.White.WithAlpha((byte)(16 * alpha)) }
                 : new[] { SKColors.White.WithAlpha((byte)(170 * alpha)), SKColors.White.WithAlpha((byte)(105 * alpha)) },
            SKShaderTileMode.Clamp);
        c.DrawPath(seg.Path, _fill);

        if (hover > 0.003f)
        {
            _fill.Shader = SKShader.CreateLinearGradient(new SKPoint(L.R, -L.R * 0.3f), new SKPoint(L.RIn, L.R * 0.3f),
                new[] { AccentLight.WithAlpha((byte)(255 * hover * alpha)), AccentDeep.WithAlpha((byte)(255 * hover * alpha)) },
                SKShaderTileMode.Clamp);
            c.DrawPath(seg.Path, _fill);
        }
        _fill.Shader = null;

        // Bevel highlight.
        _stroke.StrokeWidth = 1f * L.S;
        _stroke.Shader = SKShader.CreateLinearGradient(new SKPoint(L.R, 0), new SKPoint(L.RIn, 0),
            new[]
            {
                SKColors.White.WithAlpha((byte)((dark ? 50 : 240) * alpha * (1 - hover) + 150 * hover * alpha)),
                SKColors.White.WithAlpha((byte)((dark ? 10 : 90) * alpha)),
            }, SKShaderTileMode.Clamp);
        c.DrawPath(seg.Path, _stroke);
        _stroke.Shader = null;

        // Label (kept upright).
        float labelR = (L.R + L.RIn) / 2f + 2f * L.S;
        c.Translate(labelR, 0);
        c.RotateDegrees(-(mid + spin));
        DrawSegmentLabel(c, st, seg, n, hover, alpha, dark);
        c.Restore();
    }

    void DrawSegmentLabel(SKCanvas c, WheelState st, SegmentState seg, int n, float hover, float alpha, bool dark)
    {
        var L = st.Layout;
        var item = seg.Item;
        var baseColor = dark ? new SKColor(244, 240, 236) : new SKColor(43, 36, 31);
        var color = Lerp(baseColor, SKColors.White, hover).WithAlpha((byte)(255 * alpha * (dark ? 0.94f : 0.9f + 0.1f * hover)));
        float arc = 2f * MathF.PI * ((L.R + L.RIn) / 2f) / n - 2 * L.Gap;
        float maxW = MathF.Min(arc * 0.84f, (L.R - L.RIn) * 0.98f);
        string label = item.Label.ToUpperInvariant();

        if (item.Glyph != null)
        {
            using var iconFont = new SKFont(Type.Icons, 21f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
            using var labelFont = new SKFont(Type.Semibold, 10.5f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
            Shrink(labelFont, label, maxW, 8f * L.S);
            _text.Color = color;
            c.DrawText(item.Glyph, 0, -1.5f * L.S, SKTextAlign.Center, iconFont, _text);
            DrawSpaced(c, label, 0, 15f * L.S, labelFont, _text, 0.5f * L.S);
        }
        else
        {
            using var font = new SKFont(Type.Bold, (n > 8 ? 13.5f : 15f) * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
            Shrink(font, label, maxW, 9f * L.S);
            _text.Color = color;
            font.GetFontMetrics(out var m);
            float y = -(m.Ascent + m.Descent) / 2f;
            DrawSpaced(c, label, 0, y, font, _text, 0.6f * L.S);
        }
    }

    static void Shrink(SKFont font, string text, float maxWidth, float minSize)
    {
        while (font.Size > minSize && font.MeasureText(text) > maxWidth) font.Size -= 0.5f;
    }

    /// <summary>Draws centered text with extra letter spacing.</summary>
    public static void DrawSpaced(SKCanvas c, string text, float cx, float y, SKFont font, SKPaint paint, float spacing)
    {
        if (spacing <= 0.01f || text.Length < 2) { c.DrawText(text, cx, y, SKTextAlign.Center, font, paint); return; }
        float total = 0;
        Span<float> widths = text.Length <= 64 ? stackalloc float[text.Length] : new float[text.Length];
        for (int i = 0; i < text.Length; i++) { widths[i] = font.MeasureText(text[i].ToString()); total += widths[i]; }
        total += spacing * (text.Length - 1);
        float x = cx - total / 2f;
        for (int i = 0; i < text.Length; i++)
        {
            c.DrawText(text[i].ToString(), x, y, SKTextAlign.Left, font, paint);
            x += widths[i] + spacing;
        }
    }

    void DrawHub(SKCanvas c, WheelState st, float plateScale, bool dark)
    {
        var L = st.Layout;
        float pop = st.HubPop.Value;
        float r = L.RHub * plateScale * (0.72f + 0.28f * pop);
        if (r <= 1) return;

        // Hub drop shadow.
        _fill.Shader = null;
        _fill.Color = new SKColor(0, 0, 0, (byte)(dark ? 70 : 26));
        _fill.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 5f * L.S);
        c.DrawCircle(L.Cx, L.Cy + 2.5f * L.S, r, _fill);
        _fill.MaskFilter = null;

        using var hub = new SKPath();
        hub.AddCircle(L.Cx, L.Cy, r);
        DrawGlass(c, st, hub, dark, dark ? 40 : 75);
        _fill.Shader = SKShader.CreateLinearGradient(new SKPoint(0, L.Cy - r), new SKPoint(0, L.Cy + r),
            dark ? new[] { new SKColor(255, 255, 255, 20), new SKColor(255, 255, 255, 6) }
                 : new[] { new SKColor(255, 255, 255, 150), new SKColor(255, 255, 255, 90) }, SKShaderTileMode.Clamp);
        c.DrawCircle(L.Cx, L.Cy, r, _fill);
        _fill.Shader = null;
        _stroke.StrokeWidth = 1f * L.S;
        _stroke.Color = dark ? SKColors.White.WithAlpha(34) : SKColors.White.WithAlpha(240);
        c.DrawCircle(L.Cx, L.Cy, r - 0.5f * L.S, _stroke);

        // Cross-faded hub text.
        float f = Ease.Clamp01(st.HubFade.Value);
        float a = Ease.Clamp01(pop);
        DrawHubText(c, st, st.HubFrom, (1 - f) * a, -5f * L.S * f, r, dark);
        DrawHubText(c, st, st.HubTo, f * a, 5f * L.S * (1 - f), r, dark);
    }

    void DrawHubText(SKCanvas c, WheelState st, (string Caption, string Title, bool Accent) t, float alpha, float dy, float r, bool dark)
    {
        if (alpha <= 0.01f) return;
        var L = st.Layout;
        float maxW = r * 1.72f;
        using var capFont = new SKFont(Type.Semibold, 9f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        using var titleFont = new SKFont(Type.Bold, 17f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        string caption = t.Caption.ToUpperInvariant();
        Shrink(capFont, caption, maxW, 7f * L.S);
        Shrink(titleFont, t.Title, maxW, 10f * L.S);
        bool hasCaption = caption.Length > 0;
        float titleY = L.Cy + dy + (hasCaption ? 10f : 6f) * L.S;
        var secondary = dark ? new SKColor(176, 168, 160) : new SKColor(125, 116, 108);
        var primary = dark ? new SKColor(246, 242, 238) : new SKColor(38, 32, 28);
        if (hasCaption)
        {
            _text.Color = secondary.WithAlpha((byte)(255 * alpha));
            DrawSpaced(c, caption, L.Cx, L.Cy + dy - 9f * L.S, capFont, _text, 1.1f * L.S);
        }
        _text.Color = (t.Accent ? (dark ? AccentLight : AccentDeep) : primary).WithAlpha((byte)(255 * alpha));
        c.DrawText(t.Title, L.Cx, titleY, SKTextAlign.Center, titleFont, _text);
    }

    // ---- key hint chips under the wheel ----
    public static string KeyName(TriggerKey k) => k switch
    {
        TriggerKey.Shift => "⇧ Shift", TriggerKey.Ctrl => "Ctrl", TriggerKey.Alt => "Alt",
        TriggerKey.Space => "Space", TriggerKey.Tab => "Tab", TriggerKey.CapsLock => "Caps", _ => "",
    };

    void DrawHints(SKCanvas c, WheelState st, bool dark)
    {
        var L = st.Layout;
        var s = Settings.Current;
        var chips = new List<(WheelKind kind, string key, string label)>();
        if (s.ConvertKey != TriggerKey.None) chips.Add((WheelKind.Convert, KeyName(s.ConvertKey), "Convert"));
        if (s.ToolsKey != TriggerKey.None) chips.Add((WheelKind.Tools, KeyName(s.ToolsKey), "Tools"));
        if (s.ActionsKey != TriggerKey.None) chips.Add((WheelKind.Actions, KeyName(s.ActionsKey), "Actions"));
        if (chips.Count == 0) return;

        float open = Ease.Clamp01(st.Open.Value);
        using var keyFont = new SKFont(Type.Semibold, 9.5f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        using var labelFont = new SKFont(Type.Semibold, 11f * L.S) { Subpixel = true, Edging = SKFontEdging.Antialias };
        float padX = 10f * L.S, capPad = 5f * L.S, gapInChip = 6f * L.S, gapBetween = 4f * L.S, h = 26f * L.S;
        var widths = chips.Select(ch => capPad * 2 + MeasureKey(ch.key, keyFont) + gapInChip + labelFont.MeasureText(ch.label) + padX * 2).ToList();
        float total = widths.Sum() + gapBetween * (chips.Count - 1) + 6f * L.S;
        float top = L.Cy + L.RPlate + 14f * L.S + (1 - open) * -10f * L.S;
        float left = L.Cx - total / 2f;
        var pillRect = new SKRect(left, top, left + total, top + h + 6f * L.S);

        // Frosted pill.
        using (var pill = new SKPath())
        {
            pill.AddRoundRect(pillRect, pillRect.Height / 2, pillRect.Height / 2);
            _fill.Shader = null;
            _fill.Color = new SKColor(0, 0, 0, (byte)(dark ? 60 : 22));
            _fill.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 6f * L.S);
            c.DrawPath(pill, _fill);
            _fill.MaskFilter = null;
            DrawGlass(c, st, pill, dark, 30);
            _stroke.StrokeWidth = 1f * L.S;
            _stroke.Color = dark ? SKColors.White.WithAlpha(30) : SKColors.White.WithAlpha(220);
            c.DrawRoundRect(pillRect, pillRect.Height / 2, pillRect.Height / 2, _stroke);
        }

        // Sliding highlight behind the active chip.
        int active = chips.FindIndex(ch => ch.kind == st.Kind);
        float x = left + 3f * L.S;
        var lefts = new List<float>();
        foreach (var w in widths) { lefts.Add(x); x += w + gapBetween; }
        if (active >= 0)
        {
            float targetX = lefts[active] + widths[active] / 2f;
            if (st.ChipX.Target != targetX)
            {
                if (st.ChipX.Value == 0) st.ChipX.Snap(targetX); else st.ChipX.To(targetX);
            }
            float cx = st.ChipX.Value;
            float w = widths[active];
            var hl = new SKRect(cx - w / 2f, top + 3f * L.S, cx + w / 2f, top + 3f * L.S + h);
            _fill.Color = dark ? SKColors.White.WithAlpha(26) : SKColors.White.WithAlpha(230);
            c.DrawRoundRect(hl, h / 2, h / 2, _fill);
        }

        for (int i = 0; i < chips.Count; i++)
        {
            bool isActive = i == active;
            float cx0 = lefts[i] + padX;
            float midY = top + 3f * L.S + h / 2f;
            float keyW = MeasureKey(chips[i].key, keyFont) + capPad * 2;
            var cap = new SKRect(cx0, midY - 8.5f * L.S, cx0 + keyW, midY + 8.5f * L.S);
            if (isActive)
            {
                _fill.Shader = SKShader.CreateLinearGradient(new SKPoint(cap.Left, cap.Top), new SKPoint(cap.Right, cap.Bottom),
                    new[] { AccentLight, AccentDeep }, SKShaderTileMode.Clamp);
                c.DrawRoundRect(cap, 4.5f * L.S, 4.5f * L.S, _fill);
                _fill.Shader = null;
                _text.Color = SKColors.White;
            }
            else
            {
                _stroke.StrokeWidth = 1f * L.S;
                _stroke.Color = dark ? SKColors.White.WithAlpha(60) : new SKColor(0, 0, 0, 40);
                c.DrawRoundRect(cap, 4.5f * L.S, 4.5f * L.S, _stroke);
                _text.Color = dark ? new SKColor(200, 194, 188) : new SKColor(110, 102, 95);
            }
            keyFont.GetFontMetrics(out var km);
            DrawKey(c, chips[i].key, cap.MidX, midY - (km.Ascent + km.Descent) / 2f, keyFont);
            labelFont.GetFontMetrics(out var lm);
            _text.Color = isActive ? (dark ? new SKColor(250, 246, 242) : new SKColor(38, 32, 28))
                                   : (dark ? new SKColor(176, 168, 160) : new SKColor(120, 112, 105));
            c.DrawText(chips[i].label, cap.Right + gapInChip, midY - (lm.Ascent + lm.Descent) / 2f, SKTextAlign.Left, labelFont, _text);
        }
    }

    // Segoe UI Variable has no ⇧, so the symbol is drawn from whichever installed font has it.
    static readonly SKTypeface? SymbolFace = SKFontManager.Default.MatchCharacter('⇧');

    static float MeasureKey(string key, SKFont font)
    {
        if (!key.StartsWith("⇧ ") || SymbolFace == null) return font.MeasureText(key);
        using var sym = new SKFont(SymbolFace, font.Size * 1.1f);
        return sym.MeasureText("⇧") + font.Size * 0.3f + font.MeasureText(key[2..]);
    }

    void DrawKey(SKCanvas c, string key, float cx, float y, SKFont font)
    {
        if (!key.StartsWith("⇧ ") || SymbolFace == null)
        {
            c.DrawText(key, cx, y, SKTextAlign.Center, font, _text);
            return;
        }
        using var sym = new SKFont(SymbolFace, font.Size * 1.1f) { Subpixel = true, Edging = SKFontEdging.Antialias };
        float x = cx - MeasureKey(key, font) / 2f;
        c.DrawText("⇧", x, y, SKTextAlign.Left, sym, _text);
        c.DrawText(key[2..], x + sym.MeasureText("⇧") + font.Size * 0.3f, y, SKTextAlign.Left, font, _text);
    }

    public static SKColor Lerp(SKColor a, SKColor b, float t)
    {
        t = Ease.Clamp01(t);
        return new SKColor(
            (byte)(a.Red + (b.Red - a.Red) * t),
            (byte)(a.Green + (b.Green - a.Green) * t),
            (byte)(a.Blue + (b.Blue - a.Blue) * t),
            (byte)(a.Alpha + (b.Alpha - a.Alpha) * t));
    }
}
