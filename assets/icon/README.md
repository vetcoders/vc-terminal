# Product icon

`vc-terminal-icon-light.png` is the exact 1024 × 1024 PNG supplied by the Founder
on 2026-10-04: three hollow black circles on a filled glossy silver rounded tile.
Its immutable SHA-256 is
`0f970578d5cb6aea1472840e4a2f03b3f5a294a9e6e26c682409f5e4767b9a2d`.
This raster is the sole production artwork authority.

`render.swift` derives the dark counterpart by pointwise native recoloring.
Every alpha value and circle coordinate stays unchanged. Cold ink `#e0def4`
replaces black; silver body and highlight tones remain ordered over the navy
`#0b0b12` base. The generator never draws new contours or resizes the master.
The light asset remains byte-identical to the supplied PNG.

`vc-terminal-icon.png` is the dark static fallback, byte-identical to
`vc-terminal-icon-dark.png`. The macOS application observes its effective system
appearance and selects the matching native NSImage. Only `applicationIconImage`
is changed: terminal/window themes, ANSI palettes and user configuration remain
independent. Older macOS or failed decoding retains the bundle's static ICNS.

On macOS, `make icons` regenerates the dark master, 128px reference and ICNS
representations up to 1024px. `make icons-check` checks the canonical digest,
every tinted pixel, hollow centers, exact alpha and derived carriers.
`cargo run -p alacritty --example dock_icon_probe -- OUTPUT_DIRECTORY` exports
actual native light/dark/light Dock images and proves observer teardown in an
isolated application without changing system appearance or opening a window.
The probe compares every actual/expected pair through `render.swift --compare-native`
and rejects the opposite appearance as a negative control:
AppKit's display-scale/profile rasterization requires native sRGB normalization.
Vibecrafted's `materialize_vc_terminal_app_bundle` packages these for both the
embedded helper and Runtime Pack; this donor does not install a separate app.

Dock artwork is static. Tray activity animation and live health indicators
are separate behavior. The tray template asset remains independent.
