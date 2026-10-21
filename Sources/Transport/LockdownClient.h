//
//  LockdownClient.h
//  Wandering
//
//  A tiny lockdownd client: enough to start `com.apple.dt.simulatelocation` and speak
//  its four-message protocol. Written by hand because the vendored idevice FFI has no
//  lockdown-over-TCP entry point, and because this path needs no pairing at all — which
//  is exactly what the remote-pairing tunnel cannot give us here.
//

#ifndef LOCKDOWN_CLIENT_H
#define LOCKDOWN_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Sends one request plist and reports the reply, or the reason there wasn't one.
/// `reply` receives the raw plist bytes (truncated to `reply_len`).
int wd_lk_request(const char *ip, uint16_t port,
                  const char *request_xml,
                  char *reply, size_t reply_len,
                  char *err, size_t err_len);

/// Starts `com.apple.dt.simulatelocation` and reports its TLS flag and port.
int wd_lk_start_simulate(const char *ip, uint16_t port,
                         uint16_t *service_port, bool *needs_tls,
                         char *err, size_t err_len);

/// Sets the simulated location through a fresh service connection.
int wd_lk_set_location(const char *ip, uint16_t port,
                       double latitude, double longitude,
                       uint16_t *service_port, char *err, size_t err_len);

/// Clears the simulated location (restores the real one).
int wd_lk_clear_location(const char *ip, uint16_t port,
                         uint16_t *service_port, char *err, size_t err_len);

#endif /* LOCKDOWN_CLIENT_H */
