#include "CControl24Capture.h"
#include <pcap/pcap.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <net/if_dl.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct c24_capture { pcap_t *pcap; uint8_t local_mac[6]; char interface[IFNAMSIZ]; };
static volatile sig_atomic_t stopping=0;
static void stop_signal(int signal_number) { (void)signal_number; stopping=1; }
void c24_install_signals(void) { signal(SIGINT,stop_signal);signal(SIGTERM,stop_signal); }
int c24_should_stop(void) { return stopping; }

c24_capture *c24_open(const char *interface,const char *source_mac,char *error,size_t error_size) {
    char pcap_error[PCAP_ERRBUF_SIZE]={0};
    pcap_t *handle=pcap_open_live(interface,65535,0,100,pcap_error);
    if (!handle) {snprintf(error,error_size,"%s",pcap_error);return NULL;}
    if (pcap_datalink(handle)!=DLT_EN10MB) {snprintf(error,error_size,"Choose an Ethernet interface (en3/en5), not a non-Ethernet capture device.");pcap_close(handle);return NULL;}
    char filter[128]="ether proto 0x885f";
    if (source_mac && source_mac[0]) {
        if (strlen(source_mac)!=17 || strspn(source_mac,"0123456789abcdefABCDEF:")!=17) {
            snprintf(error,error_size,"Invalid console MAC address.");pcap_close(handle);return NULL;
        }
        snprintf(filter,sizeof(filter),"ether proto 0x885f and ether src %s",source_mac);
    }
    struct bpf_program program;
    if (pcap_compile(handle,&program,filter,1,PCAP_NETMASK_UNKNOWN)<0) {snprintf(error,error_size,"%s",pcap_geterr(handle));pcap_close(handle);return NULL;}
    int result=pcap_setfilter(handle,&program);pcap_freecode(&program);
    if (result<0 || pcap_setnonblock(handle,1,pcap_error)<0) {snprintf(error,error_size,"%s",pcap_geterr(handle));pcap_close(handle);return NULL;}
    c24_capture *capture=calloc(1,sizeof(*capture));
    if (!capture) {snprintf(error,error_size,"Out of memory");pcap_close(handle);return NULL;}
    capture->pcap=handle;
    snprintf(capture->interface,sizeof(capture->interface),"%s",interface);
    return capture;
}

static void refresh_local_mac(c24_capture *capture) {
    memset(capture->local_mac,0,sizeof(capture->local_mac));
    struct ifaddrs *addresses=NULL;
    if (getifaddrs(&addresses)==0) {
        for (struct ifaddrs *a=addresses;a;a=a->ifa_next) {
            if (a->ifa_addr && a->ifa_addr->sa_family==AF_LINK && strcmp(a->ifa_name,capture->interface)==0) {
                struct sockaddr_dl *link=(struct sockaddr_dl *)a->ifa_addr;
                if (link->sdl_alen==6) memcpy(capture->local_mac,LLADDR(link),6);
            }
        }
        freeifaddrs(addresses);
    }
}

int c24_next(c24_capture *capture,uint8_t *buffer,size_t capacity) {
    struct pcap_pkthdr *header;const u_char *packet;
    int result=pcap_next_ex(capture->pcap,&header,&packet);
    if (result<=0) return result;
    if (header->caplen>capacity || header->caplen<14) return 0;
    if (packet[12]!=0x88 || packet[13]!=0x5f) return 0;
    if (memcmp(packet+6,capture->local_mac,6)==0) return 0;
    memcpy(buffer,packet,header->caplen);return (int)header->caplen;
}
int c24_send(c24_capture *capture,const uint8_t *destination,const uint8_t *payload,size_t size) {
    if (size>1500 || size<16) return -1;
    refresh_local_mac(capture);
    static const uint8_t zero[6]={0};if (memcmp(capture->local_mac,zero,6)==0) return -1;
    uint8_t frame[1514];memcpy(frame,destination,6);memcpy(frame+6,capture->local_mac,6);
    frame[12]=0x88;frame[13]=0x5f;memcpy(frame+14,payload,size);
    return pcap_inject(capture->pcap,frame,size+14)==(int)(size+14) ? 0:-1;
}
void c24_close(c24_capture *capture) {if (capture) {pcap_close(capture->pcap);free(capture);}}
