#include <metal_stdlib>
using namespace metal;

// Original Aperture geometry. Continuous metal ribbons share a single surface
// across every voice state. No stochastic particles, blur passes, or textures.
constant float aperturePi = 3.14159265359;
struct ApertureUniforms { float4 shape; float4 motion; float4 presentation; };
struct ApertureVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 surface;
    float edge;
    float dark;
};

float3 apertureRotate(float3 p, float x, float y) {
    p = float3(p.x, p.y * cos(x) - p.z * sin(x), p.y * sin(x) + p.z * cos(x));
    return float3(p.x * cos(y) + p.z * sin(y), p.y, -p.x * sin(y) + p.z * cos(y));
}

// Un-rotated surface point. The pose rotation is applied once per vertex by the
// caller: it is linear, so rotating the point and the local tangents gives the
// same normals as rotating every finite-difference sample separately, at a
// third of the trigonometry cost.
float3 apertureSurface(float theta, float phi, constant ApertureUniforms &u) {
    float time = u.motion.x;
    float audio = u.motion.y;
    float fold = u.shape.z * sin(theta * 2.0 + time);
    float section = phi + fold;
    float wave = audio * 0.045 * sin(theta * 3.0 - time * 4.0 + phi);
    float radius = u.shape.x + (u.shape.y + wave) * cos(section);
    float3 p = float3(radius * cos(theta), radius * sin(theta), u.shape.y * sin(section));
    p.y *= 1.04;
    p.z += 0.075 * u.shape.z * sin(theta * 2.0 + time);
    return p;
}

vertex ApertureVertexOut apertureOrbVertex(uint id [[vertex_id]], constant ApertureUniforms &u [[buffer(0)]]) {
    uint segments = uint(u.presentation.z);
    uint cell = id / 6u;
    uint ring = cell / segments;
    uint segment = cell % segments;
    uint corner = id % 6u;
    float along = (corner == 1u || corner == 2u || corner == 4u) ? 1.0 : 0.0;
    float edge = (corner == 2u || corner == 4u || corner == 5u) ? 1.0 : -1.0;
    float theta = (float(segment) + along) / float(segments) * 2.0 * aperturePi;
    // Preserve surface coverage at both quality levels. Reduce tessellation,
    // not alternate samples of the same sparse point cloud.
    float phi = (float(ring) + 0.5 + edge * 0.31) / u.presentation.w * 2.0 * aperturePi;
    // Forward differences: three surface evaluations instead of five. The
    // shading error at this epsilon is well under one pixel of normal change.
    float3 local = apertureSurface(theta, phi, u);
    float3 tangent = apertureSurface(theta + 0.004, phi, u) - local;
    float3 across = apertureSurface(theta, phi + 0.004, u) - local;
    float rollX = u.shape.w + u.motion.w;
    float rollY = -0.24 + u.motion.z + 0.10 * sin(u.motion.x * 0.6);
    float3 p = apertureRotate(local, rollX, rollY);
    // A proper rotation commutes with the cross product, so the normal needs
    // one rotation rather than one per tangent.
    float3 normal = apertureRotate(normalize(cross(tangent, across)), rollX, rollY);
    float2 clip = p.xy * 1.30;
    float aspect = max(u.presentation.x, 0.001);
    if (aspect > 1.0) clip.x /= aspect; else clip.y *= aspect;
    ApertureVertexOut result;
    result.position = float4(clip, 0.5 - p.z * 0.55, 1.0);
    result.normal = normal;
    result.surface = p;
    result.edge = edge;
    result.dark = u.presentation.y;
    return result;
}

fragment float4 apertureOrbFragment(ApertureVertexOut in [[stage_in]]) {
    float3 normal = normalize(in.normal);
    // Two-sided lighting through abs() instead of flipping the normal: the flip
    // is discontinuous where normal.z crosses zero, which drew a bright seam
    // travelling across the ribbons as the sculpture rotated.
    float diffuse = abs(dot(normal, normalize(float3(-0.45, 0.75, 1.1))));
    float specular = pow(abs(dot(normal, normalize(float3(-0.28, 0.48, 1.0)))), 28.0);
    float grazing = pow(1.0 - abs(normal.z), 2.0);
    float depth = smoothstep(-0.35, 0.35, in.surface.z);
    float shade = 0.18 + 0.48 * diffuse + 0.24 * specular + 0.10 * grazing;
    shade *= mix(0.60, 1.0, depth);
    if (in.dark > 0.5) shade = 0.22 + shade * 0.88;
    // Feather a constant two pixels of screen space rather than a fixed slice of
    // the ribbon parameter. Alpha-to-coverage quantizes the ramp to the sample
    // count, so a parametric feather collapsed into sub-pixel bands that crawled
    // as the ribbons moved. Clamped so a minified ribbon feathers fully instead
    // of disappearing.
    float edgeRate = clamp(fwidth(in.edge), 1e-4, 0.5);
    float coverage = 1.0 - smoothstep(1.0 - 2.0 * edgeRate, 1.0, abs(in.edge));
    // CAMetalLayer composites premultiplied alpha and the MSAA resolve preserves
    // the premultiplication, so ribbon edges no longer bloom at full brightness.
    float3 tint = float3(shade * 0.97, shade * 0.985, shade);
    return float4(tint * coverage, coverage);
}
