#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// sage37's refraction, ported from the web shader in points. Under every glass
// pane it bends the bloom at the rim, magnifies the middle and splits colour at
// the edge. Runs only when a pane moves or the window resizes.

static float3 s37tx(SwiftUI::Layer layer, float2 p, float2 size) {
    p = clamp(p, float2(0.0), size - 1.0);
    return float3(layer.sample(p).rgb);
}

[[ stitchable ]] half4 sage37Refract(float2 p, SwiftUI::Layer layer,
                                     float2 size,
                                     device const float *rects, int rectFloats,
                                     device const float *radii, int radiiCount,
                                     float count) {
    const float3 BG = float3(16.0, 14.0, 11.0) / 255.0;
    float3 c = s37tx(layer, p, size);
    int n = min(int(count), min(rectFloats / 4, radiiCount));
    for (int i = 0; i < n; i++) {
        float4 r = float4(rects[i*4], rects[i*4+1], rects[i*4+2], rects[i*4+3]); // x, y, w, h
        float2 h = r.zw * 0.5;
        float2 l = p - (r.xy + h);
        float rad = radii[i];
        float2 q = abs(l) - h + rad;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
        if (d < 0.0) {
            float t = clamp(1.0 + d / 30.0, 0.0, 1.0);           // refract-bezel 30
            t = t * t * (3.0 - 2.0 * t); t *= t;
            float2 nrm = (q.x > 0.0 && q.y > 0.0) ? normalize(q) : (q.x > q.y ? float2(1, 0) : float2(0, 1));
            nrm *= sign(l + 1e-4);
            float k = min(1.0, min(r.z, r.w) / 260.0);              // shift scales down under 260
            float2 sp = p - nrm * t * 40.0 * k - l * 0.06;           // refract-shift 40, magnify 1.06
            float f = 1.5;                                           // five-tap frost
            float3 a = s37tx(layer, sp, size) * 0.36
                     + (s37tx(layer, sp + float2(f, 0), size) + s37tx(layer, sp - float2(f, 0), size)
                      + s37tx(layer, sp + float2(0, f), size) + s37tx(layer, sp - float2(0, f), size)) * 0.16;
            float ca = 1.0 + t * 5.0;                                // fringe up to 6 at the rim
            a.r = s37tx(layer, sp + nrm * ca, size).r * 0.6 + a.r * 0.4;
            a.b = s37tx(layer, sp - nrm * ca, size).b * 0.6 + a.b * 0.4;
            a = BG + (a - BG) * 1.7 + float3(0.01);                  // refract-lift 1.7
            c = a;
            break;
        }
    }
    return half4(half3(c), 1.0h);
}
