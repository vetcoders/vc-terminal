<p align="center">
    <img width="200" alt="Alacritty Logo" src="https://raw.githubusercontent.com/alacritty/alacritty/master/extra/logo/compat/alacritty-term%2Bscanlines.png">
</p>

<h1 align="center">vc-terminal — standalone terminal</h1>

<p align="center">
  <img alt="Alacritty - A fast, cross-platform, OpenGL terminal emulator"
       src="https://raw.githubusercontent.com/alacritty/alacritty/master/extra/promo/alacritty-readme.png">
</p>

## About

`vc-terminal` is an Alacritty-based terminal with its own macOS app and local
DMG build. It starts as a regular application with a Dock icon. The explicit
`--vibecrafted-hosted` switch retains the accessory/helper role used by existing
Vibecrafted installations.

The binary donor contract for the
[`vibecrafted`](https://github.com/vetcoders/vibecrafted) release builder remains:

```sh
make release-bins
```

It produces `target/release/alacritty` with the default Cargo target directory.
The upstream Alacritty documentation below describes inherited terminal behavior.

### Build the macOS app

Requirements: macOS, Rust/Cargo, Xcode Command Line Tools, Python 3, and `scdoc`
(`brew install scdoc`). The system supplies `tic`, `codesign` and `hdiutil`.

```sh
make app             # dist/vc-terminal.app
make dmg             # app plus dist/vc-terminal.dmg
make packaging-test  # packaging contracts with fake build/signing tools
```

Both targets build through `make release-bins`. The app executable is
`Contents/MacOS/vc-terminal`; Info.plist records the Cargo package version and
source commit. Source Code Pro fonts and their OFL license are bundled privately
through `ATSApplicationFontsPath`. Packaging does not change the default font.

The script uses an existing **Developer ID Application** identity for team
`MW223P3NPX` from the keychain when available, with hardened runtime and the
audio-input entitlement. Otherwise it reports ad-hoc signing. `DIST_DIR` can
override the output directory. For a previously built binary matching HEAD:

```sh
bash scripts/build-vc-terminal-release.sh --skip-build --skip-dmg
dist/vc-terminal.app/Contents/MacOS/vc-terminal --version
```

These targets do not notarize, install, publish, or provide an updater. The DMG
is a local build artifact, not a notarized public release.

Alacritty is a modern terminal emulator that comes with sensible defaults, but
allows for extensive [configuration](#configuration). By integrating with other
applications, rather than reimplementing their functionality, it manages to
provide a flexible set of [features](./docs/features.md) with high performance.
The supported platforms currently consist of BSD, Linux, macOS and Windows.

The software is considered to be at a **beta** level of readiness; there are
a few missing features and bugs to be fixed, but it is already used by many as
a daily driver.

Precompiled binaries are available from the [GitHub releases page](https://github.com/alacritty/alacritty/releases).

Join [`#alacritty`] on libera.chat if you have questions or looking for a quick help.

[`#alacritty`]: https://web.libera.chat/gamja/?channels=#alacritty

## Features

You can find an overview over the features available in Alacritty [here](./docs/features.md).

## Further information

- [Announcing Alacritty, a GPU-Accelerated Terminal Emulator](https://jwilm.io/blog/announcing-alacritty/) January 6, 2017
- [A talk about Alacritty at the Rust Meetup January 2017](https://www.youtube.com/watch?v=qHOdYO3WUTk) January 19, 2017
- [Alacritty Lands Scrollback, Publishes Benchmarks](https://jwilm.io/blog/alacritty-lands-scrollback/) September 17, 2018

## Installation

Alacritty can be installed by using various package managers on Linux, BSD,
macOS and Windows.

Prebuilt binaries for macOS and Windows can also be downloaded from the
[GitHub releases page](https://github.com/alacritty/alacritty/releases).

For everyone else, the detailed instructions to install Alacritty can be found
[here](INSTALL.md).

### Requirements

- At least OpenGL ES 2.0
- [Windows] ConPTY support (Windows 10 version 1809 or higher)

## Configuration

You can find the documentation for Alacritty's configuration in `man 5
alacritty`, or by looking at [the website] if you do not have the manpages
installed.

[the website]: https://alacritty.org/config-alacritty.html

### Vibecrafted host fragment

For the Vetcoders / Vibecrafted stack, the recommended host fragment lives at
`extra/config/vibecrafted-host.toml` (wheel split by alternate buffer +
`option_as_alt`). The full preset is owned by **vc-frame**:
`tools/alacritty/vc-frame.toml` and `tools/alacritty/launch-primary-shell.zsh`.
Do not wrap the login shell in permanent `smcup` — that kills host scrollback.

When launched by Vibecrafted, vc-terminal is a replaceable host: closing its
window releases the PTY client without explicitly signalling it, while vc-frame
continues to own the durable workspace/session. Stock Alacritty launches retain
their normal terminate-and-reap behavior. Operators can force either host policy
with `VIBECRAFTED_TERMINAL_CLOSE_MODE=detach|terminate`; destructive session
termination remains an explicit `vc-frame kill-session` / `delete-session`
operation and is never inferred from window close.


vc-terminal doesn't create the config file for you. On macOS and other Unix
systems, it first checks
`$HOME/.config/vibecrafted/vc-terminal/vc-terminal.toml`, then the inherited
locations below. This build retains that existing configuration lookup order.

1. `$XDG_CONFIG_HOME/alacritty/alacritty.toml`
2. `$XDG_CONFIG_HOME/alacritty.toml`
3. `$HOME/.config/alacritty/alacritty.toml`
4. `$HOME/.alacritty.toml`
5. `/etc/alacritty/alacritty.toml`

On Windows, the config file will be looked for in:

* `%APPDATA%\alacritty\alacritty.toml`

## Contributing

A guideline about contributing to Alacritty can be found in the
[`CONTRIBUTING.md`](CONTRIBUTING.md) file.

## FAQ

**_Is it really the fastest terminal emulator?_**

Benchmarking terminal emulators is complicated. Alacritty uses
[vtebench](https://github.com/alacritty/vtebench) to quantify terminal emulator
throughput and manages to consistently score better than the competition using
it. If you have found an example where this is not the case, please report a
bug.

Other aspects like latency or framerate and frame consistency are more difficult
to quantify. Some terminal emulators also intentionally slow down to save
resources, which might be preferred by some users.

If you have doubts about Alacritty's performance or usability, the best way to
quantify terminal emulators is always to test them with **your** specific
usecases.

**_Why isn't feature X implemented?_**

Alacritty has many great features, but not every feature from every other
terminal. This could be for a number of reasons, but sometimes it's just not a
good fit for Alacritty. This means you won't find things like tabs or splits
(which are best left to a window manager or [terminal multiplexer][tmux]) nor
niceties like a GUI config editor.

[tmux]: https://github.com/tmux/tmux

## License

Alacritty is released under the [Apache License, Version 2.0].

[Apache License, Version 2.0]: https://github.com/alacritty/alacritty/blob/master/LICENSE-APACHE
