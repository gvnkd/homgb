# dear-imgui 2.5.0 is not in nixpkgs yet (unstable still has 2.4.1),
# so pin it from Hackage. Flag notes (must match homgb's vendored SDL3
# backend shim and cabal.project dev flags):
#   sdl disabled        — the SDL2-backed DearImGui.SDL module is
#                         unused (homgb compiles the SDL3 backend
#                         in-tree) and pulls the sdl2 package in
#   use-wchar32 = true  — default; ImWchar32, required for emoji
#   use-ImDrawIdx32     — default; matches the shim's -DImDrawIdx
{ haskellLib }:

self: super: {
  dear-imgui = haskellLib.overrideCabal
    (self.callHackageDirect {
      pkg = "dear-imgui";
      ver = "2.5.0";
      sha256 = "1qp6yw05iyzry43msvadmnq1gs3p29gj9qqi37nifzy1n4n52x12";
    } {
      # The sdl flag is disabled below; sdl2/SDL2 exist as arguments
      # only because cabal2nix lists default-flag deps unconditionally.
      # Stub them with null and filter out of the depends lists:
      # nixpkgs' sdl2/SDL2 are sdl2-compat wrappers whose SDL3 closure
      # (ibus, gtk+3, pipewire, ...) is enormous — it blew the linker
      # argv ("Argument list too long") even though nothing links them.
      sdl2 = null;
      SDL2 = null;
    })
    (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [ "-f-sdl" ];
      libraryHaskellDepends =
        builtins.filter (p: p != null) (old.libraryHaskellDepends or [ ]);
      libraryPkgconfigDepends =
        builtins.filter (p: p != null) (old.libraryPkgconfigDepends or [ ]);
    });
}
