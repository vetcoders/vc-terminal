# Product icon

`vc-terminal-icon.png` is the 1254 × 1254 static VC Terminal Dock icon:
a filled, rounded galactic-navy tile with the pale three-circle product mark.
The lower-left circle is filled; the upper and lower-right circles are outlined.
Transparency is confined to the space outside the tile.

Founder requested a filled application icon on 2026-10-04. The agent prepared
this variant with imagegen using the prior monochrome tray pictogram as its
reference (`vibecrafted/docs/presence/tray-pictogram-monochrome.png`).
Master SHA-256: `94f21388aa5ed358503294a543db80a8a74d7b114137e12e9f854114cc7599d3`.

Run `make icons` to regenerate the 128px reference and macOS ICNS representations
up to 1024px. Run `make icons-check` to check the master and derived assets.
Vibecrafted's `materialize_vc_terminal_app_bundle` packages these for both the
embedded helper and Runtime Pack; this donor does not install a separate app.

Dock artwork is static. Tray activity animation and live health indicators
are separate behavior. The tray template asset remains independent.
