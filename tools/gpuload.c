// gpuload — minimal GPU load through the CUDA *driver* API (libcuda): no CUDA toolkit needed, the kernel is plain PTX (fused multiply-adds).
// Charge GPU minimale via l'API pilote CUDA (libcuda) : pas besoin du toolkit CUDA, le noyau est du PTX (multiplications-additions fusionnées).
//
// Build / compilation : gcc -O2 -o gpuload gpuload.c -ldl        (or: make)
// Usage : CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<gpu index> ./gpuload [seconds, default 20]
// Needs a Volta-or-newer GPU (the PTX targets sm_70 and is JIT-compiled by the driver).
// The TFLOPS figure is the FP32 FMA throughput actually achieved (2 FLOP per FMA), it is NOT a hardware peak.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <time.h>
typedef int R; typedef void *H;
static const char *PTX =
".version 7.0\n.target sm_70\n.address_size 64\n"
".visible .entry burn(.param .u32 iters, .param .u64 out)\n{\n"
" .reg .u32 %r<4>; .reg .u64 %rd<3>; .reg .pred %p; .reg .f32 %f<16>;\n"
" ld.param.u32 %r1,[iters]; ld.param.u64 %rd1,[out];\n"
" mov.u32 %r2,%tid.x; cvt.rn.f32.u32 %f1,%r2;\n"
" mov.f32 %f2,0f3F800001; mov.f32 %f3,0f3F7FFFFE; mov.f32 %f4,0f3A83126F;\n"
" mov.f32 %f5,%f1; mov.f32 %f6,%f1; mov.f32 %f7,%f1; mov.f32 %f8,%f1; mov.f32 %f9,%f1; mov.f32 %f10,%f1; mov.f32 %f11,%f1; mov.f32 %f12,%f1;\n"
"L:\n"
" fma.rn.f32 %f5,%f5,%f2,%f4; fma.rn.f32 %f6,%f6,%f3,%f4; fma.rn.f32 %f7,%f7,%f2,%f4; fma.rn.f32 %f8,%f8,%f3,%f4;\n"
" fma.rn.f32 %f9,%f9,%f2,%f4; fma.rn.f32 %f10,%f10,%f3,%f4; fma.rn.f32 %f11,%f11,%f2,%f4; fma.rn.f32 %f12,%f12,%f3,%f4;\n"
" sub.u32 %r1,%r1,1; setp.ne.u32 %p,%r1,0; @%p bra L;\n"
" add.f32 %f13,%f5,%f6; add.f32 %f13,%f13,%f7; add.f32 %f13,%f13,%f8; add.f32 %f13,%f13,%f9; add.f32 %f13,%f13,%f10; add.f32 %f13,%f13,%f11; add.f32 %f13,%f13,%f12;\n"
" st.global.f32 [%rd1],%f13;\n ret;\n}\n";
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static int fr(void){const char*l=getenv("LC_ALL");if(!l||!*l)l=getenv("LANG");return l&&l[0]=='f'&&l[1]=='r';}
#define CK(x) do{R e=(x); if(e){fprintf(stderr,fr()?"erreur CUDA %d à la ligne %d\n":"CUDA error %d at line %d\n",e,__LINE__);return 1;}}while(0)
int main(int argc,char**argv){
  double secs=argc>1?atof(argv[1]):20;
  void*l=dlopen("libcuda.so.1",RTLD_NOW); if(!l){puts(fr()?"libcuda introuvable":"libcuda not found");return 2;}
  R(*cuInit)(unsigned)=dlsym(l,"cuInit"); R(*cuDeviceGet)(int*,int)=dlsym(l,"cuDeviceGet");
  R(*cuDeviceGetName)(char*,int,int)=dlsym(l,"cuDeviceGetName"); R(*cuCtxCreate)(H*,unsigned,int)=dlsym(l,"cuCtxCreate_v2");
  R(*cuDeviceGetAttribute)(int*,int,int)=dlsym(l,"cuDeviceGetAttribute");
  R(*cuModuleLoadData)(H*,const void*)=dlsym(l,"cuModuleLoadData"); R(*cuModuleGetFunction)(H*,H,const char*)=dlsym(l,"cuModuleGetFunction");
  R(*cuMemAlloc)(unsigned long long*,size_t)=dlsym(l,"cuMemAlloc_v2");
  R(*cuLaunchKernel)(H,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,H,void**,void**)=dlsym(l,"cuLaunchKernel");
  R(*cuCtxSynchronize)(void)=dlsym(l,"cuCtxSynchronize");
  int dev,nsm=0; char name[128]; H ctx,mod,fn; unsigned long long buf;
  CK(cuInit(0)); CK(cuDeviceGet(&dev,0)); CK(cuDeviceGetName(name,128,dev));
  cuDeviceGetAttribute(&nsm,16,dev); if(nsm<1)nsm=1;               // CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT
  printf(fr()?"Charge sur: %s (%d SM)\n":"Load on: %s (%d SMs)\n",name,nsm);
  CK(cuCtxCreate(&ctx,0,dev)); CK(cuModuleLoadData(&mod,PTX)); CK(cuModuleGetFunction(&fn,mod,"burn")); CK(cuMemAlloc(&buf,4096));
  unsigned iters=4000000; void*params[]={&iters,&buf}; unsigned blocks=nsm*6;
  double t0=now(); long n=0;
  while(now()-t0<secs){ CK(cuLaunchKernel(fn,blocks,1,1,256,1,1,0,NULL,params,NULL)); CK(cuCtxSynchronize()); n++; }
  printf(fr()?"%ld lancements en %.1f s (%.2f TFLOPS fma estimés)\n":"%ld launches in %.1f s (%.2f TFLOPS fma estimated)\n",
         n,now()-t0,(double)n*blocks*256*8*iters*2/(now()-t0)/1e12);
  return 0;
}
