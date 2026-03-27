# Animation 005 — Pac-Man Chase

## Overview

Pac-Man travels vertically downward across all four stacked panels, chased by four classic ghosts (Blinky, Pinky, Inky, Clyde). A column of pellets fills the virtual height of the framebuffer. Pac-Man eats pellets as he passes and wraps back to the top when he reaches the bottom. The scene runs for a random duration of 45–90 seconds before fading out.

---

## Files

| File | Purpose |
|------|---------|
| `modules/pacman/PacMan.gd` | Main module script |
| `modules/pacman/PacMan.tscn` | Scene root (Node2D + script) |
| `modules/pacman/manifest.json` | Launcher manifest |
| `modules/pacman/images/ghost.svg` | Ghost sprite (recoloured per character via shader) |
| `modules/pacman/images/pacman.svg` | Pac-Man sprite asset (present but not used — Pac-Man is drawn procedurally) |

---

## Manifest

```json
{
  "id": "pac_man",
  "title": "Pac-Man Chase",
  "tags": ["arcade", "retro", "chase", "vertical"],
  "timeline": { "mode": "range", "min_sec": 45, "max_sec": 90 },
  "transition": { "in": "fade_black", "out": "fade_black", "in_duration": 1.0, "out_duration": 1.0 },
  "seed": { "policy": "scene+boot", "variant": "" },
  "interruptible": true,
  "weight": 1.0
}
```

---

## Visual Design

### Palette

| Element | Colour | Notes |
|---------|--------|-------|
| Background | `#020210` (near-black) | Per-panel solid fill |
| Pac-Man | `#FFE600` (arcade yellow) | Procedural pie-slice |
| Pellets | `#FFF2D9` (cream) | 3.8 px radius dots |
| Power pellets | `#FFF2D9` (cream, pulsing) | 9 px radius, sine-pulse brightness |
| Maze walls | `#1F38D1` (blue) | 4 px border + corridor dividers |
| Score text | White | Top-right of framebuffer |
| Ghost name labels | Per-ghost colour | Drawn beside each visible ghost |

### Ghost colours (arcade-faithful)

| Ghost | Name | Colour |
|-------|------|--------|
| 0 | BLINKY | Red `#FF2E2E` |
| 1 | PINKY | Pink `#FFB8E6` |
| 2 | INKY | Cyan `#33E6FF` |
| 3 | CLYDE | Orange `#FFB84D` |

Ghost sprites are loaded from `ghost.svg` (orange body baseline) and recoloured at runtime via an inline canvas-item shader. The shader detects "orangeness" (`clamp((r - b) * 2, 0, 1)`) and lerps body pixels toward the target ghost colour while leaving the white/blue eye pixels untouched.

---

## Motion

### Coordinate system

All vertical movement uses the **virtual coordinate space** provided by `VirtualSpace` (total virtual height = 4608 px: 4 × 768 panel pixels + 3 × 512 bezel gap pixels). Pac-Man and ghosts travel in virtual Y, mapped to real panel Y via `virtual_to_real()`. Both automatically disappear while in a bezel gap and reappear at the top of the next panel.

### Pac-Man

- Moves **downward** at **200 virtual px/sec** (one full loop ≈ 23 s).
- Starts at a random virtual Y position in the upper half (seeded per boot).
- On reaching the bottom of virtual space, wraps to the top and regenerates all pellets.
- Mouth oscillates open/closed via `abs(sin(mouth_t))` at **7 rad/sec** (~24° max opening), facing downward (`PI/2`).
- Drawn with a 28-vertex `draw_polygon` pie-slice plus a small eye dot.
- Radius: **52 real px**.

### Ghosts

- Four ghosts trail behind Pac-Man, spaced **90 virtual px** apart.
- Each ghost's virtual Y = `(pac_virt_y - (i+1) * 90) mod virtual_h`.
- Rendered as `Sprite2D` nodes with shader material; scale set so the sprite fits a **48 px** half-height bounding box.
- Ghost name label drawn beside each visible ghost using the fallback font at 12 pt.

### Pellets

- One pellet every **48 virtual px**, spanning the full virtual height (~96 pellets).
- Every **8th** pellet (by index) is a power pellet (larger, brightness-pulsing).
- Pac-Man eats any pellet within **~73 px** (radius × 1.4) of its virtual Y; eaten pellets are tracked in a dictionary keyed by integer virtual Y and excluded from drawing.
- Score increments by **10** per eaten pellet.

---

## Per-Panel Decoration

Each panel receives the same decoration layout in real coordinates:

- **Dark background** rect.
- **Outer maze border**: 4 px blue lines inset 36 px from panel edges.
- **Horizontal corridor dividers** at 33% and 67% panel height, split left/right of the central track with a gap wide enough for Pac-Man to pass unobstructed (`gap = radius * 2.4`).
- **Corner accent ticks**: short 1.5 px lines at each inner border corner.
- **Panel label**: "PANEL  I" through "PANEL  IV" in 14 pt at the top-left inside the border.

---

## HUD

Drawn via `_draw()` directly on the Node2D canvas:

- **Score**: top-right of the framebuffer, `"SCORE  XXXXXX"` format (6 digits, zero-padded), 20 pt.
- **"1UP"** label: top-left, 18 pt, dimmed grey.
- **Ghost name labels**: drawn beside each ghost sprite that is currently visible, coloured to match the ghost.

---

## Wind-Down / Stop

When `module_request_stop()` is called (by Launcher deadline or the `N` debug key):

1. `_winding_down = true`, `_wd_timer = 0`.
2. Each frame, alpha fades linearly from 1 → 0 over **1.5 seconds** (`WD_DUR`).
3. Ghost sprite `modulate.a` is updated in `_process`; Pac-Man and all `_draw()` elements use the same `a` factor.
4. After 1.5 s, `_finished = true` → Launcher proceeds to transition out.

---

## Lifecycle Methods

| Method | Behaviour |
|--------|-----------|
| `module_configure(ctx)` | Stores manifest, panel layout, virtual space; initialises RNG from seed. |
| `module_start()` | Records start time, resets state, builds pellet array, creates ghost Sprite2D nodes with shader materials. |
| `module_status()` | Returns `{ok:true, notes:"score:N vy:N", intensity:0.5}`. |
| `module_request_stop(reason)` | Sets `_winding_down=true`, logs reason. |
| `module_is_finished()` | Returns `_finished` (true after wind-down completes). |
| `module_shutdown()` | Frees ghost Sprite2D nodes, clears texture/shader refs, clears dot arrays. |

---

## Implementation Notes

- Pac-Man is drawn **procedurally** — `pacman.svg` is present in the images folder but not used.
- The ghost shader is compiled from an inline string constant (`GHOST_SHADER_SRC`) at startup; no `.gdshader` file on disk.
- If `ghost.svg` is missing or fails to load as `Texture2D`, ghosts are silently skipped (warnings logged via `Log.warn`).
- Virtual space wrapping uses `fmod(virt_y, virtual_h)` with a `+ virtual_h * 2.0` offset before the modulo to keep ghost virtual-Y values positive.
- The scene root is a minimal `.tscn` (Node2D + script only); all child nodes (ghost Sprite2Ds) are created and destroyed in code.
