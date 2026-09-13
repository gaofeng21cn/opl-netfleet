/* A private child session for local TLS checks. No routing or lease operations. */
#define _GNU_SOURCE
#include <ucode/module.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "probe-session.h"
struct session { int fd; pid_t pid; uint64_t serial; };
static uc_resource_type_t *session_type;
static int64_t millis(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000LL+t.tv_nsec/1000000;}
static void stop(struct session *s) {
    if(s->fd>=0) {close(s->fd);s->fd=-1;}
    if(s->pid<=0)return;
    int status;pid_t rc;
    do {rc=waitpid(s->pid,&status,WNOHANG);}while(rc<0&&errno==EINTR);
    if(!rc) {
        kill(s->pid,SIGKILL);
        int64_t end=millis()+25;
        do {rc=waitpid(s->pid,&status,WNOHANG);if(!rc)poll(NULL,0,1);}while(!rc&&millis()<end);
    }
    s->pid=0;
}
static void release(void *data) {struct session *s=data;if(s){stop(s);free(s);}}
static uc_value_t *error(uc_vm_t *vm,const char *reason) {uc_vm_raise_exception(vm,EXCEPTION_RUNTIME,"%s",reason);return NULL;}
static uc_value_t *open_session(uc_vm_t *vm,size_t nargs) {
    (void)nargs;uc_value_t *path=uc_fn_arg(0),*user=uc_fn_arg(1),*group=uc_fn_arg(2);
    const char *run=ucv_string_get(path);int64_t uid=ucv_int64_get(user),gid=ucv_int64_get(group);
    if(geteuid()!=0||ucv_type(path)!=UC_STRING||!run||run[0]!='/'||ucv_string_length(path)!=strlen(run)||strlen(run)>350||
       ucv_type(user)!=UC_INTEGER||ucv_type(group)!=UC_INTEGER||uid<1||gid<1||uid>INT32_MAX||gid>INT32_MAX) return error(vm,"probe_identity_failed");
    struct session *s=calloc(1,sizeof(*s));if(!s)return error(vm,"probe_session_failed");
    int pair[2];if(socketpair(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC|SOCK_NONBLOCK,0,pair)){free(s);return error(vm,"probe_session_failed");}
    char userarg[24],grouparg[24];snprintf(userarg,sizeof(userarg),"%lld",(long long)uid);snprintf(grouparg,sizeof(grouparg),"%lld",(long long)gid);
    pid_t pid=fork();
    if(!pid) {
        if(pair[1]!=3&&dup2(pair[1],3)<0)_exit(125);
        if(fcntl(3,F_SETFD,0)<0||syscall(SYS_close_range,4U,~0U,0)<0)_exit(125);
        int sink=open("/dev/null",O_RDWR|O_CLOEXEC);
        if(sink<0)_exit(125);
        for(int i=0;i<3;i++)if(dup2(sink,i)<0)_exit(125);
        if(sink>3)close(sink);
        struct rlimit zero={0,0},files={16,16},memory={33554432,33554432};
        if(setrlimit(RLIMIT_CORE,&zero)||setrlimit(RLIMIT_NOFILE,&files)||setrlimit(RLIMIT_AS,&memory))_exit(125);
        execl("/usr/libexec/opl-netfleet-compat/tls-probe","tls-probe","session",run,userarg,grouparg,(char *)NULL);
        _exit(125);
    }
    close(pair[1]);
    if(pid<0){close(pair[0]);free(s);return error(vm,"probe_session_failed");}
    s->fd=pair[0];s->pid=pid;return ucv_resource_new(session_type,s);
}
static uc_value_t *proof(uc_vm_t *vm,const struct probe_proof *p) {
    if(p->ok>1||p->duration_ms>1400||!memchr(p->reason,0,sizeof(p->reason))||
       strspn(p->reason,"abcdefghijklmnopqrstuvwxyz_")!=strlen(p->reason)||
       (p->ok?*p->reason!=0:*p->reason==0))return NULL;
    uc_value_t *out=ucv_object_new(vm);
    ucv_object_add(out,"ok",ucv_boolean_new(p->ok));ucv_object_add(out,"reason",*p->reason?ucv_string_new(p->reason):NULL);
    ucv_object_add(out,"duration_ms",ucv_uint64_new(p->duration_ms));ucv_object_add(out,"timeout_ms",ucv_uint64_new(1400));return out;
}
static uc_value_t *request(uc_vm_t *vm,size_t nargs) {
    (void)nargs;struct session *s=uc_fn_thisval("netfleet.probe");
    if(!s||s->fd<0)return error(vm,"probe_session_failed");
    const char *reason="probe_channel_failed";
    const int64_t deadline=millis()+1400;
    const struct probe_request req={.serial=++s->serial};
    if(send(s->fd,&req,sizeof(req),MSG_NOSIGNAL)!=sizeof(req))goto failed;
    for(;;) {
        int64_t remaining=deadline-millis();if(remaining<=0){reason="probe_timeout";goto failed;}
        struct pollfd p={.fd=s->fd,.events=POLLIN};int rc=poll(&p,1,remaining);
        if(rc<0&&errno==EINTR)continue;
        if(rc<=0){reason=rc==0?"probe_timeout":"probe_channel_failed";goto failed;}
        struct probe_reply reply;struct iovec iov={.iov_base=&reply,.iov_len=sizeof(reply)};
        struct msghdr msg={.msg_iov=&iov,.msg_iovlen=1};
        ssize_t n=recvmsg(s->fd,&msg,MSG_DONTWAIT);
        if(n<0&&(errno==EAGAIN||errno==EINTR))continue;
        reason=n==0?"probe_worker_exited":"probe_response_invalid";
        if(n!=sizeof(reply)||(msg.msg_flags&MSG_TRUNC)||reply.serial!=req.serial)goto failed;
        if(millis()>deadline){reason="probe_timeout";goto failed;}
        uc_value_t *v4=proof(vm,&reply.ipv4),*v6=proof(vm,&reply.ipv6);
        if(!v4||!v6){ucv_put(v4);ucv_put(v6);goto failed;}
        uc_value_t *out=ucv_object_new(vm);ucv_object_add(out,"ipv4",v4);ucv_object_add(out,"ipv6",v6);return out;
    }
failed:
    stop(s);return error(vm,reason);
}
static uc_value_t *close_session(uc_vm_t *vm,size_t nargs) {(void)nargs;struct session *s=uc_fn_thisval("netfleet.probe");if(s)stop(s);return ucv_boolean_new(true);}
static const uc_function_list_t methods[]={{"request",request},{"close",close_session}};
static const uc_function_list_t functions[]={{"open",open_session}};
void uc_module_init(uc_vm_t *vm,uc_value_t *scope) {session_type=uc_type_declare(vm,"netfleet.probe",methods,release);uc_function_list_register(scope,functions);}
