/* procd owns restart and signals. This launcher limits and execs one process. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
static int write_value(const char *path, const char *value) {
    int fd = open(path,O_WRONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return -1;
    ssize_t count=write(fd,value,strlen(value));
    int closed=close(fd);
    return count==(ssize_t)strlen(value) && !closed ? 0 : -1;
}
static int read_value(const char *path,char *out,size_t limit) {
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0) return -1;
    ssize_t count=read(fd,out,limit-1); close(fd);
    if(count<0 || (size_t)count>=limit-1) return -1;
    out[count]=0; while(count && (out[count-1]=='\n'||out[count-1]==' ')) out[--count]=0;
    return 0;
}
static int limit(int which, rlim_t value) {
    const struct rlimit spec={value,value}; return setrlimit(which,&spec);
}
static int constrain(int manager) {
    const char *group=manager?"/sys/fs/cgroup/netfleet-compat-manager":"/sys/fs/cgroup/netfleet-compat";
    char data[4096],path[256];
    if(read_value("/sys/fs/cgroup/cgroup.controllers",data,sizeof(data)) ||
       !strstr(data,"memory") || !strstr(data,"cpu") || !strstr(data,"pids")) return -1;
    if(write_value("/sys/fs/cgroup/cgroup.subtree_control","+memory +cpu +pids")) return -1;
    if(mkdir(group,0755) && errno!=EEXIST) return -1;
    struct stat st;
    if(lstat(group,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=0||(st.st_mode&0022)) return -1;
    snprintf(path,sizeof(path),"%s/cgroup.procs",group);
    if(read_value(path,data,sizeof(data)) || *data) return -1;
    const char *names[]={"memory.max","memory.swap.max","memory.oom.group","pids.max","cpu.max"};
    const char *values[]={manager?"100663296":"201326592","0","1",manager?"16":"32","50000 100000"};
    for(unsigned n=0;n<5;n++) {
        snprintf(path,sizeof(path),"%s/%s",group,names[n]);
        if(write_value(path,values[n])||read_value(path,data,sizeof(data))||strcmp(data,values[n])) return -1;
    }
    snprintf(path,sizeof(path),"%s/cgroup.procs",group); snprintf(data,sizeof(data),"%ld",(long)getpid());
    if(write_value(path,data)||limit(RLIMIT_NOFILE,manager?128:512)||limit(RLIMIT_CORE,0)||limit(RLIMIT_FSIZE,8388608)) return -1;
    if(manager) {
        cpu_set_t available,selected; CPU_ZERO(&available); CPU_ZERO(&selected);
        if(sched_getaffinity(0,sizeof(available),&available)) return -1;
        for(int n=0;n<CPU_SETSIZE;n++) if(CPU_ISSET(n,&available)) {CPU_SET(n,&selected);break;}
        if(sched_setaffinity(0,sizeof(selected),&selected)) return -1;
    }
    return 0;
}
int main(int argc,char **argv) {
    if(argc!=2 || (strcmp(argv[1],"engine") && strcmp(argv[1],"manager")) || getuid()!=0) return 2;
    const int manager=!strcmp(argv[1],"manager");
    umask(0077);
    if(constrain(manager)) {fputs("engine_resource_isolation_failed\n",stderr);return 3;}
    if(!manager) {
        struct passwd *pw=getpwnam("netfleet-compat");
        struct group *gr=getgrnam("netfleet-compat");
        if(!pw||!gr||!pw->pw_uid||!gr->gr_gid||pw->pw_gid!=gr->gr_gid) return 4;
        uid_t uid=pw->pw_uid; gid_t gid=gr->gr_gid;
        setpwent(); while((pw=getpwent())) if(pw->pw_uid==uid&&strcmp(pw->pw_name,"netfleet-compat")) return 4; endpwent();
        setgrent(); while((gr=getgrent())) if(gr->gr_gid==gid&&strcmp(gr->gr_name,"netfleet-compat")) return 4; endgrent();
        if(setgroups(0,NULL)||setgid(gid)||setuid(uid)||prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)) return 4;
        execl("/usr/libexec/opl-netfleet-compat/haproxy","/usr/libexec/opl-netfleet-compat/haproxy","-db","-f","/var/run/opl-netfleet-compat/haproxy.cfg",(char*)NULL);
    } else {
        execl("/usr/bin/ucode","ucode","/usr/libexec/opl-netfleet/main.uc","compatibility-watch",(char*)NULL);
    }
    fputs("compatibility_exec_failed\n",stderr);return 5;
}
