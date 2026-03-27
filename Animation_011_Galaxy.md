Below is a Claude.md-style, implementation-ready spec for a rotating particle-based galaxy in Godot 4.5, designed for your multi-monitor space station aesthetic.

🌌 galaxy_particle_system.claude.md
1. Overview

This module renders a stylized rotating spiral galaxy using GPU particles.
It is optimized for:

Smooth, continuous animation (30–60 FPS on modest hardware)

4x1 vertical monitor layout (tall aspect ratio)

Vector-like, clean aesthetic (white-on-black or subtle color accents)

Low CPU usage (GPU-driven motion)

The galaxy consists of:

A core (bulge)

Multiple spiral arms

Optional dust / noise particles

Subtle depth illusion via motion + size variation

2. Scene Structure
GalaxyRoot (Node2D or Node3D)
├── Camera2D / Camera3D
├── GalaxyParticles (GPUParticles2D or GPUParticles3D)
├── GlowLayer (optional, for bloom effect)
├── Background (ColorRect or shader)
Recommended Mode

Use GPUParticles2D for:

Crisp vector look

Easier screen-space control

Use GPUParticles3D if:

You want parallax tilt or camera rotation

3. Particle System Configuration
Core Settings
Property	Value
Amount	5,000 – 20,000
Lifetime	8 – 20 seconds
One Shot	false
Preprocess	10–20 seconds (pre-warm)
Explosiveness	0.0
Randomness	0.2 – 0.5
4. Emission Shape
Shape: Disk
Emission Shape: Sphere / Circle
Radius: 200–600 px (scale to screen height)

Particles spawn in a flat circular distribution, then get shaped into spiral motion via shader logic.

5. Particle Shader (CRITICAL)

Use a custom particle shader to create spiral motion.

Shader Type
shader_type particles;
Core Concept

Each particle:

Has a radius from center

Gets an angular velocity based on radius

Rotates continuously → creates spiral arms

Example Shader
shader_type particles;

uniform float rotation_speed = 1.5;
uniform float spiral_strength = 2.0;
uniform float radial_spread = 400.0;
uniform float time_scale = 1.0;

void process() {
    float t = TIME * time_scale;

    // Initial radial position
    float r = length(TRANSFORM[3].xy);

    // Normalize radius
    float r_norm = r / radial_spread;

    // Angular velocity (faster near center)
    float angular_velocity = rotation_speed / (0.2 + r_norm);

    // Spiral offset
    float angle = angular_velocity * t + r * spiral_strength * 0.01;

    float x = cos(angle) * r;
    float y = sin(angle) * r;

    TRANSFORM[3].xy = vec2(x, y);
}
6. Creating Spiral Arms

To avoid a boring uniform disk, bias particle distribution.

Method 1: Angle Quantization

In shader:

float arms = 4.0;
float arm_offset = floor(rand_from_seed(INDEX) * arms) / arms * TAU;
angle += arm_offset;
Method 2: Density Mask

Increase probability of spawning along specific angular bands

Creates visible arms

7. Particle Appearance
Texture

Use a small soft dot:

White circle with soft falloff

32x32 or 64x64 PNG

Color Ramp
Region	Color Suggestion
Core	Bright white / blue
Mid arms	Pale blue / purple
Outer arms	Dim white / gray
Size
Parameter	Value
Min Size	0.5
Max Size	2.5
Scale Curve	Larger near center
8. Core Glow (Bulge)

Add a second particle system or sprite:

CoreGlow (Sprite2D)
- Radial gradient
- Additive blending
- Slow pulsation

Optional shader pulse:

float pulse = 1.0 + sin(TIME * 0.5) * 0.1;
9. Depth Illusion

Fake 3D depth without real 3D:

Smaller particles = further away

Slight vertical drift:

TRANSFORM[3].y += sin(TIME + r) * 2.0;
10. Performance Optimization

If things start melting:

Reduce particle count to ~5,000

Lower lifetime

Use fixed FPS = 30

Disable collision (obviously… it’s space)

11. Multi-Monitor (4x1 Vertical) Behavior

Design considerations:

Galaxy center should sit across monitor boundaries

Arms should span entire column

Implementation

Anchor galaxy center at:

viewport_height * 0.5

Scale radius so arms extend beyond top/bottom screens

12. Optional Enhancements
12.1 Slow Camera Drift
camera.position.y += sin(Time.get_ticks_msec() * 0.0001) * 10
12.2 Star Twinkle

In shader:

float flicker = sin(TIME * 10.0 + INDEX) * 0.2;
COLOR.rgb += flicker;
12.3 Warp Distortion (for sci-fi flavor)

Add subtle radial distortion:

float warp = sin(r * 0.05 - TIME) * 2.0;
TRANSFORM[3].xy += normalize(TRANSFORM[3].xy) * warp;
13. Visual Style Guidelines (c-base compatible)

Background: pure black (#000000)

Particles: white / cyan / violet

No gradients unless subtle

Avoid realism → favor clean sci-fi instrumentation look

14. Export Parameters

Expose these for runtime tweaking:

@export var rotation_speed: float = 1.5
@export var spiral_strength: float = 2.0
@export var particle_count: int = 10000
@export var galaxy_radius: float = 400.0
@export var arm_count: int = 4
15. Behavior Summary

Galaxy rotates continuously

Inner core spins faster than outer arms

Spiral structure remains stable (not chaotic)

Motion is smooth, hypnotic, and non-distracting

16. What This Should Feel Like

Not:

"Look, I made particles."

But:

"This is a quiet, ancient system slowly rotating while your space station pretends everything is under control."