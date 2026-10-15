// sondeclk — measures the REAL SM clock under load (clock64 / globaltimer inside a kernel), the SM count, and a checksum of the results.
// Mesure la fréquence RÉELLE des SM sous charge (clock64 / globaltimer dans le noyau), le nombre de SM et une somme de contrôle des résultats.
//
// Why: nvidia-smi shows the clock the driver *asked for*; this shows what the SMs actually deliver. On the card this repo was written for,
// nvidia-smi said 1995 MHz while the SMs really ran at ~1335 MHz (a healthy card of the same model: 1917-1938 real for 1905-1920 shown).
// The checksum must be identical on two GPUs of the same architecture running the same code (a mismatch = computation errors).
//
// Build : gcc -O2 -o sondeclk sondeclk.c -ldl        (or: make)
// Usage : CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<gpu index> ./sondeclk [launches=4] [iterations=4000000]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
typedef int R; typedef void *H;
static const char *PTX =
".version 7.0\n.target sm_70\n.address_size 64\n"
".visible .entry clk(.param .u32 iters, .param .u64 rec, .param .u64 scr)\n{\n"
" .reg .u32 %r<8>; .reg .u64 %rd<14>; .reg .pred %p<3>; .reg .f32 %f<16>;\n"
" ld.param.u32 %r1,[iters]; ld.param.u64 %rd1,[rec]; ld.param.u64 %rd2,[scr];\n"
" mov.u32 %r2,%tid.x; mov.u32 %r3,%ctaid.x; cvt.rn.f32.u32 %f1,%r2;\n"
" mov.f32 %f2,0f3F800001; mov.f32 %f3,0f3F7FFFFE; mov.f32 %f4,0f3A83126F;\n"
" mov.f32 %f5,%f1; mov.f32 %f6,%f1; mov.f32 %f7,%f1; mov.f32 %f8,%f1; mov.f32 %f9,%f1; mov.f32 %f10,%f1; mov.f32 %f11,%f1; mov.f32 %f12,%f1;\n"
" mov.u64 %rd3,%clock64; mov.u64 %rd4,%globaltimer;\n"
"L:\n"
" fma.rn.f32 %f5,%f5,%f2,%f4; fma.rn.f32 %f6,%f6,%f3,%f4; fma.rn.f32 %f7,%f7,%f2,%f4; fma.rn.f32 %f8,%f8,%f3,%f4;\n"
" fma.rn.f32 %f9,%f9,%f2,%f4; fma.rn.f32 %f10,%f10,%f3,%f4; fma.rn.f32 %f11,%f11,%f2,%f4; fma.rn.f32 %f12,%f12,%f3,%f4;\n"
" sub.u32 %r1,%r1,1; setp.ne.u32 %p1,%r1,0; @%p1 bra L;\n"
" mov.u64 %rd5,%clock64; mov.u64 %rd6,%globaltimer;\n"
" add.f32 %f13,%f5,%f6; add.f32 %f13,%f13,%f7; add.f32 %f13,%f13,%f8; add.f32 %f13,%f13,%f9; add.f32 %f13,%f13,%f10; add.f32 %f13,%f13,%f11; add.f32 %f13,%f13,%f12;\n"
" mad.lo.u32 %r4,%r3,256,%r2; mul.wide.u32 %rd7,%r4,4; add.u64 %rd8,%rd2,%rd7; st.global.f32 [%rd8],%f13;\n"
" setp.ne.u32 %p2,%r2,0; @%p2 bra D;\n"
" mul.wide.u32 %rd9,%r3,32; add.u64 %rd10,%rd1,%rd9;\n"
" st.global.u64 [%rd10],%rd3; st.global.u64 [%rd10+8],%rd5; st.global.u64 [%rd10+16],%rd4; st.global.u64 [%rd10+24],%rd6;\n"
"D: ret;\n}\n";
static int fr(void){const char*l=getenv("LC_ALL");if(!l||!*l)l=getenv("LANG");return l&&l[0]=='f'&&l[1]=='r';}
#define CK(x) do{R e=(x); if(e){fprintf(stderr,fr()?"erreur CUDA %d à la ligne %d\n":"CUDA error %d at line %d\n",e,__LINE__);return 1;}}while(0)
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
int main(int argc,char**argv){
  int nlaunch=argc>1?atoi(argv[1]):4; unsigned iters=argc>2?(unsigned)atol(argv[2]):4000000;
  void*l=dlopen("libcuda.so.1",RTLD_NOW); if(!l){puts(fr()?"libcuda introuvable":"libcuda not found");return 2;}
  R(*cuInit)(unsigned)=dlsym(l,"cuInit"); R(*cuDeviceGet)(int*,int)=dlsym(l,"cuDeviceGet");
  R(*cuDeviceGetName)(char*,int,int)=dlsym(l,"cuDeviceGetName"); R(*cuDeviceGetAttribute)(int*,int,int)=dlsym(l,"cuDeviceGetAttribute");
  R(*cuCtxCreate)(H*,unsigned,int)=dlsym(l,"cuCtxCreate_v2");
  R(*cuModuleLoadData)(H*,const void*)=dlsym(l,"cuModuleLoadData"); R(*cuModuleGetFunction)(H*,H,const char*)=dlsym(l,"cuModuleGetFunction");
  R(*cuMemAlloc)(unsigned long long*,size_t)=dlsym(l,"cuMemAlloc_v2"); R(*cuMemcpyDtoH)(void*,unsigned long long,size_t)=dlsym(l,"cuMemcpyDtoH_v2");
  R(*cuLaunchKernel)(H,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,H,void**,void**)=dlsym(l,"cuLaunchKernel");
  R(*cuCtxSynchronize)(void)=dlsym(l,"cuCtxSynchronize");
  int dev,nsm=0,clk=0,mclk=0,bus=0,l2=0,maj=0,min=0; char name[128]; H ctx,mod,fn; unsigned long long rec,scr;
  CK(cuInit(0)); CK(cuDeviceGet(&dev,0)); CK(cuDeviceGetName(name,128,dev));
  cuDeviceGetAttribute(&nsm,16,dev); cuDeviceGetAttribute(&clk,13,dev); cuDeviceGetAttribute(&mclk,36,dev);
  cuDeviceGetAttribute(&bus,37,dev); cuDeviceGetAttribute(&l2,38,dev); cuDeviceGetAttribute(&maj,75,dev); cuDeviceGetAttribute(&min,76,dev);
  if(nsm<1)nsm=1;
  printf(fr()?"%s : %d SM, capacité %d.%d, horloge max annoncée %d MHz, mémoire %d MHz sur %d bits, L2 %d Ko\n"
             :"%s: %d SMs, compute capability %d.%d, advertised max clock %d MHz, memory %d MHz on %d bits, L2 %d KiB\n",
         name,nsm,maj,min,clk/1000,mclk/1000,bus,l2/1024);
  int nb=nsm*6; size_t nrec=(size_t)nb*32, nscr=(size_t)nb*256*4;
  CK(cuCtxCreate(&ctx,0,dev)); CK(cuModuleLoadData(&mod,PTX)); CK(cuModuleGetFunction(&fn,mod,"clk"));
  CK(cuMemAlloc(&rec,nrec)); CK(cuMemAlloc(&scr,nscr));
  uint64_t *r=malloc(nrec); float *s=malloc(nscr); double *f=malloc(nb*sizeof(double));
  void*params[]={&iters,&rec,&scr};
  for(int k=0;k<nlaunch;k++){
    CK(cuLaunchKernel(fn,nb,1,1,256,1,1,0,NULL,params,NULL)); CK(cuCtxSynchronize());
    CK(cuMemcpyDtoH(r,rec,nrec)); CK(cuMemcpyDtoH(s,scr,nscr));
    uint64_t tmin=~0ULL,tmax=0; double mean=0;
    for(int b=0;b<nb;b++){ uint64_t c0=r[b*4],c1=r[b*4+1],t0=r[b*4+2],t1=r[b*4+3];
      f[b]=(t1>t0)?(double)(c1-c0)*1e3/(double)(t1-t0):0; mean+=f[b]; if(t0<tmin)tmin=t0; if(t1>tmax)tmax=t1; }
    mean/=nb; qsort(f,nb,sizeof(double),cmp);
    uint64_t h=1469598103934665603ULL; const unsigned char*p=(const unsigned char*)s; for(size_t i=0;i<nscr;i++){h^=p[i];h*=1099511628211ULL;}
    printf(fr()?"lancement %d : %.3f s ; fréquence réelle des SM : moyenne %.0f MHz (min %.0f, médiane %.0f, max %.0f) ; somme de contrôle des résultats %016llx\n"
               :"launch %d: %.3f s; real SM clock: mean %.0f MHz (min %.0f, median %.0f, max %.0f); results checksum %016llx\n",
           k+1,(tmax-tmin)*1e-9,mean,f[0],f[nb/2],f[nb-1],(unsigned long long)h);
  }
  return 0;
}
