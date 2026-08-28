#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Noise

// Integer hash on the lattice. No sin() tricks: those show visible banding
// at a million samples.
static float hash21(float2 p) {
    uint2 q = uint2(int2(floor(p)));
    q *= uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * (1.0 / 4294967296.0);
}

// Value noise: random values on a grid, smoothly interpolated between cells.
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Stream potential: three octaves of drifting value noise. Higher octaves are
// finer and weaker, which is what gives the fractal, filament look.
static float streamPotential(float2 p, float t) {
    float psi = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    for (int octave = 0; octave < 3; octave++) {
        float2 drift = float2(0.11, -0.07) * t * frequency;
        psi += amplitude * valueNoise(p * frequency + drift + float(octave) * 17.0);
        amplitude *= 0.5;
        frequency *= 2.1;
    }
    return psi;
}

// Curl of the potential (finite differences): a divergence-free flow, so dust
// swirls along filaments instead of piling into clumps.
static float2 curlNoise(float2 p, float t) {
    const float e = 0.08;
    float dPsiDy = streamPotential(p + float2(0, e), t) - streamPotential(p - float2(0, e), t);
    float dPsiDx = streamPotential(p + float2(e, 0), t) - streamPotential(p - float2(e, 0), t);
    return float2(dPsiDy, -dPsiDx) / (2.0 * e);
}

// MARK: - Simulation

kernel void updateParticles(device Particle *particles [[buffer(BufferIndexParticles)]],
                            constant Uniforms &u [[buffer(BufferIndexUniforms)]],
                            uint id [[thread_position_in_grid]]) {
    if (id >= u.particleCount) { return; }
    Particle p = particles[id];

    // Deeper (closer) layers feel the flow more — cheap parallax
    float2 force = curlNoise(p.position * 1.7, u.time) * (0.02 + 0.08 * p.depth);

    if (u.wellStrength > 0.0) {
        float2 d = u.wellPosition - p.position;
        float r2 = dot(d, d) + 0.015;  // Plummer softening: finite force at the core
        force += normalize(d) * (u.wellStrength * (0.4 + 0.6 * p.depth) / r2);
    }

    // Semi-implicit Euler with frame-rate-independent damping. The damping and
    // flow strength together set the steady-state drift speed — keep it below
    // the fragment shader's heat threshold so idle dust stays cool-colored.
    p.velocity += force * u.deltaTime;
    p.velocity *= exp(-1.1 * u.deltaTime);
    p.position += p.velocity * u.deltaTime;

    // Wrap around the visible bounds with a small margin
    float2 bounds = float2(u.aspect, 1.0) + 0.05;
    if (p.position.x > bounds.x) { p.position.x = -bounds.x; }
    if (p.position.x < -bounds.x) { p.position.x = bounds.x; }
    if (p.position.y > bounds.y) { p.position.y = -bounds.y; }
    if (p.position.y < -bounds.y) { p.position.y = bounds.y; }

    particles[id] = p;
}

// MARK: - Rendering

struct ParticleVertexOut {
    float4 position [[position]];
    float2 uv;
    half3 color;
    half sharpness;  // gaussian falloff steepness: clouds are soft, stars are crisp
};

static ParticleVertexOut makeParticleVertex(Particle p, uint vid, constant Uniforms &u) {
    // Triangle-strip quad corner from vertex id: (-1,-1) (1,-1) (-1,1) (1,1)
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);

    float sizePx = u.particleSizePx * p.size * (0.6 + 0.55 * p.depth);
    float2 sizeNDC = sizePx / float2(u.pixelsPerUnit * u.aspect, u.pixelsPerUnit);
    float2 centerNDC = float2(p.position.x / u.aspect, p.position.y);

    // Palette: cold blue outskirts, violet mid-tones, warm cores when accelerated
    half3 deepBlue = half3(0.10, 0.18, 0.45);
    half3 violet = half3(0.38, 0.22, 0.60);
    half3 warm = half3(1.0, 0.62, 0.35);
    half3 base = mix(deepBlue, violet, half(fract(p.seed * 5.7)));
    // A sparse minority of dusty-rose grains keeps the palette alive at rest
    half roseMix = half(saturate((fract(p.seed * 9.3) - 0.96) * 25.0));
    base = mix(base, half3(0.62, 0.32, 0.30), roseMix);
    float speed = length(p.velocity);
    // Only genuinely accelerated particles (a gravity well fly-by) go warm;
    // ambient drift stays below the threshold and keeps the cool palette
    half heat = half(saturate((speed - 0.5) * 1.2));
    half3 rgb = mix(base, warm, heat * heat) * half(p.brightness * 1.35 * u.emission);

    // Tiny particles read as stars: pull them toward white and keep them crisp
    half starMix = half(saturate((0.55 - p.size) * 4.0));
    rgb = mix(rgb, half3(0.92, 0.95, 1.0) * half(p.brightness * u.emission), starMix);

    ParticleVertexOut out;
    out.position = float4(centerNDC + corner * sizeNDC, 0.0, 1.0);
    out.uv = corner;
    out.color = rgb;
    out.sharpness = half(clamp(6.5 - p.size * 0.45, 2.0, 9.0)) + starMix * 3.0h;
    return out;
}

// Optimized path: one draw call, the shader pulls each particle by instance id.
vertex ParticleVertexOut particleVertexInstanced(uint vid [[vertex_id]],
                                                uint iid [[instance_id]],
                                                device const Particle *particles [[buffer(BufferIndexParticles)]],
                                                constant Uniforms &u [[buffer(BufferIndexUniforms)]]) {
    return makeParticleVertex(particles[iid], vid, u);
}

// Naive path: one draw call per particle, index arrives as a per-draw constant.
vertex ParticleVertexOut particleVertexSingle(uint vid [[vertex_id]],
                                             device const Particle *particles [[buffer(BufferIndexParticles)]],
                                             constant Uniforms &u [[buffer(BufferIndexUniforms)]],
                                             constant shader_uint &index [[buffer(BufferIndexDrawParams)]]) {
    return makeParticleVertex(particles[index], vid, u);
}

fragment half4 particleFragment(ParticleVertexOut in [[stage_in]]) {
    float d2 = dot(in.uv, in.uv);
    half falloff = half(exp(-float(in.sharpness) * d2));
    falloff *= half(saturate(1.0 - d2));  // fade to zero at the quad edge, no hard rim
    return half4(in.color * falloff, falloff);  // additive blending: rgb accumulates
}
