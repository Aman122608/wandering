//
//  IDeviceShim.c
//  Wandering
//
//  Bridges the idevice FFI (jkcoxson/idevice, MIT) into a handful of int-returning
//  functions. Every FFI call is blocking, so callers must run these off the main
//  thread — the Swift side does that on a dedicated serial queue.
//

#include "IDeviceShim.h"

#include <arpa/inet.h>
#include <pthread.h>
#include <time.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include "idevice.h"

struct WanderingDevice {
    struct RpPairingFileHandle *pairing;
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *handshake;
    struct RemoteServerHandle *server;
    struct LocationSimulationHandle *sim;
    struct ImageMounterHandle *mounter;

    char ip[64];
    uint16_t port;
    int connected;
};

// MARK: - device-initiated pairing (iOS 27 flow)
//
// On iOS 27 the iPhone pairs with a *host it discovers*: Settings → Privacy &
// Security → Developer Mode → "Pair with <name>", then it shows/asks for a 6-digit
// code. That is the only way to get a pairing record this device accepts once an
// older record has been replaced — pair-verify with a stale record is answered with a
// reset, which is what "Connection reset by peer" has been.

typedef void (*wd_pin_display_fn)(const char *pin, void *context);

static wd_pin_display_fn g_pin_display = NULL;
static void *g_pin_display_context = NULL;

void wd_set_pin_display(wd_pin_display_fn fn, void *context) {
    g_pin_display = fn;
    g_pin_display_context = context;
}

static void wd_pin_display_cb(const char *pin, void *context) {
    (void)context;
    if (g_pin_display != NULL) {
        g_pin_display(pin != NULL ? pin : "", g_pin_display_context);
    }
}

int wd_pair_host(const char *name, const char *pairing_path, char *err, size_t err_len) {
    if (name == NULL || pairing_path == NULL) {
        wd_note(err, err_len, "invalid arguments");
        return -1;
    }
    struct RpPairingFileHandle *pairing = NULL;
    struct IdeviceFfiError *e = pairable_host_accept(name, NULL, 0,
                                                    wd_pin_display_cb, NULL,
                                                    NULL, NULL, &pairing);
    if (wd_fail(e, err, err_len, "pair with device") != 0 || pairing == NULL) {
        if (e == NULL) {
            wd_note(err, err_len, "pairing returned no record");
        }
        return -1;
    }
    e = rp_pairing_file_write(pairing, pairing_path);
    rp_pairing_file_free(pairing);
    if (wd_fail(e, err, err_len, "save paired record") != 0) {
        return -1;
    }
    return 0;
}

// MARK: - pairing PIN handshake
//
// `tunnel_create_rppairing` runs a pair-setup on the same socket when the device has
// never been paired with this host, and asks for the code shown on the device through
// a callback. Without one it cannot complete, and the device drops the connection —
// which is what "Connection reset by peer" was. The callback runs on the FFI's thread
// and must block until the user types the six digits.

static pthread_mutex_t g_pin_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pin_cond = PTHREAD_COND_INITIALIZER;
static char g_pin[16];
static int g_pin_ready = 0;
static int g_pin_cancelled = 0;
static int g_pin_pending_flag = 0;
static wd_pin_request_fn g_pin_request = NULL;
static void *g_pin_request_context = NULL;

void wd_set_pin_provider(wd_pin_request_fn request, void *context) {
    g_pin_request = request;
    g_pin_request_context = context;
}

int wd_submit_pin(const char *pin) {
    if (pin == NULL) {
        return -1;
    }
    pthread_mutex_lock(&g_pin_mutex);
    snprintf(g_pin, sizeof(g_pin), "%s", pin);
    g_pin_ready = 1;
    g_pin_pending_flag = 0;
    pthread_cond_broadcast(&g_pin_cond);
    pthread_mutex_unlock(&g_pin_mutex);
    return 0;
}

void wd_cancel_pin(void) {
    pthread_mutex_lock(&g_pin_mutex);
    g_pin_cancelled = 1;
    g_pin_pending_flag = 0;
    pthread_cond_broadcast(&g_pin_cond);
    pthread_mutex_unlock(&g_pin_mutex);
}

int wd_pin_pending(void) {
    pthread_mutex_lock(&g_pin_mutex);
    int pending = g_pin_pending_flag;
    pthread_mutex_unlock(&g_pin_mutex);
    return pending;
}

static const char *wd_pin_callback(void *context) {
    (void)context;
    pthread_mutex_lock(&g_pin_mutex);
    g_pin_ready = 0;
    g_pin_cancelled = 0;
    g_pin[0] = 0;
    g_pin_pending_flag = 1;
    pthread_mutex_unlock(&g_pin_mutex);

    if (g_pin_request != NULL) {
        g_pin_request(g_pin_request_context);
    }

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 180;

    pthread_mutex_lock(&g_pin_mutex);
    while (!g_pin_ready && !g_pin_cancelled) {
        if (pthread_cond_timedwait(&g_pin_cond, &g_pin_mutex, &deadline) == ETIMEDOUT) {
            break;
        }
    }
    int ready = g_pin_ready;
    g_pin_pending_flag = 0;
    pthread_mutex_unlock(&g_pin_mutex);
    return ready ? g_pin : NULL;
}

// MARK: - helpers

static int wd_fail(struct IdeviceFfiError *err, char *buf, size_t len, const char *where) {
    if (err == NULL) {
        return 0;
    }
    if (buf != NULL && len > 0) {
        snprintf(buf, len, "%s: %s (%d/%d)", where,
                 err->message != NULL ? err->message : "unknown error",
                 err->code, err->sub_code);
    }
    idevice_error_free(err);
    return -1;
}

static void wd_progress_noop(size_t done, size_t total, void *context) {
    (void)done;
    (void)total;
    (void)context;
}

static void wd_note(char *buf, size_t len, const char *message) {
    if (buf != NULL && len > 0) {
        snprintf(buf, len, "%s", message);
    }
}

// MARK: - lifecycle

WanderingDevice *wd_create(void) {
    WanderingDevice *dev = calloc(1, sizeof(WanderingDevice));
    return dev;
}

void wd_disconnect(WanderingDevice *dev) {
    if (dev == NULL) {
        return;
    }
    if (dev->sim != NULL) {
        location_simulation_free(dev->sim);
        dev->sim = NULL;
    }
    if (dev->mounter != NULL) {
        image_mounter_free(dev->mounter);
        dev->mounter = NULL;
    }
    if (dev->server != NULL) {
        remote_server_free(dev->server);
        dev->server = NULL;
    }
    if (dev->handshake != NULL) {
        rsd_handshake_free(dev->handshake);
        dev->handshake = NULL;
    }
    if (dev->adapter != NULL) {
        adapter_free(dev->adapter);
        dev->adapter = NULL;
    }
    if (dev->pairing != NULL) {
        rp_pairing_file_free(dev->pairing);
        dev->pairing = NULL;
    }
    dev->connected = 0;
}

void wd_free(WanderingDevice *dev) {
    if (dev == NULL) {
        return;
    }
    wd_disconnect(dev);
    free(dev);
}

// MARK: - connect

int wd_connect(WanderingDevice *dev, const char *ip, uint16_t port,
               const char *pairing_path, char *err, size_t err_len) {
    if (dev == NULL || ip == NULL || pairing_path == NULL) {
        wd_note(err, err_len, "invalid arguments");
        return -1;
    }
    if (dev->connected) {
        return 0;
    }

    snprintf(dev->ip, sizeof(dev->ip), "%s", ip);
    dev->port = port;

    struct IdeviceFfiError *e = rp_pairing_file_read(pairing_path, &dev->pairing);
    if (e != NULL || dev->pairing == NULL) {
        if (e == NULL) {
            wd_note(err, err_len, "pairing file could not be read");
        }
        return wd_fail(e, err, err_len, "read pairing file");
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        wd_note(err, err_len, "bad tunnel address");
        wd_disconnect(dev);
        return -1;
    }

    e = tunnel_create_rppairing((const idevice_sockaddr *)&addr, (idevice_socklen_t)sizeof(addr),
                                "Wandering", dev->pairing, wd_pin_callback, NULL,
                                &dev->adapter, &dev->handshake);
    if (wd_fail(e, err, err_len, "open remote pairing tunnel") != 0) {
        wd_disconnect(dev);
        return -1;
    }

    // A first-time pair-setup rewrites the pairing file in place; without saving it the
    // next launch would have to ask for the PIN again.
    struct IdeviceFfiError *save_err = rp_pairing_file_write(dev->pairing, pairing_path);
    if (save_err != NULL) {
        wd_note(err, err_len, "paired, but the updated pairing file could not be saved");
        idevice_error_free(save_err);
    }

    e = remote_server_connect_rsd(dev->adapter, dev->handshake, &dev->server);
    if (wd_fail(e, err, err_len, "connect remote server") != 0) {
        wd_disconnect(dev);
        return -1;
    }

    e = location_simulation_new(dev->server, &dev->sim);
    if (wd_fail(e, err, err_len, "open location simulation") != 0) {
        wd_disconnect(dev);
        return -1;
    }

    dev->connected = 1;
    return 0;
}

/// Creates a brand-new RP pairing file (fresh Ed25519 keys, no pairing yet).
///
/// Why: a file whose keys were never confirmed by this device fails pair-verify, and
/// remotepairingd answers that with a reset rather than a prompt. Generating our own
/// forces the pair-setup half of the handshake, which is the only way to get a record
/// the device actually accepts.
int wd_generate_pairing_file(const char *path, char *err, size_t err_len) {
    if (path == NULL) {
        wd_note(err, err_len, "invalid arguments");
        return -1;
    }
    struct RpPairingFileHandle *pairing = NULL;
    struct IdeviceFfiError *e = rp_pairing_file_generate("Wandering", &pairing);
    if (wd_fail(e, err, err_len, "generate pairing file") != 0 || pairing == NULL) {
        if (e == NULL) {
            wd_note(err, err_len, "generator returned no file");
        }
        return -1;
    }
    e = rp_pairing_file_write(pairing, path);
    rp_pairing_file_free(pairing);
    if (wd_fail(e, err, err_len, "write generated pairing file") != 0) {
        return -1;
    }
    return 0;
}

int wd_persist_pairing_file(WanderingDevice *dev, const char *path,
                            char *err, size_t err_len) {
    if (dev == NULL || dev->pairing == NULL || path == NULL) {
        wd_note(err, err_len, "no pairing file to persist");
        return -1;
    }
    struct IdeviceFfiError *e = rp_pairing_file_write(dev->pairing, path);
    return wd_fail(e, err, err_len, "persist pairing file");
}

// MARK: - developer services

static int wd_lockdown(WanderingDevice *dev, struct LockdowndClientHandle **out,
                       char *err, size_t err_len) {
    struct IdeviceFfiError *e = lockdownd_connect_rsd(dev->adapter, dev->handshake, out);
    if (wd_fail(e, err, err_len, "connect lockdownd") != 0) {
        return -1;
    }
    return 0;
}

int wd_developer_mode(WanderingDevice *dev, int *enabled, char *err, size_t err_len) {
    if (dev == NULL || !dev->connected) {
        wd_note(err, err_len, "not connected");
        return -1;
    }
    if (dev->mounter == NULL) {
        struct IdeviceFfiError *e =
            image_mounter_connect_rsd(dev->adapter, dev->handshake, &dev->mounter);
        if (wd_fail(e, err, err_len, "connect image mounter") != 0) {
            return -1;
        }
    }
    int status = 0;
    struct IdeviceFfiError *e = image_mounter_query_developer_mode_status(dev->mounter, &status);
    if (wd_fail(e, err, err_len, "query developer mode") != 0) {
        return -1;
    }
    if (enabled != NULL) {
        *enabled = status > 0 ? 1 : 0;
    }
    return 0;
}

int wd_unique_chip_id(WanderingDevice *dev, uint64_t *chip_id, char *err, size_t err_len) {
    if (dev == NULL || !dev->connected) {
        wd_note(err, err_len, "not connected");
        return -1;
    }
    struct LockdowndClientHandle *client = NULL;
    if (wd_lockdown(dev, &client, err, err_len) != 0) {
        return -1;
    }

    plist_t value = NULL;
    struct IdeviceFfiError *e = lockdownd_get_value(client, "UniqueChipID", NULL, &value);
    lockdownd_client_free(client);
    if (wd_fail(e, err, err_len, "read UniqueChipID") != 0) {
        return -1;
    }
    if (value == NULL) {
        wd_note(err, err_len, "UniqueChipID missing");
        return -1;
    }

    uint64_t out = 0;
    plist_get_uint_val(value, &out);
    plist_free(value);
    if (chip_id != NULL) {
        *chip_id = out;
    }
    return 0;
}

int wd_product_version(WanderingDevice *dev, char *out, size_t out_len,
                       char *err, size_t err_len) {
    if (dev == NULL || !dev->connected) {
        wd_note(err, err_len, "not connected");
        return -1;
    }
    struct LockdowndClientHandle *client = NULL;
    if (wd_lockdown(dev, &client, err, err_len) != 0) {
        return -1;
    }

    plist_t value = NULL;
    struct IdeviceFfiError *e = lockdownd_get_value(client, "ProductVersion", NULL, &value);
    lockdownd_client_free(client);
    if (wd_fail(e, err, err_len, "read ProductVersion") != 0) {
        return -1;
    }
    if (value == NULL) {
        wd_note(err, err_len, "ProductVersion missing");
        return -1;
    }

    char *text = NULL;
    plist_get_string_val(value, &text);
    plist_free(value);
    if (text == NULL) {
        wd_note(err, err_len, "ProductVersion unreadable");
        return -1;
    }
    snprintf(out, out_len, "%s", text);
    free(text);
    return 0;
}

int wd_mount_personalized(WanderingDevice *dev,
                          const uint8_t *image, size_t image_len,
                          const uint8_t *trust_cache, size_t trust_cache_len,
                          const uint8_t *build_manifest, size_t build_manifest_len,
                          uint64_t chip_id, char *err, size_t err_len) {
    if (dev == NULL || !dev->connected) {
        wd_note(err, err_len, "not connected");
        return -1;
    }
    if (image == NULL || image_len == 0 || trust_cache == NULL || build_manifest == NULL) {
        wd_note(err, err_len, "incomplete disk image payload");
        return -1;
    }
    if (dev->mounter == NULL) {
        struct IdeviceFfiError *e =
            image_mounter_connect_rsd(dev->adapter, dev->handshake, &dev->mounter);
        if (wd_fail(e, err, err_len, "connect image mounter") != 0) {
            return -1;
        }
    }

    struct IdeviceFfiError *e = image_mounter_mount_personalized_with_callback_rsd(
        dev->mounter, dev->adapter, dev->handshake,
        image, image_len, trust_cache, trust_cache_len,
        build_manifest, build_manifest_len,
        NULL, chip_id, wd_progress_noop, NULL);
    if (e != NULL) {
        // The mounter reconnects its own socket mid-mount; a failure can leave it
        // closed, so drop it and let the next attempt build a fresh one.
        image_mounter_free(dev->mounter);
        dev->mounter = NULL;
    }
    return wd_fail(e, err, err_len, "mount personalised disk image");
}

// MARK: - location

int wd_set_location(WanderingDevice *dev, double latitude, double longitude,
                    char *err, size_t err_len) {
    if (dev == NULL || dev->sim == NULL) {
        wd_note(err, err_len, "location service not open");
        return -1;
    }
    struct IdeviceFfiError *e = location_simulation_set(dev->sim, latitude, longitude);
    return wd_fail(e, err, err_len, "set location");
}

int wd_clear_location(WanderingDevice *dev, char *err, size_t err_len) {
    if (dev == NULL || dev->sim == NULL) {
        wd_note(err, err_len, "location service not open");
        return -1;
    }
    struct IdeviceFfiError *e = location_simulation_clear(dev->sim);
    return wd_fail(e, err, err_len, "clear location");
}
