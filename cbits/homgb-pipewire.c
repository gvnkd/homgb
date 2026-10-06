/* homgb-pipewire.c — minimal native PipeWire client for the volume OSD.
 *
 * Connects to the pipewire-0 socket, follows the default audio sink
 * (published by WirePlumber in the "default" metadata as
 * default.audio.sink / default.configured.audio.sink), binds that node
 * and tracks SPA_PARAM_Props (volume / mute / channelVolumes). All
 * callbacks fire on the pw_thread_loop thread; the Haskell side only
 * writes TVars + wakes the SDL loop from there.
 *
 * API (see src/Homgb/PipeWire.hs):
 *   homgb_pw_connect()        -> handle or NULL
 *   homgb_pw_destroy(h)
 *   homgb_pw_set_callback(h, cb)   cb: void (*)(float vol, int muted, int avail)
 *   homgb_pw_set_volume(h, linear)  set channel volume, linear 0..1 (cubic scale
 *                                  is applied on the Haskell side)
 *   homgb_pw_set_mute(h, mode)     0 = off, 1 = on, 2 = toggle
 */

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/param.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/pod/iter.h>
#include <spa/utils/defs.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HOMGB_MAX_SINKS 16
#define HOMGB_MAX_CH 8
#define HOMGB_MAX_META 8

typedef void (*homgb_pw_cb_t)(float volume, int muted, int available);

struct homgb_sink {
  uint32_t id;
  char name[128];
};

struct homgb_pw {
  struct pw_thread_loop *loop;
  struct pw_context *ctx;
  struct pw_core *core;
  struct pw_registry *registry;
  struct spa_hook core_listener;
  struct spa_hook registry_listener;
  struct spa_hook meta_listeners[HOMGB_MAX_META];
  struct spa_hook node_listener;
  struct spa_hook proxy_listener;

  struct pw_proxy *meta_proxies[HOMGB_MAX_META];
  int n_meta;
  struct pw_proxy *node_proxy; /* bound default sink */
  struct pw_node *node;
  int node_bound_id;

  struct homgb_sink sinks[HOMGB_MAX_SINKS];
  int n_sinks;
  /* effective default target: runtime (default.audio.sink) wins over
   * configured (default.configured.audio.sink); empty = unset */
  char runtime_target[128];
  char configured_target[128];

  float volume;
  float chvol[HOMGB_MAX_CH];
  uint32_t nch;
  int muted;
  int available;

  homgb_pw_cb_t cb;
};

static const struct pw_node_events node_events;
static const struct pw_proxy_events proxy_events;

static void homgb_pw_emit(struct homgb_pw *h) {
  if (h->cb)
    h->cb(h->volume, h->muted, h->available);
}

/* ---- default sink selection ---------------------------------------- */

static void homgb_pw_unbind_node(struct homgb_pw *h) {
  if (h->node_proxy) {
    spa_hook_remove(&h->node_listener);
    spa_hook_remove(&h->proxy_listener);
    pw_proxy_destroy(h->node_proxy);
    h->node_proxy = NULL;
    h->node = NULL;
    h->node_bound_id = -1;
  }
}

/* must be called with the loop lock held */
static void homgb_pw_maybe_select(struct homgb_pw *h) {
  struct homgb_sink *sel = NULL;
  const char *target = h->runtime_target[0] ? h->runtime_target
    : h->configured_target[0] ? h->configured_target : NULL;
  int i;

  if (target) {
    for (i = 0; i < h->n_sinks; i++) {
      if (strcmp(h->sinks[i].name, target) == 0) {
        sel = &h->sinks[i];
        break;
      }
    }
  }
  if (!sel && h->n_sinks > 0)
    sel = &h->sinks[0];
  if (!sel || (int)sel->id == h->node_bound_id)
    return;

  homgb_pw_unbind_node(h);
  h->node_proxy = pw_registry_bind(h->registry, sel->id,
      PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
  if (!h->node_proxy)
    return;
  h->node = (struct pw_node *)h->node_proxy;
  h->node_bound_id = (int)sel->id;
  h->available = 0;
  h->volume = 0.f;
  h->muted = 0;
  h->nch = 0;
  pw_node_add_listener(h->node, &h->node_listener, &node_events, h);
  pw_proxy_add_listener(h->node_proxy, &h->proxy_listener, &proxy_events, h);
  pw_node_enum_params(h->node, 1, SPA_PARAM_Props, 0, 1, NULL);
  {
    uint32_t ids[] = { SPA_PARAM_Props };
    pw_node_subscribe_params(h->node, ids, 1);
  }
}

/* ---- metadata (default audio sink) --------------------------------- */

static void parse_default_sink(struct homgb_pw *h, const char *key,
    const char *value) {
  /* value is JSON: {"name":"alsa_output.pci-..."} */
  const char *p = strstr(value, "\"name\"");
  char *dst;
  size_t len;
  if (!p)
    return;
  p = strchr(p + 6, ':');
  if (!p)
    return;
  p++;
  while (*p == ' ' || *p == '\t')
    p++;
  if (*p != '"')
    return;
  p++;
  len = strcspn(p, "\"");
  if (len == 0 || len >= 128)
    return;
  dst = strcmp(key, "default.audio.sink") == 0
    ? h->runtime_target : h->configured_target;
  memcpy(dst, p, len);
  dst[len] = '\0';
  homgb_pw_maybe_select(h);
}

static int on_meta_property(void *data, uint32_t subject, const char *key,
    const char *type, const char *value) {
  struct homgb_pw *h = data;
  (void)subject;
  (void)type;
  if (!key || !value)
    return 0;
  if (strcmp(key, "default.audio.sink") == 0 ||
      strcmp(key, "default.configured.audio.sink") == 0)
    parse_default_sink(h, key, value);
  return 0;
}

static const struct pw_metadata_events meta_events = {
  PW_VERSION_METADATA_EVENTS,
  .property = on_meta_property,
};

/* ---- node params ----------------------------------------------------- */

static void on_node_param(void *data, int seq, uint32_t id, uint32_t index,
    uint32_t next, const struct spa_pod *param) {
  struct homgb_pw *h = data;
  const struct spa_pod_prop *prop;
  float vol = -1.f;
  float chv[HOMGB_MAX_CH];
  uint32_t nch = 0;
  int mute = -1;
  int got = 0;
  int i;

  (void)seq;
  (void)index;
  (void)next;
  if (id != SPA_PARAM_Props || !param)
    return;

  SPA_POD_OBJECT_FOREACH((const struct spa_pod_object *)param, prop) {
    switch (prop->key) {
    case SPA_PROP_volume:
      if (spa_pod_get_float(&prop->value, &vol) == 0)
        got = 1;
      break;
    case SPA_PROP_mute:
    {
      bool m;
      if (spa_pod_get_bool(&prop->value, &m) == 0) {
        mute = m ? 1 : 0;
        got = 1;
      }
      break;
    }
    case SPA_PROP_channelVolumes:
    {
      uint32_t n = 0, val_size = 0, val_type = 0;
      const void *elems = spa_pod_get_array_full(&prop->value, &n,
          &val_size, &val_type);
      if (elems && val_type == SPA_TYPE_Float && val_size == sizeof(float)) {
        if (n > HOMGB_MAX_CH)
          n = HOMGB_MAX_CH;
        memcpy(chv, elems, n * sizeof(float));
        nch = n;
        got = 1;
      }
      break;
    }
    default:
      break;
    }
  }
  if (!got)
    return;

  if (nch > 0) {
    float sum = 0.f;
    for (i = 0; i < (int)nch; i++)
      sum += chv[i];
    h->volume = sum / nch;
    memcpy(h->chvol, chv, nch * sizeof(float));
    h->nch = nch;
  } else if (vol >= 0.f) {
    h->volume = vol;
  }
  if (mute >= 0)
    h->muted = mute;
  h->available = 1;
  homgb_pw_emit(h);
}

static void on_node_info(void *data, const struct pw_node_info *info) {
  (void)data;
  (void)info;
}

static const struct pw_node_events node_events = {
  PW_VERSION_NODE_EVENTS,
  .info = on_node_info,
  .param = on_node_param,
};

static void on_proxy_destroy(void *data) {
  struct homgb_pw *h = data;
  h->node_proxy = NULL;
  h->node = NULL;
  h->node_bound_id = -1;
  h->available = 0;
  homgb_pw_emit(h);
}

static const struct pw_proxy_events proxy_events = {
  PW_VERSION_PROXY_EVENTS,
  .destroy = on_proxy_destroy,
};

/* ---- registry -------------------------------------------------------- */

static void on_global(void *data, uint32_t id, uint32_t permissions,
    const char *type, uint32_t version, const struct spa_dict *props) {
  struct homgb_pw *h = data;
  const char *mc, *name;

  (void)permissions;
  if (!props)
    return;

  if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
    if (h->n_meta < HOMGB_MAX_META) {
      struct pw_proxy *mp = pw_registry_bind(h->registry, id, type, version, 0);
      if (mp) {
        int slot = h->n_meta++;
        h->meta_proxies[slot] = mp;
        pw_metadata_add_listener((struct pw_metadata *)mp,
            &h->meta_listeners[slot], &meta_events, h);
      }
    }
    return;
  }

  if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
    return;
  mc = spa_dict_lookup(props, "media.class");
  name = spa_dict_lookup(props, "node.name");
  if (!mc || !name || strcmp(mc, "Audio/Sink") != 0)
    return;
  if (h->n_sinks >= HOMGB_MAX_SINKS)
    return;
  h->sinks[h->n_sinks].id = id;
  snprintf(h->sinks[h->n_sinks].name, sizeof(h->sinks[h->n_sinks].name),
      "%s", name);
  h->n_sinks++;
  homgb_pw_maybe_select(h);
}

static void on_global_remove(void *data, uint32_t id) {
  struct homgb_pw *h = data;
  int i;

  for (i = 0; i < h->n_meta; i++) {
    if (h->meta_proxies[i] && id == pw_proxy_get_id(h->meta_proxies[i])) {
      spa_hook_remove(&h->meta_listeners[i]);
      pw_proxy_destroy(h->meta_proxies[i]);
      h->n_meta--;
      memmove(&h->meta_proxies[i], &h->meta_proxies[i + 1],
          (h->n_meta - i) * sizeof(h->meta_proxies[0]));
      memmove(&h->meta_listeners[i], &h->meta_listeners[i + 1],
          (h->n_meta - i) * sizeof(h->meta_listeners[0]));
      break;
    }
  }
  for (i = 0; i < h->n_sinks; i++) {
    if (h->sinks[i].id == id) {
      memmove(&h->sinks[i], &h->sinks[i + 1],
          (h->n_sinks - i - 1) * sizeof(h->sinks[0]));
      h->n_sinks--;
      break;
    }
  }
  if (h->node_bound_id == (int)id) {
    homgb_pw_unbind_node(h);
    h->available = 0;
    homgb_pw_emit(h);
    /* fall back to the first remaining sink, if any */
    homgb_pw_maybe_select(h);
  }
}

static const struct pw_registry_events registry_events = {
  PW_VERSION_REGISTRY_EVENTS,
  .global = on_global,
  .global_remove = on_global_remove,
};

static void on_core_error(void *data, uint32_t id, int seq, int res,
    const char *message) {
  struct homgb_pw *h = data;
  (void)seq;
  (void)message;
  if (id == PW_ID_CORE && res == -EPIPE) {
    h->available = 0;
    homgb_pw_emit(h);
  }
}

static const struct pw_core_events core_events = {
  PW_VERSION_CORE_EVENTS,
  .error = on_core_error,
};

/* ---- public API ------------------------------------------------------- */

struct homgb_pw *homgb_pw_connect(void) {
  static int pw_initialized = 0;
  struct homgb_pw *h;

  if (!pw_initialized) {
    pw_init(NULL, NULL);
    pw_initialized = 1;
  }
  h = calloc(1, sizeof(*h));
  if (!h)
    return NULL;
  h->node_bound_id = -1;

  h->loop = pw_thread_loop_new("homgb-pw", NULL);
  if (!h->loop)
    goto fail;
  h->ctx = pw_context_new(pw_thread_loop_get_loop(h->loop), NULL, 0);
  if (!h->ctx)
    goto fail;

  pw_thread_loop_lock(h->loop);
  h->core = pw_context_connect(h->ctx, NULL, 0);
  if (!h->core) {
    pw_thread_loop_unlock(h->loop);
    goto fail;
  }
  pw_core_add_listener(h->core, &h->core_listener, &core_events, h);
  h->registry = pw_core_get_registry(h->core, PW_VERSION_REGISTRY, 0);
  if (!h->registry) {
    pw_thread_loop_unlock(h->loop);
    goto fail;
  }
  pw_registry_add_listener(h->registry, &h->registry_listener,
      &registry_events, h);
  pw_thread_loop_unlock(h->loop);

  if (pw_thread_loop_start(h->loop) < 0)
    goto fail;
  return h;

fail:
  fprintf(stderr, "homgb-pipewire: failed to connect: %m\n");
  if (h->registry)
    pw_proxy_destroy((struct pw_proxy *)h->registry);
  if (h->core)
    pw_core_disconnect(h->core);
  if (h->ctx)
    pw_context_destroy(h->ctx);
  if (h->loop)
    pw_thread_loop_destroy(h->loop);
  free(h);
  return NULL;
}

void homgb_pw_destroy(struct homgb_pw *h) {
  int i;
  if (!h)
    return;
  pw_thread_loop_stop(h->loop);
  homgb_pw_unbind_node(h);
  for (i = 0; i < h->n_meta; i++) {
    spa_hook_remove(&h->meta_listeners[i]);
    pw_proxy_destroy(h->meta_proxies[i]);
  }
  if (h->registry)
    pw_proxy_destroy((struct pw_proxy *)h->registry);
  if (h->core)
    pw_core_disconnect(h->core);
  pw_context_destroy(h->ctx);
  pw_thread_loop_destroy(h->loop);
  free(h);
}

void homgb_pw_set_callback(struct homgb_pw *h, homgb_pw_cb_t cb) {
  pw_thread_loop_lock(h->loop);
  h->cb = cb;
  homgb_pw_emit(h); /* deliver the cached state immediately */
  pw_thread_loop_unlock(h->loop);
}

/* must be called with the loop lock held; volume<0 / mute<0 = keep.
 * volume is the LINEAR channel gain; WirePlumber applies its cubic
 * volume scale on top, so the cubic mapping lives on the Haskell
 * side. Only the soft channel volumes are written — the node 'volume'
 * prop is the ALSA hw-mixer element and is owned by WirePlumber. */
static void homgb_pw_apply(struct homgb_pw *h, float volume, int mute) {
  uint8_t buffer[512];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  struct spa_pod_frame f;
  const struct spa_pod *pod;
  float chv[HOMGB_MAX_CH];
  uint32_t nch = h->nch ? h->nch : 2;
  int i;

  if (nch > HOMGB_MAX_CH)
    nch = HOMGB_MAX_CH;

  spa_pod_builder_push_object(&b, &f, SPA_TYPE_OBJECT_Props,
      SPA_PARAM_Props);
  if (volume >= 0.f) {
    for (i = 0; i < (int)nch; i++)
      chv[i] = volume;
    /* nodes without parsed channel counts get both the soft array
     * and the scalar; WirePlumber-managed nodes only receive the
     * array (their 'volume' prop is the hw mixer) */
    if (h->nch > 0) {
      spa_pod_builder_prop(&b, SPA_PROP_channelVolumes, 0);
      spa_pod_builder_array(&b, sizeof(float), SPA_TYPE_Float, nch, chv);
    } else {
      spa_pod_builder_prop(&b, SPA_PROP_volume, 0);
      spa_pod_builder_float(&b, volume);
    }
  }
  if (mute >= 0) {
    spa_pod_builder_prop(&b, SPA_PROP_mute, 0);
    spa_pod_builder_bool(&b, mute ? 1 : 0);
  }
  pod = spa_pod_builder_pop(&b, &f);
  pw_node_set_param(h->node, SPA_PARAM_Props, 0, pod);

  /* optimistic cache update; the server will echo a param event which
   * re-confirms these values (and any clamping it applied) */
  if (volume >= 0.f) {
    h->volume = volume;
    for (i = 0; i < (int)nch; i++)
      h->chvol[i] = volume;
  }
  if (mute >= 0)
    h->muted = mute ? 1 : 0;
  homgb_pw_emit(h);
}

int homgb_pw_set_volume(struct homgb_pw *h, float linear) {
  int res = -1;
  pw_thread_loop_lock(h->loop);
  if (h->node && h->available) {
    if (linear < 0.f)
      linear = 0.f;
    if (linear > 1.f)
      linear = 1.f;
    homgb_pw_apply(h, linear, -1);
    res = 0;
  }
  pw_thread_loop_unlock(h->loop);
  return res;
}

int homgb_pw_set_mute(struct homgb_pw *h, int mode) {
  int res = -1;
  pw_thread_loop_lock(h->loop);
  if (h->node && h->available) {
    int mute = mode == 2 ? !h->muted : (mode != 0);
    homgb_pw_apply(h, -1.f, mute);
    res = 0;
  }
  pw_thread_loop_unlock(h->loop);
  return res;
}
