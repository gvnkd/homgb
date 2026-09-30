/* Minimal XCB/XKB shim for homgb's keyboard layout manager.
 *
 * Hides libxcb reply struct layouts from the Haskell FFI layer.
 * Connection is opaque (void *) on the Haskell side.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <xcb/xcb.h>
#include <xcb/xkb.h>

/* Finds the top-level window of this process on the given root
 * (SDL sets _NET_WM_PID) and tags it with EWMH properties so WMs
 * treat it as a dock/panel surface: _NET_WM_WINDOW_TYPE=DOCK,
 * SKIP_TASKBAR|PAGER, sticky desktop, _NET_WM_PID. */
Window homgb_find_window_by_pid(Display *dpy, Window root, long pid) {
  Window root_ret, parent, *kids = NULL;
  unsigned int n = 0;
  Atom pidAtom = XInternAtom(dpy, "_NET_WM_PID", True);
  if (pidAtom == None) return None;
  if (!XQueryTree(dpy, root, &root_ret, &parent, &kids, &n)) return None;
  Window found = None;
  for (unsigned i = 0; i < n && !found; i++) {
    Atom type = None;
    int fmt = 0;
    unsigned long nitems = 0, bytes = 0;
    unsigned char *prop = NULL;
    if (XGetWindowProperty(dpy, kids[i], pidAtom, 0, 1, False,
                           XA_CARDINAL, &type, &fmt, &nitems, &bytes,
                           &prop) == Success && prop) {
      if (nitems >= 1 && fmt == 32 && *(long *)prop == pid) found = kids[i];
      XFree(prop);
    }
  }
  if (kids) XFree(kids);
  return found;
}

void homgb_set_dock_props(Display *dpy, Window win) {
  Atom typeAtom = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  Atom dock = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", False);
  Atom stateAtom = XInternAtom(dpy, "_NET_WM_STATE", False);
  Atom skipTaskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
  Atom skipPager = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", False);
  Atom desktopAtom = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
  Atom pidAtom = XInternAtom(dpy, "_NET_WM_PID", False);
  Atom atomType = XInternAtom(dpy, "ATOM", False);
  long pid = (long)getpid();
  unsigned int allDesktops = 0xFFFFFFFF; /* sticky */
  Atom states[2];

  XChangeProperty(dpy, win, typeAtom, atomType, 32, PropModeReplace,
                  (unsigned char *)&dock, 1);
  states[0] = skipTaskbar;
  states[1] = skipPager;
  XChangeProperty(dpy, win, stateAtom, atomType, 32, PropModeReplace,
                  (unsigned char *)states, 2);
  XChangeProperty(dpy, win, desktopAtom, XA_CARDINAL, 32, PropModeReplace,
                  (unsigned char *)&allDesktops, 1);
  XChangeProperty(dpy, win, pidAtom, XA_CARDINAL, 32, PropModeReplace,
                  (unsigned char *)&pid, 1);
  XFlush(dpy);
}

/* Re-asserts _NET_WM_DESKTOP=0xFFFFFFFF if the WM overwrote it (WMs
 * assign a desktop when they adopt the window, racing the initial
 * property set). Called periodically from a dedicated display. */
void homgb_ensure_sticky(Display *dpy, Window win) {
  Atom desktopAtom = XInternAtom(dpy, "_NET_WM_DESKTOP", True);
  if (desktopAtom == None) return;
  Atom type = None;
  int fmt = 0;
  unsigned long nitems = 0, bytes = 0;
  unsigned char *prop = NULL;
  int ok = XGetWindowProperty(dpy, win, desktopAtom, 0, 1, False,
                              XA_CARDINAL, &type, &fmt, &nitems, &bytes,
                              &prop);
  int sticky = (ok == Success && prop && nitems >= 1
                && *(unsigned long *)prop == 0xFFFFFFFFUL);
  if (prop) XFree(prop);
  if (!sticky) {
    unsigned int allDesktops = 0xFFFFFFFF;
    XChangeProperty(dpy, win, desktopAtom, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&allDesktops, 1);
    XFlush(dpy);
  }
}

/* Xlib's default error handler prints and EXITS the process - a
 * failed XGrabKey (combo already grabbed, e.g. by a second homgb
 * instance) would kill the app. Install this handler instead: log
 * and continue. */
static int homgb_x_error_handler(Display *dpy, XErrorEvent *ev) {
  char buf[256];
  XGetErrorText(dpy, ev->error_code, buf, sizeof(buf));
  fprintf(stderr, "homgb: X error ignored: %s (request code %d)\n",
          buf, ev->request_code);
  return 0;
}

void homgb_x_ignore_errors(Display *dpy) {
  XSetErrorHandler(homgb_x_error_handler);
}

/* Direct map/unmap: SDL_ShowWindow/HideWindow turned out unreliable
 * for surfaces that toggle visibility (reported success, stayed
 * withdrawn). */
void homgb_x_map(Display *dpy, Window win) {
  XMapWindow(dpy, win);
  XFlush(dpy);
}

void homgb_x_unmap(Display *dpy, Window win) {
  XUnmapWindow(dpy, win);
  XFlush(dpy);
}

/* Screen size in pixels of the first X screen (for surface
 * positioning). Returns 1 on success. */
int homgb_screen_size(void *conn_, int *w, int *h) {
  xcb_connection_t *c = (xcb_connection_t *)conn_;
  xcb_screen_iterator_t sit = xcb_setup_roots_iterator(xcb_get_setup(c));
  if (sit.rem < 1) return 0;
  *w = sit.data->width_in_pixels;
  *h = sit.data->height_in_pixels;
  return 1;
}

/* Sets _NET_WM_WINDOW_TYPE from type_name (e.g.
 * "_NET_WM_WINDOW_TYPE_DOCK"), plus SKIP_TASKBAR/PAGER and _NET_WM_PID;
 * sticky desktop when sticky != 0. Used pre-map per surface window. */
void homgb_set_window_type_props(Display *dpy, Window win,
                                 const char *type_name, int sticky) {
  Atom typeAtom = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  Atom type = XInternAtom(dpy, type_name, False);
  Atom stateAtom = XInternAtom(dpy, "_NET_WM_STATE", False);
  Atom skipTaskbar = XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
  Atom skipPager = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", False);
  Atom desktopAtom = XInternAtom(dpy, "_NET_WM_DESKTOP", False);
  Atom pidAtom = XInternAtom(dpy, "_NET_WM_PID", False);
  Atom atomType = XInternAtom(dpy, "ATOM", False);
  long pid = (long)getpid();
  unsigned int allDesktops = 0xFFFFFFFF;
  Atom states[2];

  XChangeProperty(dpy, win, typeAtom, atomType, 32, PropModeReplace,
                  (unsigned char *)&type, 1);
  states[0] = skipTaskbar;
  states[1] = skipPager;
  XChangeProperty(dpy, win, stateAtom, atomType, 32, PropModeReplace,
                  (unsigned char *)states, 2);
  XChangeProperty(dpy, win, pidAtom, XA_CARDINAL, 32, PropModeReplace,
                  (unsigned char *)&pid, 1);
  if (sticky) {
    XChangeProperty(dpy, win, desktopAtom, XA_CARDINAL, 32,
                    PropModeReplace, (unsigned char *)&allDesktops, 1);
  }
  XFlush(dpy);
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
