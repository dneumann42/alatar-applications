# Alatar applications

Nomicon Settings, Nomicon Launcher, Systemd UI, and Process UI share the
Ellipse UI toolkit. Alatar's Arch bootstrap fetches and builds these tools.

With Nim 2.4.2 and the Alatar, Ellipse, and Plugnim source checkouts:

```sh
./build-apps auto /path/to/alatar /path/to/ellipse /path/to/plugnim ./bin
```

Use `tui` for a build without SDL, or `gui` to require the SDL and Wayland
development libraries. A GUI-capable binary can run in a terminal with
`--tui`. Nomicon's compositor controls require a running Sway session.
