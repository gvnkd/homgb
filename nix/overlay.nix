# Haskell package overlay wiring the pinned Hackage dependencies in
# nix/*.nix that nixpkgs doesn't carry at the versions homgb needs.
# Applied by flake.nix to the package set used for `nix build`.
final: prev: {
  # homgb uses SDL3 for video/input/GL only (no audio, no IME, no SDL
  # tray, no vulkan). nixpkgs' defaults pull ibus/libayatana-appindicator
  # (gtk+3) plus the pipewire/pulseaudio/jack stacks into every
  # pkg-config consumer's closure — enormous, and it blew the GHC
  # linker argv ("Argument list too long").
  sdl3 = (prev.sdl3.override {
    ibusSupport = false;
    pipewireSupport = false;
    pulseaudioSupport = false;
    jackSupport = false;
    traySupport = false;
    vulkanSupport = false;
    libusbSupport = false;
    # testautomation expects the disabled audio backends
  }).overrideAttrs (old: { doCheck = false; });

  haskellPackages = prev.haskellPackages.override {
    overrides = final.lib.composeManyExtensions [
      # homgb's pkgconfig-depends land in the cabal2nix argument list;
      # make them resolvable in the callPackage scope (xcb-xkb.pc
      # ships inside libxcb)
      (self: super: {
        xcb = final.xorg.libxcb;
        "xcb-xkb" = final.xorg.libxcb;
        x11 = final.xorg.libX11;
        sdl3 = final.sdl3;
      })
      (import ./dear-imgui.nix { haskellLib = final.haskell.lib; })
      (import ./status-notifier-item.nix)
      (import ./sdl3-bindgen-sys.nix)
    ];
  };
}
