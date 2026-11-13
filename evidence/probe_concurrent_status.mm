#include "rlapp_core.h"
#include "net/webui.h"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <thread>
#include <atomic>
int main(){ @autoreleasepool {
  setenv("RLPLAYER_STATE_DIR","/tmp/conc-state",1);
  setenv("RLPLAYER_LIBRARY_DIR","/tmp/conc-lib",1);
  system("mkdir -p /tmp/conc-state /tmp/conc-lib");
  FILE*f=fopen("/tmp/conc-state/rlplayer-settings.conf","w"); fputs("backend=null\nvolume=-120\nscanonstartup=0\n",f); fclose(f);
  if(!rlapp::start_embedded()){printf("core fail\n");return 1;}
  std::atomic<int> bad{0}, okc{0};
  auto worker=[&](){ for(int i=0;i<200;i++){
      rta::net::HttpRequest rq; rq.method="GET"; rq.path="/api/status"; std::string ct;
      std::string out=rlapp::dispatch(rq,ct);
      if(out.empty()||out.find("\"ok\":true")==std::string::npos) ++bad; else ++okc;
  }};
  std::thread a(worker),b(worker),c(worker);
  a.join();b.join();c.join();
  printf("status 并发 600 次: ok=%d bad=%d\n", okc.load(), bad.load());
  rlapp::stop_embedded();
  return 0; } }
