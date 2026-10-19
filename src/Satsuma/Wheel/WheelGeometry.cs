using SkiaSharp;

namespace Satsuma.Wheel;

/// <summary>All wheel dimensions in physical pixels for a given scale (DPI × user scale).</summary>
public sealed class WheelLayout
{
    public readonly float S;
    public readonly float R, RIn, RPlate, RHub, Gap, FilletOuter, FilletInner, HitRadius;
    public readonly int Width, Height;
    public readonly float Cx, Cy;
    public readonly bool ShowHints;

    public WheelLayout(float scale, bool showHints)
    {
        S = scale;
        ShowHints = showHints;
        R = 150 * S;
        RIn = 64 * S;
        RPlate = R + 9 * S;
        RHub = RIn - 8 * S;
        Gap = 5 * S;
        FilletOuter = 12 * S;
        FilletInner = 7 * S;
        HitRadius = R + 46 * S;
        float half = HitRadius + 4 * S;
        Width = (int)MathF.Ceiling(half * 2);
        Cx = Width / 2f;
        Cy = half;
        float bottom = showHints ? Cy + RPlate + 52 * S : Cy + half;
        Height = (int)MathF.Ceiling(MathF.Max(bottom, Cy + half));
    }

    /// <summary>Center angle (degrees, clockwise from 3 o'clock) of segment i of n; segment 0 sits at the top.</summary>
    public static float MidAngle(int i, int n) => -90f + i * 360f / n;

    /// <summary>Index of the segment under a point (window px), -1 for the hub, -2 for outside the magnetic zone.</summary>
    public int HitTest(float x, float y, int n)
    {
        float dx = x - Cx, dy = y - Cy;
        float dist = MathF.Sqrt(dx * dx + dy * dy);
        if (dist < RIn - 2 * S) return -1;
        if (dist > HitRadius || n == 0) return -2;
        float ang = MathF.Atan2(dy, dx) * 180f / MathF.PI + 90f; // 0 at top, clockwise
        float span = 360f / n;
        ang = ((ang + span / 2f) % 360f + 360f) % 360f;
        return Math.Clamp((int)(ang / span), 0, n - 1);
    }
}

public static class WheelGeometry
{
    const float Deg = 180f / MathF.PI;

    /// <summary>
    /// A ring segment from angle a0 to a1 (degrees) between radii r and R, with parallel gaps of width g
    /// and properly tangent rounded corners (fillets) at all four corners.
    /// </summary>
    public static SKPath Segment(float a0, float a1, float r, float R, float g, float fo, float fi)
    {
        var path = new SKPath();
        float span = a1 - a0;
        if (span >= 359.9f)
        {
            path.AddCircle(0, 0, R, SKPathDirection.Clockwise);
            path.AddCircle(0, 0, r, SKPathDirection.CounterClockwise);
            return path;
        }

        float t0 = a0 / Deg, t1 = a1 / Deg;
        var u0 = new SKPoint(MathF.Cos(t0), MathF.Sin(t0));
        var n0 = new SKPoint(-MathF.Sin(t0), MathF.Cos(t0));   // into the segment from edge 0
        var u1 = new SKPoint(MathF.Cos(t1), MathF.Sin(t1));
        var n1 = new SKPoint(MathF.Sin(t1), -MathF.Cos(t1));   // into the segment from edge 1
        float h = g / 2f;

        // Shrink fillets if the segment is too narrow for them.
        float maxOuter = (R * MathF.Sin(MathF.Min(span, 170f) / 2f / Deg) - h) * 0.9f;
        fo = MathF.Max(0.5f, MathF.Min(fo, maxOuter));
        float maxInner = (r * MathF.Sin(MathF.Min(span, 170f) / 2f / Deg) - h) * 0.9f;
        fi = MathF.Max(0.5f, MathF.Min(fi, MathF.Max(0.5f, maxInner)));

        (SKPoint center, SKPoint onEdge, SKPoint onCircle) Outer(SKPoint u, SKPoint n)
        {
            float a = MathF.Sqrt(MathF.Max(0, (R - fo) * (R - fo) - (h + fo) * (h + fo)));
            var c = u.Mul(a) + n.Mul(h + fo);
            return (c, u.Mul(a) + n.Mul(h), c.Mul(R / (R - fo)));
        }
        (SKPoint center, SKPoint onEdge, SKPoint onCircle) Inner(SKPoint u, SKPoint n)
        {
            float b = MathF.Sqrt(MathF.Max(0, (r + fi) * (r + fi) - (h + fi) * (h + fi)));
            var c = u.Mul(b) + n.Mul(h + fi);
            return (c, u.Mul(b) + n.Mul(h), c.Mul(r / (r + fi)));
        }

        var o0 = Outer(u0, n0);
        var o1 = Outer(u1, n1);
        var i0 = Inner(u0, n0);
        var i1 = Inner(u1, n1);

        path.MoveTo(i0.onEdge);
        path.LineTo(o0.onEdge);
        Fillet(path, o0.center, fo, o0.onEdge, o0.onCircle);
        ArcAroundOrigin(path, R, o0.onCircle, o1.onCircle, clockwise: true);
        Fillet(path, o1.center, fo, o1.onCircle, o1.onEdge);
        path.LineTo(i1.onEdge);
        Fillet(path, i1.center, fi, i1.onEdge, i1.onCircle);
        ArcAroundOrigin(path, r, i1.onCircle, i0.onCircle, clockwise: false);
        Fillet(path, i0.center, fi, i0.onCircle, i0.onEdge);
        path.Close();
        return path;
    }

    static SKPoint Mul(this SKPoint p, float s) => new(p.X * s, p.Y * s);

    static float AngleOf(SKPoint p) => MathF.Atan2(p.Y, p.X) * Deg;

    static void Fillet(SKPath path, SKPoint c, float radius, SKPoint from, SKPoint to)
    {
        float s = AngleOf(from - c), e = AngleOf(to - c);
        float sweep = e - s;
        while (sweep > 180) sweep -= 360;
        while (sweep <= -180) sweep += 360;
        path.ArcTo(new SKRect(c.X - radius, c.Y - radius, c.X + radius, c.Y + radius), s, sweep, false);
    }

    static void ArcAroundOrigin(SKPath path, float radius, SKPoint from, SKPoint to, bool clockwise)
    {
        float s = AngleOf(from), e = AngleOf(to);
        float sweep = e - s;
        if (clockwise) { while (sweep <= 0) sweep += 360; while (sweep > 360) sweep -= 360; }
        else { while (sweep >= 0) sweep -= 360; while (sweep < -360) sweep += 360; }
        path.ArcTo(new SKRect(-radius, -radius, radius, radius), s, sweep, false);
    }
}
