# sdl3-bindgen-sys (lithon) is not packaged in nixpkgs at all: the
# generated SDL3 bindings homgb's windowing is built on. Pinned from
# Hackage; needs pkg-config sdl3 at configure time via its
# pkgconfig-depends.
self: super: {
  sdl3-bindgen-sys = self.callHackageDirect {
    pkg = "sdl3-bindgen-sys";
    ver = "0.0.0.3";
    sha256 = "0mj6s1nqklrnqq4a03gvnzxdq6jbsp9dbrfahcf6by0lbiq3slga";
  } { };
}
