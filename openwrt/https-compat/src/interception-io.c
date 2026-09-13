/* Fixed gateway observations and private lease I/O. Policy stays in ucode. */
#define _GNU_SOURCE
#include <ucode/module.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <json-c/json.h>
#include <time.h>
#include <unistd.h>
#include <linux/netfilter.h>
#include <linux/netfilter/nf_tables.h>
#include <linux/netfilter/nfnetlink.h>
#include <linux/rtnetlink.h>
#include <linux/fib_rules.h>
#include <libmnl/libmnl.h>
#include <libnftnl/table.h>
#include <libnftnl/set.h>
#include <libnftnl/rule.h>
#include <libnftnl/expr.h>
#include <libnftnl/udata.h>
#include <libnftnl/gen.h>

#define PRIVATE_TABLE "netfleet_compat"
#define LIMIT 4096
#define BUFFER 65536
#define DEADLINE_MS 400
struct connection { int fd; uint32_t port, seq; int64_t deadline; };
static int64_t now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static uc_value_t *failure(uc_vm_t *vm, const char *reason) {
    uc_vm_raise_exception(vm, EXCEPTION_RUNTIME, "%s", reason); return NULL;
}
static int wait_io(struct connection *c, short events) {
    for (;;) {
        int64_t remaining = c->deadline - now_ms();
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd p = { .fd = c->fd, .events = events };
        int rc = poll(&p, 1, (int)remaining);
        if (rc < 0 && errno == EINTR) continue;
        if (rc > 0 && (p.revents & events)) return 0;
        errno = rc == 0 ? ETIMEDOUT : EIO; return -1;
    }
}
static int open_netlink(struct connection *c, int protocol) {
    memset(c, 0, sizeof(*c)); c->fd = -1;
    c->deadline = now_ms() + DEADLINE_MS;
    c->seq = 1;
    c->fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, protocol);
    if (c->fd < 0) return -1;
    struct sockaddr_nl local = { .nl_family = AF_NETLINK };
    socklen_t size = sizeof(local);
    int buffer = 1024 * 1024;
    setsockopt(c->fd, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    if (bind(c->fd, (struct sockaddr *)&local, sizeof(local)) ||
        getsockname(c->fd, (struct sockaddr *)&local, &size)) {
        close(c->fd); c->fd = -1; return -1;
    }
    c->port = local.nl_pid; return 0;
}
static int transmit(struct connection *c, const void *data, size_t size) {
    struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
    for (;;) {
        ssize_t n = sendto(c->fd, data, size, MSG_NOSIGNAL, (struct sockaddr *)&kernel, sizeof(kernel));
        if (n == (ssize_t)size) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN && !wait_io(c, POLLOUT)) continue;
        return -1;
    }
}
static ssize_t receive(struct connection *c, void *data, size_t size) {
    for (;;) {
        if (wait_io(c, POLLIN)) return -1;
        struct sockaddr_nl sender = {0};
        struct iovec iov = { .iov_base = data, .iov_len = size };
        struct msghdr msg = { .msg_name = &sender, .msg_namelen = sizeof(sender), .msg_iov = &iov, .msg_iovlen = 1 };
        ssize_t n = recvmsg(c->fd, &msg, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0 || sender.nl_pid || sender.nl_family != AF_NETLINK || (msg.msg_flags & MSG_TRUNC)) {
            errno = EPROTO; return -1;
        }
        return n;
    }
}
typedef int (*read_cb)(const struct nlmsghdr *, void *);
static int query(struct connection *c, struct nlmsghdr *request, read_cb cb, void *arg) {
    _Alignas(struct nlmsghdr) char buffer[BUFFER]; unsigned total = 0, objects = 0;
    const uint32_t seq = request->nlmsg_seq;
    const bool dump = (request->nlmsg_flags & NLM_F_DUMP) == NLM_F_DUMP;
    if (transmit(c, request, request->nlmsg_len)) return -1;
    for (;;) {
        ssize_t received = receive(c, buffer, sizeof(buffer));
        if (received < 0) return -1;
        int valid = received;
        for (struct nlmsghdr *h = (void *)buffer; NLMSG_OK(h, (unsigned)valid); h = NLMSG_NEXT(h, valid)) {
            if(h->nlmsg_seq!=seq || h->nlmsg_pid!=c->port || (h->nlmsg_flags & NLM_F_DUMP_INTR)) {errno=EPROTO;return -1;}
        }
        if(valid) {errno=EPROTO;return -1;}
        int remaining = received;
        for (struct nlmsghdr *h = (void *)buffer; remaining > 0 && NLMSG_OK(h, (unsigned)remaining); h = NLMSG_NEXT(h, remaining)) {
            if (++total > 16384 || h->nlmsg_seq != seq || h->nlmsg_pid != c->port || (h->nlmsg_flags & NLM_F_DUMP_INTR)) { errno = EPROTO; return -1; }
            if (h->nlmsg_type == NLMSG_ERROR) {
                if (h->nlmsg_len < NLMSG_LENGTH(sizeof(struct nlmsgerr))) { errno = EPROTO; return -1; }
                int error = ((struct nlmsgerr *)NLMSG_DATA(h))->error;
                if (error) { errno = -error; return -1; }
                if (!dump) {if(!objects){errno=EPROTO;return -1;}return 0;}
            } else if (h->nlmsg_type == NLMSG_DONE) {
                if (!dump || h->nlmsg_len < NLMSG_LENGTH(sizeof(int))) { errno = EPROTO; return -1; }
                int error; memcpy(&error, NLMSG_DATA(h), sizeof(error));
                if (error) { errno = -error; return -1; }
                return 0;
            } else if (h->nlmsg_type < NLMSG_MIN_TYPE || !cb || cb(h, arg)) {
                errno = EPROTO; return -1;
            } else objects++;
        }
        if (remaining) { errno = EPROTO; return -1; }
    }
}
static bool nft_reply(const struct nlmsghdr *h, unsigned operation) {
    return h->nlmsg_type == ((NFNL_SUBSYS_NFTABLES << 8) | operation) &&
        h->nlmsg_len >= NLMSG_LENGTH(sizeof(struct nfgenmsg)) &&
        ((struct nfgenmsg *)NLMSG_DATA(h))->nfgen_family == NFPROTO_INET;
}
static int generation_cb(const struct nlmsghdr *h,void *arg) {
    /* GETGEN uses AF_UNSPEC in its response, unlike object messages. */
    if (h->nlmsg_type != ((NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWGEN)) return -1;
    struct nftnl_gen *g=nftnl_gen_alloc();if(!g)return -1;
    int rc=nftnl_gen_nlmsg_parse(h,g);
    if(!nftnl_gen_is_set(g,NFTNL_GEN_ID))rc=-1;
    if(!rc)*(uint32_t *)arg=nftnl_gen_get_u32(g,NFTNL_GEN_ID);
    nftnl_gen_free(g);return rc;
}
static int generation(struct connection *c,uint32_t *id) {
    _Alignas(struct nlmsghdr) char buffer[128];
    struct nlmsghdr *h=nftnl_nlmsg_build_hdr(buffer,NFT_MSG_GETGEN,NFPROTO_INET,NLM_F_ACK,c->seq++);
    return query(c,h,generation_cb,id);
}
struct table_info { bool exists; char signature[65]; };
static int comment_cb(const struct nftnl_udata *attr, void *arg) {
    struct table_info *info = arg;
    if (nftnl_udata_type(attr) != NFTNL_UDATA_TABLE_COMMENT) return 0;
    unsigned len = nftnl_udata_len(attr); const char *value = nftnl_udata_get(attr);
    if (len == 65 && value[64] == 0 && strspn(value, "0123456789abcdef") == 64) memcpy(info->signature, value, 65);
    return 0;
}
static int table_cb(const struct nlmsghdr *h, void *arg) {
    if (!nft_reply(h, NFT_MSG_NEWTABLE)) return -1;
    struct table_info *info = arg; struct nftnl_table *t = nftnl_table_alloc();
    if (!t) return -1;
    int rc = nftnl_table_nlmsg_parse(h, t);
    const char *name = nftnl_table_get_str(t, NFTNL_TABLE_NAME);
    if (rc || !name || strcmp(name, PRIVATE_TABLE) || nftnl_table_get_u32(t, NFTNL_TABLE_FAMILY) != NFPROTO_INET) rc = -1;
    else {
        uint32_t size = 0; const void *data = nftnl_table_get_data(t, NFTNL_TABLE_USERDATA, &size);
        info->exists = true;
        if (data && nftnl_udata_parse(data, size, comment_cb, info)) rc = -1;
    }
    nftnl_table_free(t); return rc;
}
static int read_table(struct connection *c, struct table_info *info) {
    _Alignas(struct nlmsghdr) char buffer[1024]; struct nftnl_table *t = nftnl_table_alloc();
    if (!t) return -1;
    nftnl_table_set_str(t, NFTNL_TABLE_NAME, PRIVATE_TABLE);
    struct nlmsghdr *h = nftnl_nlmsg_build_hdr(buffer, NFT_MSG_GETTABLE, NFPROTO_INET, NLM_F_ACK, c->seq++);
    nftnl_table_nlmsg_build_payload(h, t); nftnl_table_free(t);
    int rc = query(c, h, table_cb, info);
    return rc && errno == ENOENT && !info->exists ? 0 : rc;
}
struct candidate { unsigned len; unsigned char key[36], end[36]; };
static int candidate_order(const void *, const void *);
struct elements { uc_value_t *interfaces; unsigned count; unsigned keylen; const char *table, *set; struct candidate *expected; unsigned expected_count; bool *seen; };
static int element_cb(struct nftnl_set_elem *e, void *arg) {
    struct elements *result = arg; uint32_t len = 0;
    const unsigned char *key = nftnl_set_elem_get(e, NFTNL_SET_ELEM_KEY, &len);
    if (!key || len != result->keylen || (nftnl_set_elem_is_set(e, NFTNL_SET_ELEM_FLAGS) && nftnl_set_elem_get_u32(e, NFTNL_SET_ELEM_FLAGS))) return -1;
    if (result->interfaces) {
        size_t n = strnlen((const char *)key, len);
        if (n == 0 || n >= len || n > 15 || ++result->count > 16) return -1;
        for (size_t i = 0; i < n; i++) if (!strchr("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-", key[i])) return -1;
        ucv_array_push(result->interfaces, ucv_string_new_length((const char *)key, n));
    } else {
        if (!nftnl_set_elem_is_set(e, NFTNL_SET_ELEM_EXPIRATION)) return -1;
        if (!nftnl_set_elem_get_u64(e, NFTNL_SET_ELEM_EXPIRATION)) return 0;
        if (++result->count > LIMIT) return -1;
        if (nftnl_set_elem_get_u64(e,NFTNL_SET_ELEM_EXPIRATION)>10000) return -1;
        if(result->expected) {
            uint32_t endlen=0;const void *end=nftnl_set_elem_get(e,NFTNL_SET_ELEM_KEY_END,&endlen);
            if(!end){end=key;endlen=len;}
            if(endlen!=len)return -1;
            struct candidate needle={.len=len};
            memcpy(needle.key,key,len);memcpy(needle.end,end,len);
            struct candidate *found=bsearch(&needle,result->expected,result->expected_count,
                sizeof(*result->expected),candidate_order);
            if(!found)return -1;
            unsigned index=found-result->expected;
            if(result->seen[index])return -1;
            result->seen[index]=true;
        }
    }
    return 0;
}
static int elements_cb(const struct nlmsghdr *h, void *arg) {
    if (!nft_reply(h, NFT_MSG_NEWSETELEM)) return -1;
    struct elements *result = arg; struct nftnl_set *set = nftnl_set_alloc();
    if (!set) return -1;
    int rc = nftnl_set_elems_nlmsg_parse(h, set);
    const char *table = nftnl_set_get_str(set, NFTNL_SET_TABLE), *name = nftnl_set_get_str(set, NFTNL_SET_NAME);
    if (rc || !table || !name || strcmp(table, result->table) || strcmp(name, result->set)) rc = -1;
    else rc = nftnl_set_elem_foreach(set, element_cb, result);
    nftnl_set_free(set); return rc;
}
static int read_elements(struct connection *c, struct elements *result) {
    _Alignas(struct nlmsghdr) char buffer[1024]; struct nftnl_set *set = nftnl_set_alloc();
    if (!set) return -1;
    nftnl_set_set_str(set, NFTNL_SET_TABLE, result->table); nftnl_set_set_str(set, NFTNL_SET_NAME, result->set);
    struct nlmsghdr *h = nftnl_nlmsg_build_hdr(buffer, NFT_MSG_GETSETELEM, NFPROTO_INET, NLM_F_DUMP, c->seq++);
    nftnl_set_elems_nlmsg_build_payload(h, set); nftnl_set_free(set);
    return query(c, h, elements_cb, result);
}
static uc_value_t *lease_status(uc_vm_t *vm, struct connection *c) {
    struct table_info info = {0};
    if (read_table(c, &info)) return failure(vm, "gateway_command_failed");
    struct elements v4 = {.keylen=12, .table=PRIVATE_TABLE, .set="targets4"};
    struct elements v6 = {.keylen=36, .table=PRIVATE_TABLE, .set="targets6"};
    if (info.exists && (read_elements(c, &v4) || read_elements(c, &v6))) return failure(vm, "gateway_command_failed");
    uc_value_t *out = ucv_object_new(vm);
    ucv_object_add(out, "intercepting", ucv_boolean_new(v4.count + v6.count > 0));
    ucv_object_add(out, "leases", ucv_uint64_new(v4.count + v6.count));
    return out;
}
static uc_value_t *uc_status(uc_vm_t *vm, size_t nargs) {
    (void)nargs; struct connection c;
    if (open_netlink(&c, NETLINK_NETFILTER)) return failure(vm, "gateway_command_failed");
    uc_value_t *result = lease_status(vm, &c); close(c.fd); return result;
}
static uc_value_t *uc_table(uc_vm_t *vm, size_t nargs) {
    (void)nargs; struct connection c; struct table_info info = {0};
    if (open_netlink(&c, NETLINK_NETFILTER)) return failure(vm, "gateway_command_failed");
    int rc = read_table(&c, &info); close(c.fd);
    if (rc) return failure(vm, "gateway_command_failed");
    uc_value_t *out = ucv_object_new(vm);
    ucv_object_add(out, "exists", ucv_boolean_new(info.exists));
    ucv_object_add(out, "signature", info.signature[0] ? ucv_string_new(info.signature) : NULL); return out;
}
struct guard { unsigned rules; bool valid; };
static bool data32(struct nftnl_expr *e, uint16_t attr, uint32_t value) {
    uint32_t len = 0; const void *data = nftnl_expr_get(e, attr, &len);
    return data && len == sizeof(value) && !memcmp(data, &value, sizeof(value));
}
static int guard_cb(const struct nlmsghdr *h, void *arg) {
    if (!nft_reply(h, NFT_MSG_NEWRULE)) return -1;
    struct guard *g = arg; struct nftnl_rule *r = nftnl_rule_alloc();
    if (!r) return -1;
    int rc = nftnl_rule_nlmsg_parse(h, r);
    const char *table = nftnl_rule_get_str(r, NFTNL_RULE_TABLE), *chain = nftnl_rule_get_str(r, NFTNL_RULE_CHAIN);
    if (rc || !table || !chain || strcmp(table, "netfleet") || strcmp(chain, "mangle_prerouting_lan")) { nftnl_rule_free(r); return -1; }
    if (g->rules++ == 0) {
        struct nftnl_expr_iter *it = nftnl_expr_iter_create(r);
        if (!it) { nftnl_rule_free(r); return -1; }
        unsigned step = 0; bool valid = true; struct nftnl_expr *e;uint32_t reg=0;
        while ((e = nftnl_expr_iter_next(it)) != NULL) {
            const char *name = nftnl_expr_get_str(e, NFTNL_EXPR_NAME);
            if (!name) { valid = false; break; }
            if (!strcmp(name, "counter")) continue;
            if (step == 0) {
                if (strcmp(name,"ct")) { valid=false; break; }
                reg=nftnl_expr_get_u32(e,NFTNL_EXPR_CT_DREG);
                valid &= nftnl_expr_get_u32(e,NFTNL_EXPR_CT_KEY)==NFT_CT_MARK &&
                    (reg==NFT_REG_1||reg==NFT_REG32_00) &&
                    !nftnl_expr_is_set(e,NFTNL_EXPR_CT_SREG) && !nftnl_expr_is_set(e,NFTNL_EXPR_CT_DIR);
            }
            else if (step == 1) valid &= !strcmp(name,"bitwise") && nftnl_expr_get_u32(e,NFTNL_EXPR_BITWISE_SREG)==reg && nftnl_expr_get_u32(e,NFTNL_EXPR_BITWISE_DREG)==reg && nftnl_expr_get_u32(e,NFTNL_EXPR_BITWISE_LEN)==4 && data32(e,NFTNL_EXPR_BITWISE_MASK,0x01000000) && data32(e,NFTNL_EXPR_BITWISE_XOR,0) && (!nftnl_expr_is_set(e,NFTNL_EXPR_BITWISE_OP) || nftnl_expr_get_u32(e,NFTNL_EXPR_BITWISE_OP)==NFT_BITWISE_BOOL);
            else if (step == 2) valid &= !strcmp(name,"cmp") && nftnl_expr_get_u32(e,NFTNL_EXPR_CMP_SREG)==reg && nftnl_expr_get_u32(e,NFTNL_EXPR_CMP_OP)==NFT_CMP_NEQ && data32(e,NFTNL_EXPR_CMP_DATA,0);
            else if (step == 3) valid &= !strcmp(name,"immediate") && nftnl_expr_get_u32(e,NFTNL_EXPR_IMM_DREG)==NFT_REG_VERDICT && nftnl_expr_get_u32(e,NFTNL_EXPR_IMM_VERDICT)==(uint32_t)NFT_RETURN;
            else valid = false;
            step++;
        }
        g->valid = valid && step == 4; nftnl_expr_iter_destroy(it);
    }
    nftnl_rule_free(r); return 0;
}
static uc_value_t *uc_observe(uc_vm_t *vm, size_t nargs) {
    (void)nargs; struct connection c;
    if (open_netlink(&c, NETLINK_NETFILTER)) return failure(vm, "gateway_command_failed");
    struct elements lan = {.interfaces=ucv_array_new(vm), .keylen=16, .table="netfleet", .set="lan_inbound_device"};
    uint32_t before=0,after=0;int rc=generation(&c,&before);
    if(!rc)rc=read_elements(&c, &lan);
    struct guard g = {0};
    if (!rc) {
        _Alignas(struct nlmsghdr) char buffer[1024]; struct nftnl_rule *r = nftnl_rule_alloc();
        if (!r) rc = -1;
        else {
            nftnl_rule_set_str(r,NFTNL_RULE_TABLE,"netfleet"); nftnl_rule_set_str(r,NFTNL_RULE_CHAIN,"mangle_prerouting_lan");
            struct nlmsghdr *h=nftnl_nlmsg_build_hdr(buffer,NFT_MSG_GETRULE,NFPROTO_INET,NLM_F_DUMP,c.seq++);
            nftnl_rule_nlmsg_build_payload(h,r); nftnl_rule_free(r); rc=query(&c,h,guard_cb,&g);
        }
    }
    bool present=!(rc&&errno==ENOENT);
    if(!present)rc=0;
    if(!rc)rc=generation(&c,&after);
    close(c.fd);if(before!=after)rc=-1;
    if (rc) { ucv_put(lan.interfaces); return failure(vm,"gateway_command_failed"); }
    uc_value_t *out=ucv_object_new(vm); ucv_object_add(out,"interfaces",lan.interfaces);
    ucv_object_add(out,"guard",ucv_boolean_new(g.valid));ucv_object_add(out,"present",ucv_boolean_new(present));
    ucv_object_add(out,"generation",ucv_uint64_new(after));return out;
}
struct route_query { uint32_t table; int family; bool rule, found; unsigned loopback; };
static int route_cb(const struct nlmsghdr *h, void *arg) {
    struct route_query *q=arg;
    size_t header=q->rule?sizeof(struct fib_rule_hdr):sizeof(struct rtmsg);
    if (h->nlmsg_len<NLMSG_LENGTH(header) || h->nlmsg_type!=(q->rule?RTM_NEWRULE:RTM_NEWROUTE)) return -1;
    const struct rtmsg *route=q->rule?NULL:NLMSG_DATA(h);
    const struct fib_rule_hdr *rule=q->rule?NLMSG_DATA(h):NULL;
    uint32_t table=q->rule?rule->table:route->rtm_table,oif=0;
    int len=h->nlmsg_len-NLMSG_LENGTH(header);
    struct rtattr *attr=(void *)((char *)NLMSG_DATA(h)+NLMSG_ALIGN(header));
    for (;RTA_OK(attr,len);attr=RTA_NEXT(attr,len)) {
        int table_attr=q->rule?FRA_TABLE:RTA_TABLE;
        if (attr->rta_type==table_attr || (!q->rule&&attr->rta_type==RTA_OIF)) {
            if (RTA_PAYLOAD(attr)!=4) return -1;
            uint32_t value;memcpy(&value,RTA_DATA(attr),4);
            if (attr->rta_type==table_attr) table=value;else oif=value;
        }
    }
    if (len) return -1;
    int family=q->rule?rule->family:route->rtm_family;
    if (family==q->family && table==q->table && (q->rule ||
        (route->rtm_type==RTN_LOCAL && !route->rtm_dst_len && oif==q->loopback))) q->found=true;
    return 0;
}
static uc_value_t *uc_routes(uc_vm_t *vm,size_t nargs) {
    (void)nargs; uc_value_t *table=uc_fn_arg(0),*families=uc_fn_arg(1);
    int64_t id=ucv_int64_get(table);
    if (ucv_type(table)!=UC_INTEGER || id<1 || id>UINT32_MAX || ucv_type(families)!=UC_ARRAY || ucv_array_length(families)>2) return failure(vm,"gateway_input_invalid");
    struct connection c;if(open_netlink(&c,NETLINK_ROUTE))return failure(vm,"gateway_command_failed");
    bool ready=true;int rc=0;
    for(size_t i=0;i<ucv_array_length(families)&&!rc;i++) {
        int64_t family=ucv_int64_get(ucv_array_get(families,i));
        if(family!=4&&family!=6){rc=-1;break;}
        for(int rule=0;rule<2&&!rc;rule++) {
            _Alignas(struct nlmsghdr) char buffer[128]={0};struct nlmsghdr *h=(void *)buffer;
            h->nlmsg_len=NLMSG_LENGTH(rule?sizeof(struct fib_rule_hdr):sizeof(struct rtmsg));h->nlmsg_type=rule?RTM_GETRULE:RTM_GETROUTE;
            h->nlmsg_flags=NLM_F_REQUEST|NLM_F_DUMP;h->nlmsg_seq=c.seq++;
            int af=family==4?AF_INET:AF_INET6;
            if(rule)((struct fib_rule_hdr *)NLMSG_DATA(h))->family=af;
            else ((struct rtmsg *)NLMSG_DATA(h))->rtm_family=af;
            struct route_query q={.table=(uint32_t)id,.family=af,.rule=rule,.loopback=if_nametoindex("lo")};
            rc=query(&c,h,route_cb,&q);ready &= q.found;
        }
    }
    close(c.fd);return rc?failure(vm,"gateway_command_failed"):ucv_boolean_new(ready);
}
static uc_value_t *uc_port_range(uc_vm_t *vm,size_t nargs) {
    (void)nargs;int64_t low=ucv_int64_get(uc_fn_arg(0)),high=ucv_int64_get(uc_fn_arg(1));
    if(ucv_type(uc_fn_arg(0))!=UC_INTEGER||ucv_type(uc_fn_arg(1))!=UC_INTEGER||low<1||high<=low||high>65535)return failure(vm,"gateway_input_invalid");
    uint32_t wanted=((uint32_t)high<<16)|(uint32_t)low;
    for(unsigned i=0;i<2;i++) {
        int fd=socket(i?AF_INET6:AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);uint32_t got=0;socklen_t size=sizeof(got);
        if(fd<0)return failure(vm,"egress_port_range_unsupported");
        int rc=setsockopt(fd,IPPROTO_IP,51,&wanted,sizeof(wanted))||getsockopt(fd,IPPROTO_IP,51,&got,&size)||size!=sizeof(got)||wanted!=got;
        close(fd);if(rc)return failure(vm,"egress_port_range_unsupported");
    }
    return ucv_boolean_new(true);
}
static int candidate_order(const void *a,const void *b) {
    const struct candidate *x=a,*y=b;
    if(x->len!=y->len)return x->len<y->len?-1:1;
    int cmp=memcmp(x->key,y->key,x->len);return cmp?cmp:memcmp(x->end,y->end,x->len);
}
static bool source_valid(const unsigned char *s,int bytes) {
    bool any=false;for(int i=0;i<bytes;i++)any|=s[i]!=0;
    if(!any)return false;
    if(bytes==4)return s[0]!=127 && !(s[0]>=224&&s[0]<=239) && !(s[0]==169&&s[1]==254);
    if(s[0]==255||(s[0]==254&&(s[1]&192)==128))return false;
    any=false;for(int i=0;i<15;i++)any|=s[i]!=0;
    return any||s[15]!=1;
}
static int parse_candidate(uc_value_t *value,struct candidate *row) {
    if(ucv_type(value)!=UC_ARRAY||ucv_array_length(value)!=3)return -1;
    uc_value_t *src=ucv_array_get(value,0),*dst=ucv_array_get(value,1),*p=ucv_array_get(value,2);
    if(ucv_type(src)!=UC_STRING||ucv_type(dst)!=UC_STRING||ucv_type(p)!=UC_INTEGER)return -1;
    const char *source=ucv_string_get(src),*target=ucv_string_get(dst);
    int64_t port=ucv_int64_get(p);
    if(ucv_string_length(src)!=strlen(source)||ucv_string_length(dst)!=strlen(target)||strlen(target)>=64||port<1||port>65535)return -1;
    int family=strchr(source,':')?AF_INET6:AF_INET,bytes=family==AF_INET?4:16;
    if(inet_pton(family,source,row->key)!=1||!source_valid(row->key,bytes))return -1;
    char address[64];strcpy(address,target);char *prefix=strchr(address,'/');int bits=bytes*8;
    if(prefix){*prefix++=0;char *end;errno=0;long n=strtol(prefix,&end,10);if(errno||!*prefix||*end||n<0||n>bits)return -1;bits=n;}
    if(inet_pton(family,address,row->key+bytes)!=1)return -1;
    uint16_t nport=htons((uint16_t)port);memcpy(row->key+2*bytes,&nport,2);row->len=bytes*2+4;
    memcpy(row->end,row->key,row->len);
    for(int bit=bits;bit<bytes*8;bit++) {
        unsigned char mask=1U<<(7-bit%8);
        if(row->key[bytes+bit/8]&mask)return -1;
        row->end[bytes+bit/8]|=mask;
    }
    return 0;
}
static struct nlmsghdr *set_message(void *buffer,uint16_t op,uint16_t flags,uint32_t seq,int family) {
    struct nftnl_set *set=nftnl_set_alloc();if(!set)return NULL;
    nftnl_set_set_str(set,NFTNL_SET_TABLE,PRIVATE_TABLE);
    nftnl_set_set_str(set,NFTNL_SET_NAME,family==4?"targets4":"targets6");
    struct nlmsghdr *h=nftnl_nlmsg_build_hdr(buffer,op,NFPROTO_INET,flags,seq);
    nftnl_set_elems_nlmsg_build_payload(h,set);nftnl_set_free(set);return h;
}
/* One bounded datagram contains BEGIN, both flushes, additions, END. */
static int write_candidates(struct connection *c,struct candidate *rows,unsigned count,uint32_t gen) {
    const size_t capacity=1024*1024;char *buffer=calloc(1,capacity);
    if(!buffer)return -1;
    size_t used=0;uint32_t first=c->seq;struct nlmsghdr *h=nftnl_batch_begin(buffer,c->seq++);
    mnl_attr_put_u32(h,NFNL_BATCH_GENID,htonl(gen));
    used+=NLMSG_ALIGN(h->nlmsg_len);
    for(unsigned family=4;family<=6;family+=2) {
        h=set_message(buffer+used,NFT_MSG_DELSETELEM,NLM_F_ACK,c->seq++,family);
        if(!h){free(buffer);return -1;}used+=NLMSG_ALIGN(h->nlmsg_len);
    }
    unsigned at=0;
    while(at<count) {
        struct nftnl_set *set=nftnl_set_alloc();if(!set){free(buffer);return -1;}
        unsigned len=rows[at].len,added=0;
        nftnl_set_set_str(set,NFTNL_SET_TABLE,PRIVATE_TABLE);
        nftnl_set_set_str(set,NFTNL_SET_NAME,len==12?"targets4":"targets6");
        while(at<count&&rows[at].len==len&&added<128) {
            struct candidate *row=&rows[at++];struct nftnl_set_elem *e=nftnl_set_elem_alloc();
            if(!e){nftnl_set_free(set);free(buffer);return -1;}
            if(nftnl_set_elem_set(e,NFTNL_SET_ELEM_KEY,row->key,len)||nftnl_set_elem_set(e,NFTNL_SET_ELEM_KEY_END,row->end,len)) {
                nftnl_set_elem_free(e);nftnl_set_free(set);free(buffer);return -1;
            }
            nftnl_set_elem_set_u64(e,NFTNL_SET_ELEM_TIMEOUT,10000);nftnl_set_elem_add(set,e);added++;
        }
        if(used+BUFFER>capacity){nftnl_set_free(set);free(buffer);return -1;}
        h=nftnl_nlmsg_build_hdr(buffer+used,NFT_MSG_NEWSETELEM,NFPROTO_INET,NLM_F_CREATE|NLM_F_EXCL|NLM_F_ACK,c->seq++);
        nftnl_set_elems_nlmsg_build_payload(h,set);nftnl_set_free(set);used+=NLMSG_ALIGN(h->nlmsg_len);
    }
    uint32_t end=c->seq;h=nftnl_batch_end(buffer+used,c->seq++);used+=NLMSG_ALIGN(h->nlmsg_len);
    int size=2*1024*1024;
    if(setsockopt(c->fd,SOL_SOCKET,SO_SNDBUFFORCE,&size,sizeof(size))||transmit(c,buffer,used)){free(buffer);return -1;}
    free(buffer);unsigned expected=end-first-1,received=0;bool seen[40]={0};
    if(expected>=sizeof(seen)/sizeof(seen[0])){errno=E2BIG;return -1;}
    while(received<expected) {
        _Alignas(struct nlmsghdr) char reply[BUFFER];ssize_t size=receive(c,reply,sizeof(reply));if(size<0)return -1;
        int remain=size;
        for(struct nlmsghdr *ack=(void *)reply;remain > 0 && NLMSG_OK(ack,(unsigned)remain);ack=NLMSG_NEXT(ack,remain)) {
            if(ack->nlmsg_pid!=c->port||ack->nlmsg_type!=NLMSG_ERROR||ack->nlmsg_len<NLMSG_LENGTH(sizeof(struct nlmsgerr))||ack->nlmsg_seq<first||ack->nlmsg_seq>end){errno=EPROTO;return -1;}
            struct nlmsgerr *error=NLMSG_DATA(ack);
            if(error->error){errno=-error->error;return -1;}
            unsigned index=ack->nlmsg_seq-first-1;
            if(ack->nlmsg_seq<=first||index>=expected||seen[index]){errno=EPROTO;return -1;}
            seen[index]=true;received++;
        }
        if(remain){errno=EPROTO;return -1;}
    }
    return 0;
}
static uc_value_t *uc_renew(uc_vm_t *vm,size_t nargs) {
    uc_value_t *input=uc_fn_arg(0);size_t count=ucv_array_length(input);
    if(geteuid()!=0||ucv_type(input)!=UC_ARRAY||count>LIMIT)return failure(vm,"invalid_lease_candidate");
    struct candidate *rows=calloc(count?count:1,sizeof(*rows));
    if(!rows)return failure(vm,"gateway_command_failed");
    for(size_t i=0;i<count;i++)if(parse_candidate(ucv_array_get(input,i),&rows[i])){free(rows);return failure(vm,"invalid_lease_candidate");}
    qsort(rows,count,sizeof(*rows),candidate_order);unsigned unique=0;
    for(size_t i=0;i<count;i++)if(!unique||candidate_order(&rows[unique-1],&rows[i]))rows[unique++]=rows[i];
    struct connection c;if(open_netlink(&c,NETLINK_NETFILTER)){free(rows);return failure(vm,"gateway_command_failed");}
    struct table_info info={0};uint32_t gen=0;int rc=generation(&c,&gen);
    uc_value_t *expected=uc_fn_arg(1);
    if(!rc&&expected&&(ucv_type(expected)!=UC_INTEGER||ucv_uint64_get(expected)!=gen))rc=-1;
    if(!rc)rc=read_table(&c,&info);
    if(!rc&&info.exists)rc=write_candidates(&c,rows,unique,gen);
    else if(!rc&&unique)rc=-1;
    /* New read requests after the write ACKs, never the transaction's cache. */
    bool *seen=calloc(unique?unique:1,sizeof(bool));if(!seen)rc=-1;
    struct elements v4={.keylen=12,.table=PRIVATE_TABLE,.set="targets4",.expected=rows,.expected_count=unique,.seen=seen};
    struct elements v6={.keylen=36,.table=PRIVATE_TABLE,.set="targets6",.expected=rows,.expected_count=unique,.seen=seen};
    if(!rc&&info.exists)rc=read_elements(&c,&v4)||read_elements(&c,&v6);
    if(!rc&&(v4.count+v6.count!=unique))rc=-1;
    close(c.fd);free(rows);free(seen);
    if(rc)return failure(vm,"gateway_command_failed");
    uc_value_t *out=ucv_object_new(vm);ucv_object_add(out,"intercepting",ucv_boolean_new(unique>0));ucv_object_add(out,"leases",ucv_uint64_new(unique));return out;
}
static uc_value_t *uc_controller(uc_vm_t *vm,size_t nargs) {
    (void)vm;(void)nargs;
    struct connection c={.deadline=now_ms()+DEADLINE_MS};
    c.fd=socket(AF_UNIX,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    if(c.fd<0)return ucv_boolean_new(false);
    struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,"/etc/opl-netfleet/native/run/controller.sock");
    bool ready=false;
    if(connect(c.fd,(struct sockaddr *)&address,sizeof(address))) {
        if(errno!=EINPROGRESS||wait_io(&c,POLLOUT))goto done;
        int error=0;socklen_t size=sizeof(error);if(getsockopt(c.fd,SOL_SOCKET,SO_ERROR,&error,&size)||error)goto done;
    }
    const char request[]="GET /version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    size_t sent=0;
    while(sent<sizeof(request)-1) {
        ssize_t n=send(c.fd,request+sent,sizeof(request)-1-sent,MSG_NOSIGNAL);
        if(n>0){sent+=n;continue;}if(n<0&&errno==EINTR)continue;
        if(n<0&&errno==EAGAIN&&!wait_io(&c,POLLOUT))continue;
        goto done;
    }
    char response[8193];size_t used=0;
    while(used<sizeof(response)-1) {
        ssize_t n=recv(c.fd,response+used,sizeof(response)-1-used,MSG_DONTWAIT);
        if(n>0){used+=n;continue;}if(!n)break;if(errno==EINTR)continue;
        if(errno==EAGAIN&&!wait_io(&c,POLLIN))continue;
        goto done;
    }
    response[used]=0;
    if(used>=sizeof(response)-1||strncmp(response,"HTTP/1.1 200 ",13))goto done;
    char *body=strstr(response,"\r\n\r\n");if(!body)goto done;body+=4;
    struct json_tokener *parser=json_tokener_new();if(!parser)goto done;
    struct json_object *value=json_tokener_parse_ex(parser,body,used-(body-response));
    struct json_object *version=NULL;
    ready=json_tokener_get_error(parser)==json_tokener_success&&value&&json_object_object_get_ex(value,"version",&version)&&json_object_is_type(version,json_type_string);
    if(value)json_object_put(value);
    json_tokener_free(parser);
done:
    close(c.fd);return ucv_boolean_new(ready);
}
static const uc_function_list_t functions[]={
    {"observe",uc_observe},{"table",uc_table},{"status",uc_status},{"routes",uc_routes},{"port_range",uc_port_range},{"renew",uc_renew},{"controller",uc_controller}
};
void uc_module_init(uc_vm_t *vm,uc_value_t *scope) { uc_function_list_register(scope,functions);(void)vm; }
