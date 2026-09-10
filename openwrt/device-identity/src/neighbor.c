#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_LINKS 16
#define MAX_TARGETS 64
#define MAX_RESULTS 256
struct link { int fd; unsigned int index; uint8_t mac[6]; struct in6_addr source; };
struct result { struct in6_addr ip; uint8_t mac[6]; };
static unsigned int sum(const uint8_t *p, size_t n) {
    unsigned int s = 0;
    while (n > 1) { s += ((unsigned int)p[0] << 8) | p[1]; p += 2; n -= 2; }
    return s + (n ? (unsigned int)*p << 8 : 0);
}
static uint16_t checksum(const uint8_t *src, const uint8_t *dst, const uint8_t *body, size_t n) {
    unsigned int s = sum(src, 16) + sum(dst, 16) + sum(body, n) + n + 58;
    while (s >> 16) s = (s & 65535) + (s >> 16);
    return (uint16_t)~s;
}
static int parse_mac(const char *s, uint8_t *out) {
    unsigned int v[6]; int used = 0;
    if (strlen(s) != 17 || sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x%n", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &used) != 6 || used != 17) return 0;
    unsigned int any = 0;
    for (size_t i = 0; i < 6; i++) { out[i] = v[i]; any |= v[i]; }
    return any && !(out[0] & 1);
}
static void solicitation(uint8_t p[86], const struct link *l, const struct in6_addr *target) {
    memset(p, 0, 86);
    p[0] = p[1] = 0x33; p[2] = 0xff; memcpy(p + 3, target->s6_addr + 13, 3);
    memcpy(p + 6, l->mac, 6); p[12] = 0x86; p[13] = 0xdd;
    p[14] = 0x60; p[19] = 32; p[20] = 58; p[21] = 255;
    memcpy(p + 22, &l->source, 16);
    p[38] = 0xff; p[39] = 2; p[49] = 1; p[50] = 0xff; memcpy(p + 51, target->s6_addr + 13, 3);
    p[54] = 135; memcpy(p + 62, target, 16); p[78] = p[79] = 1; memcpy(p + 80, l->mac, 6);
    uint16_t c = checksum(p + 22, p + 38, p + 54, 32); p[56] = c >> 8; p[57] = c;
}
static int advertisement(const uint8_t *p, size_t n, const struct link *l,
                         const struct in6_addr *targets, size_t count, struct result *out) {
    if (n < 86 || memcmp(p, l->mac, 6) || p[6] & 1 || !memcmp(p + 6, "\0\0\0\0\0\0", 6) ||
        p[12] != 0x86 || p[13] != 0xdd || p[14] >> 4 != 6 || p[20] != 58 || p[21] != 255 ||
        memcmp(p + 38, &l->source, 16)) return 0;
    size_t length = ((size_t)p[18] << 8) | p[19];
    struct in6_addr src; memcpy(&src, p + 22, 16);
    if (IN6_IS_ADDR_UNSPECIFIED(&src) || IN6_IS_ADDR_MULTICAST(&src) || length < 32 || length > n - 54 ||
        p[54] != 136 || p[55] || (p[58] & 0xc0) != 0x40 || checksum(p + 22, p + 38, p + 54, length)) return 0;
    size_t i; for (i = 0; i < count && memcmp(p + 62, &targets[i], 16); i++);
    if (i == count) return 0;
    size_t links = 0;
    for (size_t offset = 78; offset < 54 + length;) {
        if (offset + 2 > 54 + length || p[offset + 1] == 0) return 0;
        size_t size = (size_t)p[offset + 1] * 8;
        if (size > 54 + length - offset) return 0;
        if (p[offset] == 2) { if (size != 8 || memcmp(p + offset + 2, p + 6, 6)) return 0; links++; }
        offset += size;
    }
    if (links != 1) return 0;
    memcpy(&out->ip, p + 62, 16); memcpy(out->mac, p + 6, 6); return 1;
}
static int64_t millis(void) {
    struct timespec ts; if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
int main(int argc, char **argv) {
    if (getuid() != 0 || geteuid() != 0) return 2;
    struct link links[MAX_LINKS]; struct in6_addr targets[MAX_TARGETS];
    struct result results[MAX_RESULTS]; struct pollfd fds[MAX_LINKS];
    size_t nl = 0, nt = 0, nr = 0, packets = 0; int code = 1, pos = 1;
    memset(links, 0, sizeof(links)); for (size_t i = 0; i < MAX_LINKS; i++) links[i].fd = -1;
    while (pos < argc && strcmp(argv[pos], "--")) {
        if (nl == MAX_LINKS || pos + 2 >= argc || !strlen(argv[pos]) || strlen(argv[pos]) >= IFNAMSIZ ||
            strspn(argv[pos], "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-") != strlen(argv[pos]) ||
            !(links[nl].index = if_nametoindex(argv[pos])) || inet_pton(AF_INET6, argv[pos+1], &links[nl].source) != 1 ||
            !IN6_IS_ADDR_LINKLOCAL(&links[nl].source) || !parse_mac(argv[pos+2], links[nl].mac)) goto done;
        nl++; pos += 3;
    }
    if (!nl || pos >= argc) goto done;
    while (++pos < argc) {
        if (nt == MAX_TARGETS || inet_pton(AF_INET6, argv[pos], &targets[nt]) != 1 ||
            IN6_IS_ADDR_UNSPECIFIED(&targets[nt]) || IN6_IS_ADDR_LOOPBACK(&targets[nt]) ||
            IN6_IS_ADDR_MULTICAST(&targets[nt]) || IN6_IS_ADDR_LINKLOCAL(&targets[nt]) || IN6_IS_ADDR_V4MAPPED(&targets[nt])) goto done;
        nt++;
    }
    if (!nt) { code = 0; goto done; }
    const int64_t began = millis(), deadline = began + 350;
    if (began < 0) goto done;
    for (size_t i = 0; i < nl; i++) {
        links[i].fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, htons(ETH_P_IPV6));
        struct sockaddr_ll address = {.sll_family=AF_PACKET, .sll_protocol=htons(ETH_P_IPV6), .sll_ifindex=(int)links[i].index};
        if (links[i].fd < 0 || bind(links[i].fd, (struct sockaddr *)&address, sizeof(address))) goto done;
        fds[i] = (struct pollfd){.fd=links[i].fd, .events=POLLIN};
        for (size_t j = 0; j < nt; j++) {
            if (millis() >= deadline) goto done;
            uint8_t p[86]; solicitation(p, &links[i], &targets[j]);
            if (send(links[i].fd, p, sizeof(p), 0) < 0 && errno != EAGAIN && errno != EWOULDBLOCK) goto done;
        }
    }
    while (millis() < deadline) {
        int64_t remaining = deadline - millis();
        if (remaining <= 0) break;
        int rc = poll(fds, nl, (int)remaining);
        if (rc < 0) { if (errno == EINTR) continue; goto done; }
        if (!rc) break;
        for (size_t i = 0; i < nl; i++) {
            if (fds[i].revents & (POLLERR | POLLHUP | POLLNVAL)) goto done;
            if (!(fds[i].revents & POLLIN)) continue;
            uint8_t packet[65536]; ssize_t length = recv(links[i].fd, packet, sizeof(packet), 0);
            if (length < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) continue; goto done; }
            if (++packets > 4096) goto done;
            struct result result;
            if (advertisement(packet, length, &links[i], targets, nt, &result)) {
                if (nr == MAX_RESULTS) goto done;
                results[nr++] = result;
            }
        }
    }
    code = 0;
done:
    for (size_t i = 0; i < nl; i++) if (links[i].fd >= 0) close(links[i].fd);
    if (code) { fputs("local_observation_failed\n", stderr); return code; }
    putchar('[');
    for (size_t i = 0; i < nr; i++) {
        char ip[INET6_ADDRSTRLEN]; inet_ntop(AF_INET6, &results[i].ip, ip, sizeof(ip));
        printf("%s[\"%s\",\"%02x:%02x:%02x:%02x:%02x:%02x\"]", i ? "," : "", ip,
            results[i].mac[0],results[i].mac[1],results[i].mac[2],results[i].mac[3],results[i].mac[4],results[i].mac[5]);
    }
    puts("]"); return ferror(stdout) ? 1 : 0;
}
