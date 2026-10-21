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
                                "Wandering", dev->pairing, NULL, NULL,
                                &dev->adapter, &dev->handshake);
    if (wd_fail(e, err, err_len, "open remote pairing tunnel") != 0) {
        wd_disconnect(dev);
        return -1;
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
        NULL, chip_id, NULL, NULL);
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
