Below is a **clean technical spec you can hand directly to Codex / Claude Code CLI** to build a **Cold-War command-center rotating vector globe in Godot 4.5**.

I’m structuring it like an **implementation doc**, so an AI coding assistant can execute it step-by-step.

---

# Cold War Vector Globe – Godot 4.5 Implementation Spec

## Goal

Create a **retro Cold War command-center globe** resembling:

* NORAD / WarGames style displays
* Green vector phosphor lines
* Slowly rotating Earth
* Latitude/longitude grid
* Optional radar sweep
* CRT glow and scanlines

The globe should be **lightweight and procedural** rather than relying on heavy textures.

---

# Architecture Overview

```
VectorGlobe (Node3D)
 ├── EarthSphere (MeshInstance3D)
 │     └── VectorGlobeMaterial (ShaderMaterial)
 ├── LatLonGrid (MeshInstance3D)
 ├── RadarSweep (MeshInstance3D)
 ├── Camera3D
 ├── DirectionalLight3D (optional)
 └── GlobeController.gd
```

Responsibilities:

| Node                | Role                       |
| ------------------- | -------------------------- |
| EarthSphere         | Base sphere mesh           |
| VectorGlobeMaterial | Draws vector lines         |
| LatLonGrid          | Latitude/longitude overlay |
| RadarSweep          | Rotating sweep effect      |
| GlobeController     | Controls rotation          |
| Camera              | Fixed camera view          |

---

# Step 1 — Create the Sphere

Use a **SphereMesh**.

Settings:

```
Radius: 1
Radial Segments: 128
Rings: 64
```

Higher subdivisions help vector lines appear smooth.

---

# Step 2 — Globe Rotation Script

Attach to **VectorGlobe node**.

```gdscript
extends Node3D

@export var rotation_speed := 0.1   # radians per second

func _process(delta):
    rotate_y(rotation_speed * delta)
```

Recommended speed:

```
1 full rotation = ~60 seconds
```

---

# Step 3 — Convert Lat/Lon to Sphere Coordinates

Used if you want to draw coastlines or markers.

```gdscript
func latlon_to_sphere(lat: float, lon: float, radius: float) -> Vector3:
    var lat_r = deg_to_rad(lat)
    var lon_r = deg_to_rad(lon)

    var x = radius * cos(lat_r) * cos(lon_r)
    var y = radius * sin(lat_r)
    var z = radius * cos(lat_r) * sin(lon_r)

    return Vector3(x, y, z)
```

This maps geographic coordinates onto the sphere.

---

# Step 4 — Vector Globe Shader

Create a **ShaderMaterial** on the sphere.

This shader generates:

* latitude lines
* longitude lines
* glowing green emission

```
shader_type spatial;

uniform float line_thickness = 0.02;
uniform float grid_density = 18.0;

void fragment() {

    vec2 uv = UV;

    float lat_lines = abs(fract(uv.y * grid_density) - 0.5);
    float lon_lines = abs(fract(uv.x * grid_density) - 0.5);

    float lat_mask = smoothstep(line_thickness, 0.0, lat_lines);
    float lon_mask = smoothstep(line_thickness, 0.0, lon_lines);

    float grid = max(lat_mask, lon_mask);

    vec3 glow = vec3(0.1, 1.0, 0.3);

    ALBEDO = vec3(0.0);
    EMISSION = glow * grid * 2.0;
}
```

Result:

```
black sphere
+ glowing vector grid
```

---

# Step 5 — Coastline Overlay (Optional)

You can overlay coastlines using a **transparent texture**.

Recommended source:

```
Natural Earth coastline dataset
```

Convert to **equirectangular map**.

Shader modification:

```
uniform sampler2D coastline_tex;

vec3 coast = texture(coastline_tex, UV).rgb;

EMISSION += coast * vec3(0.2,1.0,0.4);
```

This avoids the need to render vector geometry.

Mapping works because sphere meshes typically use **equirectangular UV projection**. ([Godot Forum][1])

---

# Step 6 — Radar Sweep Effect

Create a **thin transparent cylinder or plane**.

Scene:

```
RadarSweep (MeshInstance3D)
```

Attach script:

```gdscript
extends Node3D

@export var sweep_speed := 1.5

func _process(delta):
    rotate_y(sweep_speed * delta)
```

---

### Radar Sweep Shader

```
shader_type spatial;

render_mode blend_add;

uniform vec3 sweep_color = vec3(0.2,1.0,0.4);

void fragment(){
    float strength = 1.0 - UV.y;

    ALBEDO = vec3(0.0);
    EMISSION = sweep_color * strength;
}
```

This produces a rotating scan beam.

---

# Step 7 — CRT Scanline Shader (Post Process)

Add a **fullscreen shader**.

```
shader_type canvas_item;

void fragment() {

    vec2 uv = UV;

    float scan = sin(uv.y * 800.0) * 0.05;

    vec3 color = texture(SCREEN_TEXTURE, uv).rgb;

    color -= scan;

    COLOR = vec4(color,1.0);
}
```

Enhances the retro look.

---

# Step 8 — Bloom Settings

Enable **glow** in the environment.

```
Environment
  Glow Enabled: true
  Intensity: 0.8
  Strength: 1.2
```

Phosphor glow makes the grid look authentic.

---

# Step 9 — Camera Setup

Cold War displays usually have:

```
camera tilt ≈ 20°
distance ≈ 3–4 sphere radii
```

Example:

```
Camera position: (0,1.2,3)
Look at: (0,0,0)
```

---

# Step 10 — Optional Enhancements

### Missile trajectories

Draw arc:

```
Line3D
```

Arc math:

```
spherical interpolation
```

---

### Satellite icons

Use billboard sprites positioned via lat/lon conversion.

---

### Radar blips

Animated points with fade.

---

### Command overlays

Add UI labels like:

```
DEFCON
TRACKING
ICBM DETECTED
SATELLITE FEED
```

---

# Performance Notes

This design is extremely cheap:

| Component         | Cost    |
| ----------------- | ------- |
| Sphere mesh       | trivial |
| Shader grid       | minimal |
| Coastline texture | small   |
| Radar sweep       | trivial |

Total cost:

```
< 0.5 ms GPU
```

---

# Expected Result

The display should resemble:

```
1970s command center
green vector globe
slow rotation
radar sweep
CRT glow
```

Think:

```
WarGames
NORAD
submarine fire-control computer
```

---

# If you'd like, I can also generate

1. **A procedural coastline generator**
2. **A perfect CRT phosphor shader stack**
3. **Missile trajectory math**
4. **A full Godot project template**

All tuned for your **retro terminal / submarine / Cold War UI project stack**, which fits *exactly* the stuff you’ve been building lately.

[1]: https://forum.godotengine.org/t/mapping-a-planet-texture-to-a-sphere/119342?utm_source=chatgpt.com "Mapping a Planet Texture to a Sphere - Shaders - Godot Forum"
