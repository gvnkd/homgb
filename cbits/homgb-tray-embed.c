/* XEmbed system-tray host for homgb (freedesktop system tray spec
 * 0.3 + ICCCM 2.8 + XEmbed). homgb owns the _NET_SYSTEM_TRAY_S0
 * selection on the tray surface window; apps dock by sending a
 * _NET_SYSTEM_TRAY_OPCODE ClientMessage to the selection owner; we
 * reparent their icon window into a slot child window inside the
 * tray surface and announce the embedding with XEMBED_EMBEDDED_NOTIFY.
 * Mouse input needs no forwarding — docked windows are ordinary
 * mapped children and get their events from the server.
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <string.h>

static Atom a_opcode, a_manager, a_visual, a_orient, a_xembed, a_tray_sel;

/* Docked icon windows are reparented into slot children of the tray
 * surface. Slots use the SCREEN DEFAULT visual, and
 * _NET_SYSTEM_TRAY_VISUAL is deliberately NOT advertised: clients
 * then create their icon on the default visual too, which is the
 * only depth a slot can host. Advertising a 32-bit ARGB visual (the
 * SDL window's) broke docking both ways on real systems: clients
 * that honor the property made 32-bit icons, clients that don't
 * (several Telegram builds) made 24-bit ones — a cross-depth
 * reparent is a BadMatch either way (request code 7, the laptop
 * repro). trayer does the same (no property, default visual). */
static Visual *g_visual = NULL;
static int g_depth = 0;
static Colormap g_cmap = None;

static void intern_atoms(Display *dpy, int screen) {
  char selname[64];
  a_opcode = XInternAtom(dpy, "_NET_SYSTEM_TRAY_OPCODE", False);
  a_manager = XInternAtom(dpy, "MANAGER", False);
  a_visual = XInternAtom(dpy, "_NET_SYSTEM_TRAY_VISUAL", False);
  a_orient = XInternAtom(dpy, "_NET_SYSTEM_TRAY_ORIENT", False);
  a_xembed = XInternAtom(dpy, "_XEMBED", False);
  snprintf(selname, sizeof selname, "_NET_SYSTEM_TRAY_S%d", screen);
  a_tray_sel = XInternAtom(dpy, selname, False);
}

unsigned long homgb_xembed_opcode_atom(Display *dpy) {
  return (unsigned long)XInternAtom(dpy, "_NET_SYSTEM_TRAY_OPCODE", False);
}

unsigned long homgb_xembed_xembed_atom(Display *dpy) {
  return (unsigned long)XInternAtom(dpy, "_XEMBED", False);
}

/* A real server timestamp via a self-inflicted PropertyNotify
 * (ICCCM forbids CurrentTime for selection/MANAGER traffic). */
static long grab_timestamp(Display *dpy, Window w) {
  static Atom dummy;
  XEvent ev;
  if (!dummy)
    dummy = XInternAtom(dpy, "HOMGB_EMBED_TS", False);
  XSelectInput(dpy, w, PropertyChangeMask);
  XChangeProperty(dpy, w, dummy, XA_CARDINAL, 32, PropModeAppend, NULL, 0);
  XWindowEvent(dpy, w, PropertyChangeMask, &ev);
  XSelectInput(dpy, w, NoEventMask);
  return (long)ev.xproperty.time;
}

/* Become the tray host: create the (1x1, invisible) selection owner
 * window as a child of the tray surface, grab the selection and
 * broadcast MANAGER. Returns 1 on success, 0 when another tray
 * (trayer, another homgb) already owns the selection. */
int homgb_xembed_acquire(Display *dpy, Window parent, int screen,
                         Window *owner_out, long *ts_out) {
  Window owner;
  long ts;
  intern_atoms(dpy, screen);
  if (XGetSelectionOwner(dpy, a_tray_sel) != None)
    return 0;
  owner = XCreateSimpleWindow(dpy, parent, 0, 0, 1, 1, 0, 0, 0);
  XSelectInput(dpy, owner, NoEventMask);
  ts = grab_timestamp(dpy, owner);
  XSetSelectionOwner(dpy, a_tray_sel, owner, (Time)ts);
  if (XGetSelectionOwner(dpy, a_tray_sel) != owner) {
    XDestroyWindow(dpy, owner);
    return 0;
  }
  /* MANAGER announcement so already-running apps (Telegram, Electron
   * clients) notice the tray and embed without a restart. */
  {
    XClientMessageEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.type = ClientMessage;
    ev.window = DefaultRootWindow(dpy);
    ev.message_type = a_manager;
    ev.format = 32;
    ev.data.l[0] = ts;
    ev.data.l[1] = a_tray_sel;
    ev.data.l[2] = (long)owner;
    XSendEvent(dpy, DefaultRootWindow(dpy), False, StructureNotifyMask,
               (XEvent *)&ev);
  }
  /* horizontal orientation, advertised on the owner window */
  {
    unsigned long orient = 0;
    XChangeProperty(dpy, owner, a_orient, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)&orient, 1);
  }
  /* dock requests arrive as ClientMessages sent with the
   * StructureNotifyMask bit */
  XSelectInput(dpy, owner, StructureNotifyMask);
  g_visual = DefaultVisual(dpy, screen);
  g_depth = DefaultDepth(dpy, screen);
  g_cmap = DefaultColormap(dpy, screen);
  *owner_out = owner;
  *ts_out = ts;
  XFlush(dpy);
  return 1;
}

/* Dock `client` into a fresh slot window (child of the tray surface
 * at x,y btn-sized), reparent, map, and announce XEMBED_EMBEDDED_NOTIFY.
 * bg_r/g/b tint the slot background (slots are 24-bit, no alpha — the
 * bar's color beats black in the unpainted regions). Returns the slot
 * window. */
Window homgb_xembed_dock(Display *dpy, Window parent, Window client,
                         int x, int y, int size, long ts,
                         int bg_r, int bg_g, int bg_b) {
  Window slot;
  if (g_visual) {
    XSetWindowAttributes a;
    XColor color;
    color.red = (short)(bg_r * 257);
    color.green = (short)(bg_g * 257);
    color.blue = (short)(bg_b * 257);
    XAllocColor(dpy, g_cmap, &color);
    a.colormap = g_cmap;
    a.background_pixel = color.pixel;
    a.border_pixel = 0;
    slot = XCreateWindow(dpy, parent, x, y, size, size, 0, g_depth,
                          InputOutput, g_visual,
                          CWColormap | CWBackPixel | CWBorderPixel, &a);
  } else {
    slot = XCreateSimpleWindow(dpy, parent, x, y, size, size, 0, 0, 0);
  }
  XSelectInput(dpy, slot, SubstructureNotifyMask);
  XReparentWindow(dpy, client, slot, 0, 0);
  /* Clients that assume a composited 32-bit tray may leave their
   * (24-bit) icon window unpainted; let those regions show the slot
   * background instead of the client's own black. */
  XSetWindowBackgroundPixmap(dpy, client, ParentRelative);
  XClearWindow(dpy, client);
  XMapWindow(dpy, slot);
  {
    XClientMessageEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.type = ClientMessage;
    ev.window = client;
    ev.message_type = a_xembed;
    ev.format = 32;
    ev.data.l[0] = ts;
    ev.data.l[1] = 1; /* XEMBED_EMBEDDED_NOTIFY */
    ev.data.l[2] = 0; /* highest supported protocol version */
    ev.data.l[3] = (long)slot;
    XSendEvent(dpy, client, False, NoEventMask, (XEvent *)&ev);
  }
  XResizeWindow(dpy, client, size, size);
  /* no-op when already mapped: a client that mapped itself before
   * the slot existed was unmapped by the reparent (unmapped parent)
   * and XEmbed clients may wait for EMBEDDED_NOTIFY before mapping */
  XMapWindow(dpy, client);
  XFlush(dpy);
  /* drop the dock when the client window is dead (e.g. its embedder
   * died and the app re-docked a stale id before recreating it):
   * verify the reparent actually took */
  XSync(dpy, False);
  {
    Window rt, parent, *kids = NULL;
    unsigned int nk = 0;
    if (XQueryTree(dpy, client, &rt, &parent, &kids, &nk) == 0 ||
        parent != slot) {
      XDestroyWindow(dpy, slot);
      XFlush(dpy);
      return None;
    }
    if (kids)
      XFree(kids);
  }
  return slot;
}

void homgb_xembed_move(Display *dpy, Window slot, int x, int y, int size) {
  XMoveResizeWindow(dpy, slot, x, y, size, size);
}

void homgb_xembed_undock(Display *dpy, Window slot) {
  XDestroyWindow(dpy, slot);
  XFlush(dpy);
}

/* Drain one relevant event (dock request / XEmbed message / child
 * destruction). Returns 1 when an event was dequeued. `type_out` is
 * the ClientMessage message_type atom, or DestroyNotify (a real
 * event type constant) for child destruction.
 *
 * NB: XCheckMaskEvent silently drops sent events (ClientMessage
 * mask matching is unreliable across sender conventions — verified:
 * the dock request sat in the queue unseen while XNextEvent
 * returned it). XCheckIfEvent with an always-true predicate sees
 * everything, including NoEventMask XEMBED protocol messages. */
static Bool homgb_any_event(Display *d, XEvent *e, char *arg) {
  (void)d; (void)e; (void)arg;
  return True;
}

int homgb_xembed_poll(Display *dpy, long *type_out, unsigned long *win_out,
                      long *d0, long *d1, long *d2) {
  XEvent ev;
  if (!XCheckIfEvent(dpy, &ev, homgb_any_event, NULL))
    return 0;
  if (ev.type == ClientMessage) {
    *type_out = (long)ev.xclient.message_type;
    *win_out = (unsigned long)ev.xclient.window;
    *d0 = ev.xclient.data.l[0];
    *d1 = ev.xclient.data.l[1];
    *d2 = ev.xclient.data.l[2];
    return 1;
  }
  if (ev.type == DestroyNotify) {
    *type_out = DestroyNotify;
    *win_out = (unsigned long)ev.xdestroywindow.window;
    *d0 = *d1 = *d2 = 0;
    return 1;
  }
  return 0;
}
