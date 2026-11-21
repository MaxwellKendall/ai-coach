#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 shimmer(float2 position, half4 color, float4 bounds, float phase) {
    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0));
    // The entire band is clear of the view at both ends of the cycle.
    float center = mix(-0.18, 1.36, phase);
    half band = half(1.0 - smoothstep(0.0, 0.18, abs(uv.x + 0.18 * uv.y - center)));
    color.rgb = mix(color.rgb, half3(color.a), 0.48h * band);
    return color;
}

[[ stitchable ]] half4 sheen(float2 position, half4 color, float4 bounds, float angle) {
    float2 offset = position - bounds.xy - 0.5 * bounds.zw;
    float2 direction = float2(cos(angle), sin(angle));
    float distance = dot(offset, direction) / max(length(bounds.zw), 1.0);
    half highlight = half(1.0 - smoothstep(0.0, 0.26, abs(distance - 0.12 * sin(angle))));
    color.rgb = mix(color.rgb, half3(color.a), 0.38h * highlight * highlight);
    return color;
}
