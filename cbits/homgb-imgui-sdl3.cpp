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

/* Add a TTF/OTF font from a file to the CURRENT context's atlas and
 * make it the default font. with_cyrillic includes ImGui's Cyrillic
 * glyph ranges (the built-in default font has none). Returns the ImFont*
 * or NULL when the file cannot be loaded (caller keeps ImGui's
 * default). Call before the renderer builds the atlas (per surface). */
void *homgb_add_font(const char *filename, float size_pixels,
                     int with_cyrillic) {
  ImGuiIO &io = ImGui::GetIO();
  ImFontConfig cfg;
  if (with_cyrillic)
    cfg.GlyphRanges = io.Fonts->GetGlyphRangesCyrillic();
  ImFont *font = io.Fonts->AddFontFromFileTTF(filename, size_pixels, &cfg);
  if (font)
    io.FontDefault = font;
  return (void *)font;
}

/* Merge a fallback font into the CURRENT default font (glyphs the
 * primary font lacks — emoji, Nerd Font icons — resolve through it).
 * Must be added AFTER the primary font, same size, before the atlas
 * build. Returns the ImFont* or NULL when loading failed. */
void *homgb_add_merged_font(const char *filename, float size_pixels,
                            int with_cyrillic) {
  ImGuiIO &io = ImGui::GetIO();
  ImFontConfig cfg;
  cfg.MergeMode = true;
  if (with_cyrillic)
    cfg.GlyphRanges = io.Fonts->GetGlyphRangesCyrillic();
  ImFont *font = io.Fonts->AddFontFromFileTTF(filename, size_pixels, &cfg);
  return (void *)font;
}

/* dear-imgui's sameLine binds SameLine() without the spacing
 * argument; tray.spacing needs it. */
void homgb_same_line(float spacing) { ImGui::SameLine(0.0f, spacing); }

/* dear-imgui 2.5 binds only the ImVec2 PushStyleVar overload; the
 * float variant (WindowBorderSize, Alpha, ...) needs this shim. */
void homgb_push_style_var_float(int var, float value) {
  ImGui::PushStyleVar((ImGuiStyleVar)var, value);
}

} // extern "C"
