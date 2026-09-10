/* Probe per-socket port ranges; never modifies host sysctls. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#ifndef IP_LOCAL_PORT_RANGE
#define IP_LOCAL_PORT_RANGE 51
#endif
static int port(const char *text) {
    char *end;
    errno = 0;
    long value = strtol(text, &end, 10);
    return !errno && text[0] && !*end && value > 0 && value <= 65535 ? (int)value : -1;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int lower = port(argv[1]), upper = port(argv[2]);
    if (lower < 0 || upper <= lower) return 2;
    uint32_t requested = ((uint32_t)upper << 16) | (uint32_t)lower;
    const int families[] = {AF_INET, AF_INET6};
    for (unsigned i = 0; i < 2; i++) {
        int fd = socket(families[i], SOCK_STREAM | SOCK_CLOEXEC, 0);
        uint32_t observed = 0;
        socklen_t size = sizeof(observed);
        if (fd < 0) return 3;
        int failed = setsockopt(fd, IPPROTO_IP, IP_LOCAL_PORT_RANGE, &requested, sizeof(requested)) ||
            getsockopt(fd, IPPROTO_IP, IP_LOCAL_PORT_RANGE, &observed, &size) ||
            size != sizeof(observed) || observed != requested;
        close(fd);
        if (failed) return 3;
    }
    puts("{\"ok\":true}");
    return 0;
}
