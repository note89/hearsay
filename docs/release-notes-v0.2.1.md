# hearsay v0.2.1 — NixOS, Wayland paste, baked-in fonts

**New**
- **Nix flake.** `nix run github:note89/hearsay` builds `hearsay-rs` with every library linked and the
  run-time-loaded ones wrapped in, so it starts on NixOS. `nix develop` for a dev shell. CI builds the flake
  on every push.
- **Wayland paste on wlroots compositors.** hearsay asks the compositor for `zwp_virtual_keyboard_v1`:
  Hyprland, Sway and river get the paste at the caret; GNOME still gets the clipboard and a "press Ctrl+V" pill.
- **Fonts baked in.** Inter for text and JetBrains Mono for keys and paths ship inside the binary, so the
  Linux and Windows window looks the same everywhere, and closer to the Mac app. Both SIL OFL.
- **Honest insertion outcomes.** "copied — could not paste" and "nothing landed — the text is in History"
  are now distinct; the log says which step failed. `hearsay-rs insert "text"` tests insertion by hand.
- `hearsay-rs insert` and `hearsay-rs transcribe file.wav [engine]` for debugging a desktop.

**Fixes**
- Style pane cards laid out horizontally on Linux; History showed a day count instead of a date.
