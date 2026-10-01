// Extern "C" wrappers over upstream imgui_impl_sdl3 (vendored in
// vendor/imgui). The Haskell side (Homgb.ImGui.SDL3) links these.
// dear-imgui's Haskell SDL module binds the sdl2 package, which we no
// longer use, so the SDL3 backend is compiled here instead.
#include "imgui.h"
#include "backends/imgui_impl_sdl3.h"
#include <SDL3/SDL.h>

extern "C" {

int homgb_imgui_sdl3_init_for_opengl(void *window, void *gl_context) {
  return ImGui_ImplSDL3_InitForOpenGL((SDL_Window *)window, gl_context)
             ? 1
             : 0;
}

void homgb_imgui_sdl3_shutdown(void) { ImGui_ImplSDL3_Shutdown(); }

void homgb_imgui_sdl3_new_frame(void) { ImGui_ImplSDL3_NewFrame(); }

int homgb_imgui_sdl3_process_event(const void *event) {
  return ImGui_ImplSDL3_ProcessEvent((const SDL_Event *)event) ? 1 : 0;
}

/* All surfaces share the CWD; per-context ini persistence corrupts
 * settings across ImGui contexts (and resurrects Debug##Default's
 * saved position). homgb positions every window with SetNextWindowPos
 * Always, so persistence is disabled for every context. Call with the
 * context current. */
void homgb_imgui_disable_ini(void) { ImGui::GetIO().IniFilename = nullptr; }

} // extern "C"
