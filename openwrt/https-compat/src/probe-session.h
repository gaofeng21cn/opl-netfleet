#ifndef NETFLEET_PROBE_SESSION_H
#define NETFLEET_PROBE_SESSION_H
#include <stdint.h>
struct probe_request { uint64_t serial; };
struct probe_proof { uint32_t ok, duration_ms; char reason[64]; };
struct probe_reply { uint64_t serial; struct probe_proof ipv4, ipv6; };
#endif
