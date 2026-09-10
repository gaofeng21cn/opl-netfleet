#define main neighbor_program_main
#include "../openwrt/device-identity/src/neighbor.c"
#undef main
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    struct link link = {0}; struct in6_addr target; struct result result;
    inet_pton(AF_INET6,"fe80::fe",&link.source); inet_pton(AF_INET6,"2001:db8::1234",&target);
    parse_mac("02:00:00:00:00:fe",link.mac);
    if (!strcmp(argv[1],"solicitation")) {
        uint8_t packet[86]; solicitation(packet,&link,&target);
        FILE *out=fopen(argv[2],"wb"); if (!out) return 1;
        return fwrite(packet,1,sizeof(packet),out) != sizeof(packet) || fclose(out);
    }
    FILE *in=fopen(argv[2],"rb"); if (!in) return 1;
    uint8_t packet[65536]; size_t n=fread(packet,1,sizeof(packet),in); fclose(in);
    printf("%d\n",advertisement(packet,n,&link,&target,1,&result)); return 0;
}
