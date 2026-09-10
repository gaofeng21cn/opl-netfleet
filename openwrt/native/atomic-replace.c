/* Commit one caller-created private file in a caller-owned directory. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static int name_ok(const char *name) {
    return *name && strcmp(name,".") && strcmp(name,"..") && !strchr(name,'/') && strlen(name)<256;
}
int main(int argc,char **argv) {
    if(argc!=4 || !name_ok(argv[2]) || !name_ok(argv[3]) || !strcmp(argv[2],argv[3])) return 2;
    alarm(2);
    int dir=open(argv[1],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC), fd=-1, result=3;
    struct stat st;
    if(dir<0 || fstat(dir,&st) || st.st_uid!=getuid() || (st.st_mode&0022)) goto done;
    fd=openat(dir,argv[2],O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() ||
       st.st_nlink!=1 || (st.st_mode&0027) || st.st_size>2097152) goto done;
    if(fsync(fd) || renameat(dir,argv[2],dir,argv[3]) || fsync(dir)) goto done;
    result=0;
done:
    if(fd>=0) close(fd);
    if(dir>=0) close(dir);
    if(result) fputs("atomic_replace_failed\n",stderr);
    return result;
}
