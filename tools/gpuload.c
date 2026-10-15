/*
 * gpuload: keep a GPU busy and report the FP32 throughput it actually achieves.
 *
 * Only the CUDA *driver* API is used, loaded at run time with dlopen(), so no
 * CUDA toolkit is needed to build or run this: gcc and the NVIDIA driver are enough.
 * The kernel is written directly in PTX and JIT-compiled by the driver.
 *
 *   build:  gcc -O2 -o gpuload gpuload.c -ldl      (or just `make`)
 *   run:    CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index> ./gpuload [seconds]
 *
 * The PTX targets sm_70, so the GPU must be Volta or newer. The TFLOPS number is
 * what the kernel really achieved (2 FLOP per FMA), not a hardware peak: it is
 * what you compare between two cards, or before/after a change.
 *
 * Output is in French when LC_ALL/LANG starts with "fr", English otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <time.h>

typedef int CUresult;
typedef void *CUhandle;

/*
 * One thread runs 8 independent chains of x = x * a + b (a is just above or just
 * below 1, so the values stay finite). A fused multiply-add has a latency of a few
 * cycles; 8 independent chains per thread plus many resident warps keep the FMA
 * units busy on every cycle. The result is written out so the compiler cannot
 * throw the loop away.
 */
static const char *PTX =
    ".version 7.0\n"
    ".target sm_70\n"
    ".address_size 64\n"
    ".visible .entry burn(.param .u32 iters, .param .u64 out)\n"
    "{\n"
    "  .reg .u32 %r<4>; .reg .u64 %rd<3>; .reg .pred %p; .reg .f32 %f<16>;\n"
    "  ld.param.u32 %r1, [iters];\n"
    "  ld.param.u64 %rd1, [out];\n"
    "  mov.u32 %r2, %tid.x;\n"
    "  cvt.rn.f32.u32 %f1, %r2;\n"                       /* seed the chains with the thread id */
    "  mov.f32 %f2, 0f3F800001;\n"                       /* a1 = 1.0000001 */
    "  mov.f32 %f3, 0f3F7FFFFE;\n"                       /* a2 = 0.9999999 */
    "  mov.f32 %f4, 0f3A83126F;\n"                       /* b  = 0.001 */
    "  mov.f32 %f5, %f1; mov.f32 %f6, %f1; mov.f32 %f7, %f1; mov.f32 %f8, %f1;\n"
    "  mov.f32 %f9, %f1; mov.f32 %f10, %f1; mov.f32 %f11, %f1; mov.f32 %f12, %f1;\n"
    "L:\n"
    "  fma.rn.f32 %f5, %f5, %f2, %f4;  fma.rn.f32 %f6, %f6, %f3, %f4;\n"
    "  fma.rn.f32 %f7, %f7, %f2, %f4;  fma.rn.f32 %f8, %f8, %f3, %f4;\n"
    "  fma.rn.f32 %f9, %f9, %f2, %f4;  fma.rn.f32 %f10, %f10, %f3, %f4;\n"
    "  fma.rn.f32 %f11, %f11, %f2, %f4; fma.rn.f32 %f12, %f12, %f3, %f4;\n"
    "  sub.u32 %r1, %r1, 1;\n"
    "  setp.ne.u32 %p, %r1, 0;\n"
    "  @%p bra L;\n"
    "  add.f32 %f13, %f5, %f6;  add.f32 %f13, %f13, %f7;  add.f32 %f13, %f13, %f8;\n"
    "  add.f32 %f13, %f13, %f9; add.f32 %f13, %f13, %f10; add.f32 %f13, %f13, %f11;\n"
    "  add.f32 %f13, %f13, %f12;\n"
    "  st.global.f32 [%rd1], %f13;\n"
    "  ret;\n"
    "}\n";

enum {
    THREADS_PER_BLOCK = 256,
    BLOCKS_PER_SM     = 6,         /* 6 * 256 = 1536 threads, the resident limit of an SM on compute capability 8.6 */
    FMA_PER_ITER      = 8,         /* one per chain, see the kernel */
    ATTR_SM_COUNT     = 16,        /* CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT */
};

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* French output if the locale says so */
static int french(void)
{
    const char *l = getenv("LC_ALL");
    if (!l || !*l)
        l = getenv("LANG");
    return l && l[0] == 'f' && l[1] == 'r';
}

#define CHECK(call)                                                              \
    do {                                                                         \
        CUresult e_ = (call);                                                    \
        if (e_) {                                                                \
            fprintf(stderr, french() ? "erreur CUDA %d (ligne %d)\n"             \
                                     : "CUDA error %d (line %d)\n", e_, __LINE__);\
            return 1;                                                            \
        }                                                                        \
    } while (0)

int main(int argc, char **argv)
{
    double seconds = argc > 1 ? atof(argv[1]) : 20;

    void *lib = dlopen("libcuda.so.1", RTLD_NOW);
    if (!lib) {
        puts(french() ? "libcuda introuvable (pilote NVIDIA installé ?)" : "libcuda not found (is the NVIDIA driver installed?)");
        return 2;
    }

    /* the driver API entry points we need; the _v2 names are the current ABI */
    CUresult (*cuInit)(unsigned) = dlsym(lib, "cuInit");
    CUresult (*cuDeviceGet)(int *, int) = dlsym(lib, "cuDeviceGet");
    CUresult (*cuDeviceGetName)(char *, int, int) = dlsym(lib, "cuDeviceGetName");
    CUresult (*cuDeviceGetAttribute)(int *, int, int) = dlsym(lib, "cuDeviceGetAttribute");
    CUresult (*cuCtxCreate)(CUhandle *, unsigned, int) = dlsym(lib, "cuCtxCreate_v2");
    CUresult (*cuModuleLoadData)(CUhandle *, const void *) = dlsym(lib, "cuModuleLoadData");
    CUresult (*cuModuleGetFunction)(CUhandle *, CUhandle, const char *) = dlsym(lib, "cuModuleGetFunction");
    CUresult (*cuMemAlloc)(unsigned long long *, size_t) = dlsym(lib, "cuMemAlloc_v2");
    CUresult (*cuLaunchKernel)(CUhandle, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned,
                               unsigned, CUhandle, void **, void **) = dlsym(lib, "cuLaunchKernel");
    CUresult (*cuCtxSynchronize)(void) = dlsym(lib, "cuCtxSynchronize");

    int dev, sm_count = 0;
    char name[128];
    CUhandle ctx, module, kernel;
    unsigned long long out_buf;

    /* with CUDA_VISIBLE_DEVICES set to one index, "device 0" is the card we were asked to load */
    CHECK(cuInit(0));
    CHECK(cuDeviceGet(&dev, 0));
    CHECK(cuDeviceGetName(name, sizeof name, dev));
    cuDeviceGetAttribute(&sm_count, ATTR_SM_COUNT, dev);
    if (sm_count < 1)
        sm_count = 1;
    printf(french() ? "Charge sur: %s (%d SM)\n" : "Load on: %s (%d SMs)\n", name, sm_count);

    CHECK(cuCtxCreate(&ctx, 0, dev));
    CHECK(cuModuleLoadData(&module, PTX));
    CHECK(cuModuleGetFunction(&kernel, module, "burn"));
    CHECK(cuMemAlloc(&out_buf, 4096));

    unsigned iters = 4000000;           /* ~0.3 s per launch on an RTX 3080 */
    void *params[] = { &iters, &out_buf };
    unsigned blocks = sm_count * BLOCKS_PER_SM;

    /* launch back to back until the time is up; synchronizing each time keeps launches from piling up */
    double t0 = now();
    long launches = 0;
    while (now() - t0 < seconds) {
        CHECK(cuLaunchKernel(kernel, blocks, 1, 1, THREADS_PER_BLOCK, 1, 1, 0, NULL, params, NULL));
        CHECK(cuCtxSynchronize());
        launches++;
    }
    double elapsed = now() - t0;

    /* 2 FLOP per FMA */
    double flop = (double)launches * blocks * THREADS_PER_BLOCK * FMA_PER_ITER * iters * 2;
    printf(french() ? "%ld lancements en %.1f s (%.2f TFLOPS fma estimés)\n"
                    : "%ld launches in %.1f s (%.2f TFLOPS fma estimated)\n",
           launches, elapsed, flop / elapsed / 1e12);
    return 0;
}
