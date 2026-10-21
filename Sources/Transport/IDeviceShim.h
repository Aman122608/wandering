//
//  IDeviceShim.h
//  Wandering
//
//  A deliberately small C surface over the idevice FFI.
//
//  Why a shim instead of calling the FFI from Swift directly: the FFI uses
//  opaque Rust handles and a sockaddr pointer, so every call site in Swift would
//  need pointer gymnastics and error-struct cleanup. Here it is one struct, one
//  error string, and int returns.
//

#ifndef IDEVICE_SHIM_H
#define IDEVICE_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct WanderingDevice WanderingDevice;

/// Allocate a device handle. Never returns NULL unless memory is exhausted.
WanderingDevice *wd_create(void);

/// Free the handle and any open services. Safe to call twice.
void wd_free(WanderingDevice *dev);

/// Open the tunnel, the remote server and the location service.
/// Returns 0 on success; on failure writes a message into `err` and returns < 0.
int wd_connect(WanderingDevice *dev, const char *ip, uint16_t port,
               const char *pairing_path, char *err, size_t err_len);

void wd_disconnect(WanderingDevice *dev);

/// Connects, says nothing, and reports what the peer does. Diagnostic for telling a
/// pairing rejection apart from a broken tunnel.
int wd_probe_tunnel(const char *ip, uint16_t port, char *out, size_t out_len);

/// Called (from a background thread) when the device wants a pairing PIN.
/// The connect call blocks until `wd_submit_pin` or `wd_cancel_pin` is invoked.
typedef void (*wd_pin_request_fn)(void *context);

/// Install the callback that asks the UI for a PIN. Call once at launch.
void wd_set_pin_provider(wd_pin_request_fn request, void *context);

/// Hand the PIN to the waiting handshake. Returns 0 when accepted.
int wd_submit_pin(const char *pin);

/// Abandon a waiting PIN request.
void wd_cancel_pin(void);

/// Shows the 6-digit code the device expects, so the user can type it there.
typedef void (*wd_pin_display_fn)(const char *pin, void *context);
void wd_set_pin_display(wd_pin_display_fn fn, void *context);

/// Advertises this app as a pairable host and waits for the iPhone to pair with it
/// (Settings → Privacy & Security → Developer Mode → "Pair with ..."). Blocking;
/// writes the resulting record to `pairing_path` on success.
int wd_pair_host(const char *name, const char *pairing_path, char *err, size_t err_len);

/// Writes a fresh RP pairing file (new keys, never paired) to `path`.
int wd_generate_pairing_file(const char *path, char *err, size_t err_len);

/// True while a handshake is blocked waiting for a PIN.
int wd_pin_pending(void);

/// 1 = developer mode enabled, 0 = disabled, < 0 = error.
int wd_developer_mode(WanderingDevice *dev, int *enabled, char *err, size_t err_len);

/// Reads `UniqueChipID` from lockdownd (needed to personalise a disk image).
int wd_unique_chip_id(WanderingDevice *dev, uint64_t *chip_id, char *err, size_t err_len);

/// Reads `ProductVersion` from lockdownd, e.g. "26.5".
int wd_product_version(WanderingDevice *dev, char *out, size_t out_len,
                       char *err, size_t err_len);

/// Mount a personalised developer disk image. All buffers are raw file bytes.
int wd_mount_personalized(WanderingDevice *dev,
                          const uint8_t *image, size_t image_len,
                          const uint8_t *trust_cache, size_t trust_cache_len,
                          const uint8_t *build_manifest, size_t build_manifest_len,
                          uint64_t chip_id, char *err, size_t err_len);

/// Persist the pairing file after a successful connect. The first tunnel can add
/// `alt_irk` to it in place; without writing it back the next launch re-runs
/// pair-setup and the device prompts again.
int wd_persist_pairing_file(WanderingDevice *dev, const char *path,
                            char *err, size_t err_len);

/// Set / clear the simulated location.
int wd_set_location(WanderingDevice *dev, double latitude, double longitude,
                    char *err, size_t err_len);
int wd_clear_location(WanderingDevice *dev, char *err, size_t err_len);

#endif /* IDEVICE_SHIM_H */
