/* Minimal XCB/XKB shim for homgb's keyboard layout manager.
 *
 * Hides libxcb reply struct layouts from the Haskell FFI layer.
 * Connection is opaque (void *) on the Haskell side.
 */
#include <stdlib.h>
#include <string.h>
#include <GL/glx.h>
#include <xcb/xcb.h>
#include <xcb/xkb.h>

/* Picks a depth-32 ARGB visual usable for a transparent GL window, or
 * -1 if none. Preferred: an FB config with 8-bit alpha whose X visual
 * is truly depth 32 (Mesa without ARGB GLX returns a depth-24 visual
 * here, which compositors treat as opaque). Fallback: any GLX-capable
 * depth-32 TrueColor visual (SDL creates the context on the window's
 * visual directly). Display comes from Xlib (Graphics.X11). */
long homgb_glx_alpha_visual(void *display_, int screen) {
  Display *dpy = (Display *)display_;
  int attribs[] = {
    GLX_RENDER_TYPE, GLX_RGBA_BIT,
    GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
    GLX_RED_SIZE, 8,
    GLX_GREEN_SIZE, 8,
    GLX_BLUE_SIZE, 8,
    GLX_ALPHA_SIZE, 8,
    GLX_DOUBLEBUFFER, True,
    None
  };
  int n = 0;
  GLXFBConfig *fb = glXChooseFBConfig(dpy, screen, attribs, &n);
  if (fb && n > 0) {
    XVisualInfo *vi = glXGetVisualFromFBConfig(dpy, fb[0]);
    if (vi) {
      long id = (vi->depth == 32) ? (long)vi->visualid : -1;
      XFree(vi);
      XFree(fb);
      if (id >= 0) return id;
    } else {
      XFree(fb);
    }
  }

  XVisualInfo templ;
  memset(&templ, 0, sizeof(templ));
  templ.screen = screen;
  templ.depth = 32;
  templ.class = TrueColor;
  XVisualInfo *vis = XGetVisualInfo(dpy,
    VisualScreenMask | VisualDepthMask | VisualClassMask, &templ, &n);
  if (!vis) return -1;
  long id = -1;
  for (int i = 0; i < n; i++) {
    int use_gl = 0, alpha = 0;
    if (glXGetConfig(dpy, &vis[i], GLX_USE_GL, &use_gl) == 0 && use_gl
        && glXGetConfig(dpy, &vis[i], GLX_ALPHA_SIZE, &alpha) == 0
        && alpha > 0) {
      id = (long)vis[i].visualid;
      break;
    }
  }
  XFree(vis);
  return id;
}

void *homgb_xcb_connect(void) {
  xcb_connection_t *c = xcb_connect(NULL, NULL);
  if (xcb_connection_has_error(c)) {
    xcb_disconnect(c);
    return NULL;
  }
  return c;
}

void homgb_xcb_disconnect(void *c) {
  xcb_disconnect((xcb_connection_t *)c);
}

int homgb_xkb_supported(void *conn) {
  xcb_connection_t *c = (xcb_connection_t *)conn;
  xcb_generic_error_t *err = NULL;
  xcb_xkb_use_extension_cookie_t ck =
    xcb_xkb_use_extension(c, XCB_XKB_MAJOR_VERSION, XCB_XKB_MINOR_VERSION);
  xcb_xkb_use_extension_reply_t *rep = xcb_xkb_use_extension_reply(c, ck, &err);
  int ok = rep && rep->supported;
  free(rep);
  free(err);
  return ok;
}

int homgb_xkb_get_group(void *conn) {
  xcb_connection_t *c = (xcb_connection_t *)conn;
  xcb_generic_error_t *err = NULL;
  xcb_xkb_get_state_cookie_t ck =
    xcb_xkb_get_state(c, XCB_XKB_ID_USE_CORE_KBD);
  xcb_xkb_get_state_reply_t *rep = xcb_xkb_get_state_reply(c, ck, &err);
  int group = -1;
  if (rep) {
    group = rep->group;
    free(rep);
  }
  free(err);
  return group;
}

int homgb_xkb_lock_group(void *conn, unsigned char group) {
  xcb_connection_t *c = (xcb_connection_t *)conn;
  xcb_generic_error_t *err = NULL;
  xcb_void_cookie_t ck = xcb_xkb_latch_lock_state(
      c, XCB_XKB_ID_USE_CORE_KBD,
      0, 0,       /* affectModLocks, modLocks: leave modifiers alone */
      1, group,   /* lockGroup, groupLock */
      0, 0, 0);   /* affectModLatches, latchGroup, groupLatch */
  err = xcb_request_check(c, ck);
  if (err) {
    free(err);
    return -1;
  }
  return 0;
}

/* Lists visual ids of depth-32 visuals on screen 0 (ARGB candidates
 * for a transparent window). Returns a malloc'ed array; *count set.
 * Caller frees. */
unsigned long *homgb_argb_visuals(void *conn_, int *count) {
  xcb_connection_t *c = (xcb_connection_t *)conn_;
  const xcb_setup_t *setup = xcb_get_setup(c);
  xcb_screen_iterator_t sit = xcb_setup_roots_iterator(setup);
  *count = 0;
  if (sit.rem < 1) return NULL;
  xcb_depth_iterator_t dit =
    xcb_screen_allowed_depths_iterator(sit.data);
  for (; dit.rem; xcb_depth_next(&dit)) {
    if (dit.data->depth == 32) {
      xcb_visualtype_iterator_t vit = xcb_depth_visuals_iterator(dit.data);
      int n = 0;
      for (; vit.rem; xcb_visualtype_next(&vit)) n++;
      unsigned long *out = malloc(sizeof(unsigned long) * (n > 0 ? n : 1));
      vit = xcb_depth_visuals_iterator(dit.data);
      int i = 0;
      for (; vit.rem; xcb_visualtype_next(&vit))
        out[i++] = vit.data->visual_id;
      *count = n;
      return out;
    }
  }
  return NULL;
}

/* Reads the root window _XKB_RULES_NAMES property and returns a
 * malloc'ed copy of the "layout" field (index 2, e.g. "us,ru"),
 * or NULL if unavailable. Caller frees. */
char *homgb_xkb_rules_layouts(void *conn) {
  xcb_connection_t *c = (xcb_connection_t *)conn;
  xcb_generic_error_t *err = NULL;

  xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;

  xcb_intern_atom_cookie_t ack =
    xcb_intern_atom(c, 1, strlen("_XKB_RULES_NAMES"), "_XKB_RULES_NAMES");
  xcb_intern_atom_reply_t *arep = xcb_intern_atom_reply(c, ack, &err);
  free(err);
  err = NULL;
  if (!arep) return NULL;
  xcb_atom_t prop = arep->atom;
  free(arep);
  if (!prop) return NULL;

  xcb_get_property_cookie_t pck =
    xcb_get_property(c, 0, screen->root, prop, XCB_ATOM_STRING, 0, 100);
  xcb_get_property_reply_t *prep = xcb_get_property_reply(c, pck, &err);
  free(err);
  err = NULL;
  if (!prep) return NULL;

  int len = xcb_get_property_value_length(prep);
  const char *data = xcb_get_property_value(prep);
  const char *end = data + len;
  char *out = NULL;

  /* value is a list of NUL-separated strings:
   * rules\0model\0layout\0variant\0options\0 */
  int idx = 0;
  const char *p = data;
  while (p < end) {
    const char *nul = memchr(p, '\0', (size_t)(end - p));
    size_t slen = nul ? (size_t)(nul - p) : (size_t)(end - p);
    if (idx == 2) {
      out = malloc(slen + 1);
      memcpy(out, p, slen);
      out[slen] = '\0';
      break;
    }
    if (!nul) break;
    p = nul + 1;
    idx++;
  }

  free(prep);
  return out;
}
