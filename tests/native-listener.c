#include <arpa/inet.h>
#include <grp.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
    if(setgroups(0,0)||setgid(65534)||setuid(65534)) return 1;
    int fd=socket(AF_INET,SOCK_STREAM,0),one=1;
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons(18443),.sin_addr={htonl(INADDR_ANY)}};
    if(fd<0||setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one))||bind(fd,(void*)&addr,sizeof(addr))||listen(fd,8)) return 2;
    for(;;) pause();
}
