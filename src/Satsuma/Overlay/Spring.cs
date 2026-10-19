namespace Satsuma.Overlay;

/// <summary>
/// Damped harmonic spring (unit mass). <c>response</c> is the undamped period in seconds and
/// <c>damping</c> the damping ratio (1 = critically damped, &lt;1 overshoots). Retargeting mid-flight keeps velocity,
/// which is what makes interrupted animations feel continuous.
/// </summary>
public sealed class Spring
{
    public float Value;
    public float Velocity;
    public float Target;
    float _stiffness, _dampingCoeff;
    float _pendingTarget, _delay;
    bool _hasPending;

    public Spring(float value, float response = 0.3f, float damping = 0.85f)
    {
        Value = Target = value;
        Configure(response, damping);
    }

    public Spring Configure(float response, float damping)
    {
        float w = 2f * MathF.PI / MathF.Max(0.01f, response);
        _stiffness = w * w;
        _dampingCoeff = 2f * damping * w;
        return this;
    }

    public void To(float target, float delay = 0f)
    {
        if (delay > 0f) { _pendingTarget = target; _delay = delay; _hasPending = true; }
        else { Target = target; _hasPending = false; }
    }

    public void Snap(float value)
    {
        Value = Target = value;
        Velocity = 0;
        _hasPending = false;
    }

    public bool IsMoving => _hasPending || MathF.Abs(Value - Target) > 0.0004f || MathF.Abs(Velocity) > 0.004f;

    /// <summary>Advances the spring; returns true while still in motion.</summary>
    public bool Step(float dt)
    {
        if (_hasPending)
        {
            _delay -= dt;
            if (_delay <= 0) { Target = _pendingTarget; _hasPending = false; dt = -_delay; }
            else return true;
        }
        if (!IsMoving)
        {
            Value = Target;
            Velocity = 0;
            return false;
        }
        int steps = Math.Max(1, (int)MathF.Ceiling(dt / (1f / 960f)));
        float h = dt / steps;
        for (int i = 0; i < steps; i++)
        {
            float accel = -_stiffness * (Value - Target) - _dampingCoeff * Velocity;
            Velocity += accel * h;
            Value += Velocity * h;
        }
        return true;
    }
}

public static class Ease
{
    public static float Clamp01(float v) => v < 0 ? 0 : v > 1 ? 1 : v;
    public static float Lerp(float a, float b, float t) => a + (b - a) * t;
    public static float Smooth(float t) { t = Clamp01(t); return t * t * (3 - 2 * t); }
    public static float OutCubic(float t) { t = Clamp01(t); float u = 1 - t; return 1 - u * u * u; }
}
