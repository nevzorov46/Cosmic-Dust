// Shared between Swift and Metal — the single source of truth for GPU data layout.
// Swift imports it via the bridging header; Particles.metal includes it directly.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef unsigned int shader_uint;

typedef enum {
    BufferIndexParticles = 0,
    BufferIndexUniforms = 1,
    BufferIndexDrawParams = 2
} BufferIndex;

typedef struct {
    simd_float2 position;  // world space: x in [-aspect, aspect], y in [-1, 1]
    simd_float2 velocity;
    float size;            // per-particle size multiplier
    float seed;            // random 0..1, fixed at spawn
    float depth;           // 0 = far background, 1 = foreground; scales motion and size
    float brightness;      // per-particle emission, set by layer at spawn
} Particle;

typedef struct {
    simd_float2 wellPosition;  // world space
    float wellStrength;        // 0 when no touch is active
    float deltaTime;
    float time;
    float aspect;              // drawable width / height
    float particleSizePx;      // base sprite size in drawable pixels
    float pixelsPerUnit;       // drawable pixels per world unit (height / 2)
    float emission;            // global brightness scale, lowered at high counts
    shader_uint particleCount;
} Uniforms;

#endif /* ShaderTypes_h */
