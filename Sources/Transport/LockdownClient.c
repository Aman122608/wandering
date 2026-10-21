//
//  LockdownClient.c
//  Wandering
//
//  lockdownd over TCP, plus the `com.apple.dt.simulatelocation` message format:
//
//      set:   uint32 0 | uint32 len + "lat" | uint32 len + "lon"
//      clear: uint32 1
//
//  All integers big-endian, numbers sent as ASCII. Matches pymobiledevice3's
//  DtSimulateLocation, which is the reference implementation for this service.
//

#include "LockdownClient.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static void lk_note(char *buf, size_t len, const char *message) {
    if (buf != NULL && len > 0) {
        snprintf(buf, len, "%s", message);
    }
}

static int lk_connect(const char *ip, uint16_t port, int timeout_s, char *err, size_t err_len) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        lk_note(err, err_len, "bad address");
        return -1;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        lk_note(err, err_len, "socket() failed");
        return -1;
    }
    struct timeval tv = { .tv_sec = timeout_s, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        snprintf(err, err_len, "connect to %s:%u failed: %s", ip, port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int lk_send_all(int fd, const void *buf, size_t len) {
    const unsigned char *cursor = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, cursor + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int lk_recv_all(int fd, void *buf, size_t len) {
    unsigned char *cursor = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, cursor + got, len - got, 0);
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

/// lockdownd frames: 4-byte big-endian length, then the plist.
static int lk_send_framed(int fd, const char *payload) {
    size_t len = strlen(payload);
    unsigned char header[4] = {
        (unsigned char)((len >> 24) & 0xff),
        (unsigned char)((len >> 16) & 0xff),
        (unsigned char)((len >> 8) & 0xff),
        (unsigned char)(len & 0xff)
    };
    if (lk_send_all(fd, header, 4) != 0) return -1;
    return lk_send_all(fd, payload, len);
}

static int lk_recv_framed(int fd, char *out, size_t out_len) {
    unsigned char header[4];
    if (lk_recv_all(fd, header, 4) != 0) return -1;
    size_t len = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
               | ((size_t)header[2] << 8) | (size_t)header[3];
    if (len == 0 || len > 262144) return -1;

    char *buffer = calloc(1, len + 1);
    if (buffer == NULL) return -1;
    if (lk_recv_all(fd, buffer, len) != 0) {
        free(buffer);
        return -1;
    }
    snprintf(out, out_len, "%s", buffer);
    free(buffer);
    return (int)len;
}

static const char *lk_header =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>"
    "<key>Label</key><string>Wandering</string>";

int wd_lk_request(const char *ip, uint16_t port, const char *request_xml,
                  char *reply, size_t reply_len, char *err, size_t err_len) {
    if (ip == NULL || request_xml == NULL || reply == NULL) {
        lk_note(err, err_len, "invalid arguments");
        return -1;
    }
    reply[0] = 0;

    int fd = lk_connect(ip, port, 3, err, err_len);
    if (fd < 0) return -1;

    char payload[1024];
    snprintf(payload, sizeof(payload), "%s%s</dict></plist>", lk_header, request_xml);

    if (lk_send_framed(fd, payload) != 0) {
        lk_note(err, err_len, "request could not be sent");
        close(fd);
        return -1;
    }
    int got = lk_recv_framed(fd, reply, reply_len);
    close(fd);
    if (got < 0) {
        lk_note(err, err_len, "connected, but lockdownd closed without answering");
        return -1;
    }
    return 0;
}

/// Reads the integer that follows `key` in a plist reply.
static int lk_integer_after(const char *plist, const char *key, long *out) {
    char needle[128];
    snprintf(needle, sizeof(needle), "<key>%s</key>", key);
    const char *at = strstr(plist, needle);
    if (at == NULL) return -1;
    at = strstr(at, "<integer>");
    if (at == NULL) return -1;
    at += strlen("<integer>");
    *out = strtol(at, NULL, 10);
    return 0;
}

/// Reads the error message a failed request carries, if any.
static void lk_error_text(const char *plist, char *err, size_t err_len) {
    const char *at = strstr(plist, "<key>Error</key>");
    if (at == NULL) {
        lk_note(err, err_len, "lockdownd refused the request");
        return;
    }
    at = strstr(at, "<string>");
    if (at == NULL) {
        lk_note(err, err_len, "lockdownd refused the request");
        return;
    }
    at += strlen("<string>");
    const char *end = strstr(at, "</string>");
    if (end == NULL) {
        lk_note(err, err_len, "lockdownd refused the request");
        return;
    }
    snprintf(err, err_len, "lockdownd: %.*s", (int)(end - at), at);
}

int wd_lk_start_simulate(const char *ip, uint16_t port,
                         uint16_t *service_port, bool *needs_tls,
                         char *err, size_t err_len) {
    char reply[8192];
    const char *request =
        "<key>Request</key><string>StartService</string>"
        "<key>Service</key><string>com.apple.dt.simulatelocation</string>";

    if (wd_lk_request(ip, port, request, reply, sizeof(reply), err, err_len) != 0) {
        return -1;
    }
    if (strstr(reply, "<key>Error</key>") != NULL) {
        lk_error_text(reply, err, err_len);
        return -1;
    }

    long value = 0;
    if (lk_integer_after(reply, "Port", &value) != 0 || value <= 0 || value > 65535) {
        lk_note(err, err_len, "StartService reply had no usable Port");
        return -1;
    }
    if (service_port != NULL) *service_port = (uint16_t)value;
    if (needs_tls != NULL) *needs_tls = strstr(reply, "<key>EnableServiceSSL</key><true/>") != NULL;
    return 0;
}

static int lk_send_u32(int fd, uint32_t value) {
    unsigned char bytes[4] = {
        (unsigned char)((value >> 24) & 0xff),
        (unsigned char)((value >> 16) & 0xff),
        (unsigned char)((value >> 8) & 0xff),
        (unsigned char)(value & 0xff)
    };
    return lk_send_all(fd, bytes, 4);
}

int wd_lk_set_location(const char *ip, uint16_t port,
                       double latitude, double longitude,
                       uint16_t *service_port, char *err, size_t err_len) {
    uint16_t started = 0;
    bool tls = false;
    if (wd_lk_start_simulate(ip, port, &started, &tls, err, err_len) != 0) {
        return -1;
    }
    if (service_port != NULL) *service_port = started;
    if (tls) {
        lk_note(err, err_len, "service requires TLS on its port — not implemented");
        return -1;
    }

    int fd = lk_connect(ip, started, 3, err, err_len);
    if (fd < 0) return -1;

    char lat[32], lon[32];
    snprintf(lat, sizeof(lat), "%f", latitude);
    snprintf(lon, sizeof(lon), "%f", longitude);
    size_t lat_len = strlen(lat), lon_len = strlen(lon);

    int rc = 0;
    if (lk_send_u32(fd, 0) != 0
        || lk_send_u32(fd, (uint32_t)lat_len) != 0 || lk_send_all(fd, lat, lat_len) != 0
        || lk_send_u32(fd, (uint32_t)lon_len) != 0 || lk_send_all(fd, lon, lon_len) != 0) {
        lk_note(err, err_len, "location message could not be sent");
        rc = -1;
    }
    close(fd);
    return rc;
}

int wd_lk_clear_location(const char *ip, uint16_t port,
                         uint16_t *service_port, char *err, size_t err_len) {
    uint16_t started = 0;
    bool tls = false;
    if (wd_lk_start_simulate(ip, port, &started, &tls, err, err_len) != 0) {
        return -1;
    }
    if (service_port != NULL) *service_port = started;
    if (tls) {
        lk_note(err, err_len, "service requires TLS on its port — not implemented");
        return -1;
    }

    int fd = lk_connect(ip, started, 3, err, err_len);
    if (fd < 0) return -1;
    int rc = lk_send_u32(fd, 1) == 0 ? 0 : -1;
    if (rc != 0) lk_note(err, err_len, "clear message could not be sent");
    close(fd);
    return rc;
}
