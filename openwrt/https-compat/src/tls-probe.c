/* Bounded TLS/ALPN validation; sends HTTP only to the private loopback fixture. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <netdb.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#ifndef IP_LOCAL_PORT_RANGE
#define IP_LOCAL_PORT_RANGE 51
#endif
static long long started;
static int paired;
static const char *last_reason;
static SSL_CTX *paired_context;
static long long millis(void) {struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec*1000LL+ts.tv_nsec/1000000;}
static void expired(int signum) {
    (void)signum;
    static const char message[]="{\"ok\":false,\"reason\":\"probe_timeout\"}\n";
    (void)write(STDOUT_FILENO,message,sizeof(message)-1);_exit(1);
}
static int finish(const char *reason) {
    if(paired) {last_reason=reason;return reason?1:0;}
    printf("{\"ok\":%s,\"reason\":",reason?"false":"true");
    if(reason) printf("\"%s\"",reason);else fputs("null",stdout);
    printf(",\"duration_ms\":%lld,\"timeout_ms\":1400,\"at\":%ld}\n",millis()-started,(long)time(NULL));
    return reason?1:0;
}
static int waitfd(int fd,short events,int limit) {
    long long remaining=1400-(millis()-started);
    if(remaining<=0) return -1;
    if(remaining>limit) remaining=limit;
    struct pollfd item={.fd=fd,.events=events};
    int rc;do {rc=poll(&item,1,(int)remaining);}while(rc<0&&errno==EINTR);
    return rc>0 && !(item.revents&POLLNVAL) ? 0:-1;
}
static int connectfd(int fd,const struct sockaddr *address,socklen_t length) {
    if(connect(fd,address,length)==0) return 0;
    if(errno!=EINPROGRESS||waitfd(fd,POLLOUT,400)) return -1;
    int error=0;socklen_t len=sizeof(error);
    return getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&len)||error?-1:0;
}
static int sslwait(SSL *ssl,int rc) {
    int error=SSL_get_error(ssl,rc);
    if(error!=SSL_ERROR_WANT_READ&&error!=SSL_ERROR_WANT_WRITE) return -1;
    return waitfd(SSL_get_fd(ssl),error==SSL_ERROR_WANT_READ?POLLIN:POLLOUT,1400);
}
static int sendall(int fd,const char *data,size_t size) {
    while(size) {ssize_t count=send(fd,data,size,MSG_NOSIGNAL);
        if(count>0){data+=count;size-=(size_t)count;continue;}
        if(errno!=EAGAIN&&errno!=EINTR) return -1;
        if(waitfd(fd,POLLOUT,1400)) return -1;
    }return 0;
}
static int number(const char *text,int maximum) {
    char *end;errno=0;long value=strtol(text,&end,10);
    return !errno&&*text&&!*end&&value>=0&&value<=maximum?(int)value:-1;
}
static int probe(int argc,char **argv) {
    if(argc==4 && !strcmp(argv[1],"resolve")) {
        if(number(argv[3],65535)<1 || !*argv[2] || strlen(argv[2])>253 || strspn(argv[2],"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")!=strlen(argv[2])) return 2;
        signal(SIGALRM,expired);
        struct itimerval timer={.it_value={.tv_usec=700000}};setitimer(ITIMER_REAL,&timer,NULL);
        struct addrinfo hints={.ai_socktype=SOCK_STREAM,.ai_family=AF_UNSPEC},*records=NULL;
        if(getaddrinfo(argv[2],argv[3],&hints,&records)) return finish("upstream_dns_failed");
        fputs("{\"ok\":true,\"addresses\":[",stdout);unsigned count=0;
        for(struct addrinfo *row=records;row && count<64;row=row->ai_next) {
            char address[INET6_ADDRSTRLEN];const void *data=NULL;
            if(row->ai_family==AF_INET) data=&((struct sockaddr_in*)row->ai_addr)->sin_addr;
            if(row->ai_family==AF_INET6) data=&((struct sockaddr_in6*)row->ai_addr)->sin6_addr;
            if(data && inet_ntop(row->ai_family,data,address,sizeof(address))) printf("%s\"%s\"",count++?",":"",address);
        }
        freeaddrinfo(records);puts("]}");return 0;
    }
    int local=argc>=2&&!strcmp(argv[1],"local");
    if((local&&argc!=5)||(!local&&(argc!=6||strcmp(argv[1],"upstream")))) return 2;
    signal(SIGPIPE,SIG_IGN);signal(SIGALRM,expired);
    struct itimerval timer={.it_value={.tv_sec=1,.tv_usec=400000}};
    if(!paired) setitimer(ITIMER_REAL,&timer,NULL);
    int fd=-1;char ca[512],hostname[254];uint32_t ports=0;
    if(local) {
        int family=number(argv[3],6),uid=number(argv[4],2147483647);
        if((family!=0&&family!=4&&family!=6)||uid<=0||strlen(argv[2])>350||argv[2][0]!='/') return 2;
        strcpy(hostname,"localhost");snprintf(ca,sizeof(ca),"%s/ca/mitmproxy-ca-cert.pem",argv[2]);
        if(family==0) {
            struct sockaddr_un address={.sun_family=AF_UNIX};
            int count=snprintf(address.sun_path,sizeof(address.sun_path),"%s/engine/probe.sock",argv[2]);
            if(count<0||(size_t)count>=sizeof(address.sun_path)) return 2;
            fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
            if(fd<0||connectfd(fd,(struct sockaddr*)&address,sizeof(address))) return finish("probe_connect_failed");
            const char proxy[]="PROXY TCP4 127.0.0.1 127.0.0.1 12345 18445\r\n";
            if(sendall(fd,proxy,sizeof(proxy)-1)) return finish("probe_connect_failed");
        } else {
            uid_t original=geteuid();
            if(seteuid((uid_t)uid)) return finish("probe_identity_failed");
            fd=socket(family==4?AF_INET:AF_INET6,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
            if(seteuid(original)) return finish("probe_identity_failed");
            int priority=6;
            if(fd<0||setsockopt(fd,SOL_SOCKET,SO_PRIORITY,&priority,sizeof(priority))) return finish("probe_socket_failed");
            struct sockaddr_in v4={.sin_family=AF_INET,.sin_port=htons(18445),.sin_addr={htonl(INADDR_LOOPBACK)}};
            struct sockaddr_in6 v6={.sin6_family=AF_INET6,.sin6_port=htons(18445),.sin6_addr=IN6ADDR_LOOPBACK_INIT};
            if(connectfd(fd,family==4?(struct sockaddr*)&v4:(struct sockaddr*)&v6,family==4?sizeof(v4):sizeof(v6))) return finish("probe_connect_failed");
        }
    } else {
        int port=number(argv[3],65535),lower=number(argv[4],65535),upper=number(argv[5],65535);
        if(port<1||lower<0||upper<lower||strlen(argv[2])>253||!strlen(argv[2])||strspn(argv[2],"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")!=strlen(argv[2])) return 2;
        strcpy(hostname,argv[2]);strcpy(ca,"/etc/ssl/certs/ca-certificates.crt");
        ports=((uint32_t)upper<<16)|(uint32_t)lower;
        if(geteuid()==0) {
            int group=open("/sys/fs/cgroup/netfleet-compat/cgroup.procs",O_WRONLY|O_CLOEXEC|O_NOFOLLOW);
            char pid[32];int count=snprintf(pid,sizeof(pid),"%ld",(long)getpid());
            if(group<0||write(group,pid,(size_t)count)!=count) return finish("probe_isolation_failed");
            close(group);
            struct passwd *account=getpwnam("netfleet-compat");
            if(!account||!account->pw_uid||!account->pw_gid||setgroups(0,NULL)||setgid(account->pw_gid)||setuid(account->pw_uid)) return finish("probe_identity_failed");
        }
        struct addrinfo hints={.ai_socktype=SOCK_STREAM,.ai_family=AF_UNSPEC},*records=NULL;
        if(getaddrinfo(hostname,argv[3],&hints,&records)) return finish("upstream_dns_failed");
        unsigned n=0;
        for(struct addrinfo *record=records;record&&n<4;record=record->ai_next,n++) {
            fd=socket(record->ai_family,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
            if(fd<0) continue;
            if((ports&&setsockopt(fd,IPPROTO_IP,IP_LOCAL_PORT_RANGE,&ports,sizeof(ports)))||connectfd(fd,record->ai_addr,record->ai_addrlen)) {close(fd);fd=-1;continue;}
            break;
        }
        freeaddrinfo(records);if(fd<0) return finish("upstream_connect_failed");
    }
    SSL_CTX *context=paired_context;
    if(!context) {
        context=SSL_CTX_new(TLS_client_method());
        if(!context||!SSL_CTX_load_verify_locations(context,ca,NULL)) return finish("probe_ca_failed");
        if(paired) paired_context=context;
    }
    SSL_CTX_set_verify(context,SSL_VERIFY_PEER,NULL);
    SSL *ssl=SSL_new(context);
    const unsigned char h1[]={8,'h','t','t','p','/','1','.','1'},h2[]={2,'h','2'};
    if(!ssl||!SSL_set_fd(ssl,fd)||!SSL_set_tlsext_host_name(ssl,hostname)||!SSL_set1_host(ssl,hostname)||
       SSL_set_alpn_protos(ssl,local?h1:h2,local?sizeof(h1):sizeof(h2))) return finish("probe_tls_failed");
    int rc;
    while((rc=SSL_connect(ssl))!=1) if(sslwait(ssl,rc)) return finish(SSL_get_verify_result(ssl)!=X509_V_OK?"upstream_certificate_failed":"upstream_tls_failed");
    const unsigned char *alpn=NULL;unsigned alpn_length=0;SSL_get0_alpn_selected(ssl,&alpn,&alpn_length);
    const char *expected=local?"http/1.1":"h2";
    if(alpn_length!=strlen(expected)||memcmp(alpn,expected,alpn_length)) return finish(local?"probe_downstream_protocol_failed":"upstream_h2_not_negotiated");
    if(local) {
        unsigned char random[16];char nonce[34]="/",request[256],response[4097];
        if(RAND_bytes(random,sizeof(random))!=1) return finish("probe_random_failed");
        for(unsigned n=0;n<sizeof(random);n++) snprintf(nonce+1+n*2,3,"%02x",random[n]);
        int count=snprintf(request,sizeof(request),"GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",nonce),offset=0;
        while(offset<count) {rc=SSL_write(ssl,request+offset,count-offset);if(rc>0)offset+=rc;else if(sslwait(ssl,rc)) return finish("probe_write_failed");}
        size_t received=0;char *body=NULL;
        while(received<sizeof(response)-1) {
            rc=SSL_read(ssl,response+received,(int)(sizeof(response)-1-received));
            if(rc>0) {
                received+=(size_t)rc;response[received]=0;body=strstr(response,"\r\n\r\n");
                if(body && strstr(body+4,nonce)) break;
            } else if(sslwait(ssl,rc)) break;
        }
        response[received]=0;
        if(strncmp(response,"HTTP/1.1 200 ",13)||!body) return finish("probe_conversion_failed");
        *body=0;
        if(!strcasestr(response,"\r\nx-upstream-protocol: h2\r\n")&&!strcasestr(response,"\r\nx-upstream-protocol: h2")) return finish("probe_conversion_failed");
        body+=4;
        if(strcmp(body,nonce)) {
            /* A dynamic HAProxy response may use chunked transfer encoding. */
            char *end=NULL;unsigned long size=strtoul(body,&end,16);
            if(!strcasestr(response,"transfer-encoding: chunked")||!end||strncmp(end,"\r\n",2)||size!=strlen(nonce)||strncmp(end+2,nonce,size)||strncmp(end+2+size,"\r\n",2)) return finish("probe_conversion_failed");
        }
    }
    SSL_free(ssl);if(!paired) SSL_CTX_free(context);close(fd);return finish(NULL);
}
int main(int argc,char **argv) {
    started=millis();
    if(argc>=2&&!strcmp(argv[1],"local-pair")) {
        if(argc!=4) return 2;
        paired=1;signal(SIGALRM,expired);
        struct itimerval timer={.it_value={.tv_sec=1,.tv_usec=400000}};
        setitimer(ITIMER_REAL,&timer,NULL);
        char *args[]={argv[0],"local",argv[2],"4",argv[3],NULL};
        int v4=probe(5,args);const char *reason4=last_reason;
        long long elapsed4=millis()-started,second=millis();
        args[3]="6";
        // Do not spend another deadline after the first proof has failed.
        int v6=v4?1:probe(5,args);
        const char *reason6=v4?"probe_skipped":last_reason;
        printf("{\"ipv4\":{\"ok\":%s,\"reason\":",v4?"false":"true");
        if(reason4) printf("\"%s\"",reason4);else fputs("null",stdout);
        printf(",\"duration_ms\":%lld,\"timeout_ms\":1400},\"ipv6\":{\"ok\":%s,\"reason\":",elapsed4,v6?"false":"true");
        if(reason6) printf("\"%s\"",reason6);else fputs("null",stdout);
        printf(",\"duration_ms\":%lld,\"timeout_ms\":1400},\"duration_ms\":%lld}\n",millis()-second,millis()-started);
        SSL_CTX_free(paired_context);
        return v4||v6?1:0;
    }
    return probe(argc,argv);
}
