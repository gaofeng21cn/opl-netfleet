// Disposable fixture: create an outbound SYN without a TCP socket. The peer's
// SYN/ACK must receive the kernel RST, not a loop through router TPROXY.
import * as fs from 'fs';
import * as socket from 'socket';
if(!fs.stat('/tmp/netfleet-compat-vm-authorized')) die('isolated_guest_required');
const ipv6=ARGV[0]=='6',sending=ARGV[1]=='send';
if((ARGV[0]!='4'&&!ipv6)||index(['send','observe'],ARGV[1])<0) die('fixture_arguments_required');
const origin=ipv6?'2001:db8:88::10':'198.51.100.10';
const gateway=ipv6?'2001:db8:78::1':'10.78.0.1';
const origin_bytes=ipv6?[32,1,13,184,0,136,0,0,0,0,0,0,0,0,0,16]:[198,51,100,10];
const gateway_bytes=ipv6?[32,1,13,184,0,120,0,0,0,0,0,0,0,0,0,1]:[10,78,0,1];
const sock=socket.create(ipv6?socket.AF_INET6:socket.AF_INET,socket.SOCK_RAW|socket.SOCK_NONBLOCK,socket.IPPROTO_TCP);
if(!sock||!sock.bind(sending?gateway:origin,0)||!sock.connect(sending?origin:gateway,0)) die('raw_socket_unavailable');
if(sending) {
 // Only this synthetic SYN uses the fixture's existing DSCP bypass. Its kernel
 // RST has no socket and no DSCP; the production gateway must forward that RST.
 if(!sock.setopt(ipv6?socket.IPPROTO_IPV6:socket.IPPROTO_IP,ipv6?socket.IPV6_TCLASS:socket.IP_TOS,16)) die('fixture_dscp_failed');
 const pseudo=[...gateway_bytes,...origin_bytes,...(ipv6?[0,0,0,20,0,0,0,6]:[0,6,0,20])];
 const tcp=[253,232,1,187,18,52,86,120,0,0,0,0,80,2,32,0,0,0,0,0];
 let sum=0;
 for(let part in [pseudo,tcp]) for(let i=0;i<length(part);i+=2) sum+=(part[i]<<8)|part[i+1];
 while(sum>>16) sum=(sum&65535)+(sum>>16);
 const checksum=(~sum)&65535;tcp[16]=checksum>>8;tcp[17]=checksum&255;
 const packet=join('',map(tcp,n=>chr(n)));
 if(sock.send(packet)!=length(packet)) die('syn_send_failed');
 sock.close();exit(0);
}
fs.writefile('/tmp/tcp-reset-ready-'+ARGV[0],'ready');
const now=()=>+split(fs.readfile('/proc/uptime'),' ')[0],deadline=now()+2;
let seen=false;
while(now()<deadline) {
 const events=socket.poll(max(1,int((deadline-now())*1000)),[sock,socket.POLLIN]);
 if(!length(events ?? [])) break;
 const raw=sock.recv(4096);if(!raw) continue;
 const offset=ipv6?0:(ord(raw,0)&15)*4;
 if(length(raw)<offset+20) continue;
 if(ord(raw,offset)==253&&ord(raw,offset+1)==232&&ord(raw,offset+2)==1&&ord(raw,offset+3)==187&&
    (ord(raw,offset+13)&4)&&ord(raw,offset+4)==18&&ord(raw,offset+5)==52&&ord(raw,offset+6)==86&&ord(raw,offset+7)==121) {seen=true;break;}
}
sock.close();
if(!seen) die('kernel_reset_did_not_reach_peer');
printf('%J\n',{ok:true,family:ipv6?6:4,reset_received:true});
