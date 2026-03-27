# OrbitalOverview — Revision History

## 2026-03-08 — Globe orientation corrections (`OrbitalOverview.gd`)

**Change 1 — Rotate globe and all components 180°**

The entire visual output of the module was rotated 180° around the display center. Two changes were made:

- `_globe_sprite.rotation = PI` — rotates the SVG sprite in place around its own center (already positioned at `_center`).
- `draw_set_transform_matrix(Transform2D(PI, 2.0 * _center))` — applied at the top of `_draw()`, before any draw calls. This rotates all procedural drawing (wireframe grid, continents, radar ring/sweep, crosshairs, corner brackets, dot background) 180° around `_center`. The formula `Transform2D(angle, origin)` with `origin = 2 * _center` is the standard "rotate around a point" transform: maps any point P to `2*_center - P`.

**Change 2 — Flip continental coastlines east-west only**

The continent projection in `_draw_continents()` originally negated the X component (`Vector2(-x3, y3)`) to match Earth's true east-west layout. Removing that negation (`Vector2(x3, y3)`) flips only the continental outlines horizontally, without affecting the wireframe grid rotation, radar direction, or any other element.
