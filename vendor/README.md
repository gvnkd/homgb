# vendor/

## imgui/

Dear ImGui 1.92.8 sources, matching the copy compiled into the
`dear-imgui` Haskell package (2.5.x) that we link against.

- Core headers (`imgui.h`, `imconfig.h`, `imgui_internal.h`,
  `imstb_*.h`) are copied verbatim from the dear-imgui-2.5.0 sdist.
- `backends/imgui_impl_sdl3.{h,cpp}` is fetched from upstream
  ocornut/imgui at tag v1.92.8 (dear-imgui only compiles the sdl2
  backend; we need the sdl3 one and cannot use `DearImGui.SDL`, which
  binds the sdl2 Haskell package).

Only `imgui_impl_sdl3.cpp` is compiled here (plus the `extern "C"`
shim in `cbits/homgb-imgui-sdl3.cpp`); the imgui core objects come
from libHSdear-imgui.

ABI: must be compiled with the same defines dear-imgui uses
(`-DIMGUI_USE_WCHAR32 -DImDrawIdx=unsigned int`), see homgb.cabal
cxx-options. Bump both copies together.
