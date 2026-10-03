// phasebench: run one zdedupe scan into a result store and print per-phase wall times.
// usage: phasebench [-m mode] [-d] [-x] [-H] [-W] [-L secs] [-j threads] [-o store] PATH...
//   -L SECS logs found/done rates, bytes read, memory footprint and the longest-running path every SECS.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/task_info.h>
#endif
size_t zdedupe_get_current_path(const void*, char*, size_t, bool*);
static double log_every; // -L SECS: periodic progress line
static size_t footprint(void){
#ifdef __APPLE__
  task_vm_info_data_t i; mach_msg_type_number_t n=TASK_VM_INFO_COUNT; if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&i,&n)!=KERN_SUCCESS)return 0; return i.phys_footprint;
#else
  long pages=0, rss=0; FILE*f=fopen("/proc/self/statm","r"); if(f){ if(fscanf(f,"%ld %ld",&pages,&rss)!=2)rss=0; fclose(f);} return (size_t)rss*(size_t)sysconf(_SC_PAGESIZE);
#endif
}
typedef struct zdedupe_ctx zdedupe_ctx;
typedef struct { uint32_t phase, _pad; uint64_t files_found, done, total, bytes_done, bytes_total; } zdedupe_progress;
zdedupe_ctx* zdedupe_init(void); void zdedupe_free(zdedupe_ctx*);
int zdedupe_add_path(zdedupe_ctx*, const char*); void zdedupe_set_mode(zdedupe_ctx*, int);
void zdedupe_set_analyze_dirs(zdedupe_ctx*, bool); void zdedupe_use_default_excludes(zdedupe_ctx*, bool);
void zdedupe_set_threads(zdedupe_ctx*, uint32_t); void zdedupe_set_include_hidden(zdedupe_ctx*, bool);
void zdedupe_cancel(zdedupe_ctx*); static int walk_only;
int zdedupe_run_to_file(zdedupe_ctx*, const char*); void zdedupe_get_progress(const zdedupe_ctx*, zdedupe_progress*);
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static const char* names[]={"idle","walk","size-group","quick-hash","full-hash","analyze","write","done"};
static volatile int running=1; static zdedupe_ctx* ctx; static double t0;
static double ph_start[8]; static uint64_t ph_items[8]; static int seen[8];
static void* poll(void*_){ int last=-1; double next_log=log_every; uint64_t last_found=0,last_done=0; double last_t=0; while(running){ zdedupe_progress p; zdedupe_get_progress(ctx,&p);
  if(log_every>0 && now()-t0>=next_log){ double t=now()-t0; char cur[512]; bool tail=false; size_t w=zdedupe_get_current_path(ctx,cur,sizeof cur-1,&tail); cur[w]=0;
    fprintf(stderr,"[%7.0fs] %-10s found=%llu (+%.0f/s) done=%llu/%llu (+%.0f/s) bytes=%.2f/%.2fGB footprint=%.0fMB cur=%s%s\n",t,names[p.phase<8?p.phase:0],(unsigned long long)p.files_found,(p.files_found-last_found)/(t-last_t),(unsigned long long)p.done,(unsigned long long)p.total,(p.done>=last_done?(p.done-last_done):0)/(t-last_t),p.bytes_done/1e9,p.bytes_total/1e9,footprint()/1e6,tail?"...":"",w?cur:"-");
    last_found=p.files_found; last_done=p.done; last_t=t; next_log+=log_every; }
  int ph=p.phase<8?p.phase:0; if(ph!=last){ if(!seen[ph]){seen[ph]=1;ph_start[ph]=now()-t0;} fprintf(stderr,"[%8.2fs] -> %s (found=%llu total=%llu)\n",now()-t0,names[ph],(unsigned long long)p.files_found,(unsigned long long)p.total); last=ph; }
  if(walk_only&&ph>1)zdedupe_cancel(ctx); ph_items[ph]= ph==1? p.files_found : p.total; usleep(200);} return 0; }
int main(int argc,char**argv){ int mode=0; bool dirs=false, defx=false, hidden=false; unsigned thr=0; const char* out="/tmp/zd-store.bin"; int c;
  while((c=getopt(argc,argv,"m:dxHWj:o:L:"))!=-1){ if(c=='W')walk_only=1; if(c=='L')log_every=atof(optarg); if(c=='m')mode=atoi(optarg); else if(c=='d')dirs=true; else if(c=='x')defx=true; else if(c=='H')hidden=true; else if(c=='j')thr=atoi(optarg); else if(c=='o')out=optarg; }
  ctx=zdedupe_init(); zdedupe_set_mode(ctx,mode); zdedupe_set_analyze_dirs(ctx,dirs); zdedupe_use_default_excludes(ctx,defx); zdedupe_set_include_hidden(ctx,hidden); if(thr)zdedupe_set_threads(ctx,thr);
  for(int i=optind;i<argc;i++) if(zdedupe_add_path(ctx,argv[i])!=0){fprintf(stderr,"bad path %s\n",argv[i]);return 2;}
  pthread_t th; t0=now(); pthread_create(&th,0,poll,0);
  int rc=zdedupe_run_to_file(ctx,out); double total=now()-t0; running=0; pthread_join(th,0);
  printf("rc=%d total=%.3fs\n",rc,total);
  double prev=-1; int prevph=-1;
  for(int ph=1;ph<8;ph++){ if(!seen[ph])continue; if(prevph>=0) printf("  %-10s %8.3fs  items=%llu\n",names[prevph],ph_start[ph]-ph_start[prevph],(unsigned long long)ph_items[prevph]); prevph=ph; }
  if(prevph>=0 && prevph!=7) printf("  %-10s %8.3fs\n",names[prevph],total-ph_start[prevph]);
  zdedupe_free(ctx); return rc; }
