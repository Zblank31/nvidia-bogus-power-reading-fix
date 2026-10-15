/*
 * sondeclk: measure the clock the SMs really run at while the GPU is loaded.
 *
 * nvidia-smi reports the clock the driver asked for. This tool counts SM clock
 * cycles (clock64) against the GPU's global timer (globaltimer) inside a kernel that
 * occupies the whole card, so cycles / time is the real SM frequency. It also
 * prints the SM count and a checksum of the results.
 *
 * Why it exists: on the card this repository is about, nvidia-smi said 1995 MHz
 * while the SMs really ran at about 1335 MHz. A healthy card of the same model
 * showed 1917-1938 MHz for 1905-1920 MHz displayed.
 *
 * The checksum must be identical on two GPUs of the same architecture running the
 * same code, whatever their clocks. A different value would mean computation errors.
 *
 *   build:  gcc -O2 -o sondeclk sondeclk.c -ldl      (or `make`)
 *   run:    CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<index> ./sondeclk [launches=4] [iterations=4000000]
 *
 * Regression value for the default arguments: checksum c1a800a176215af3.
 * Output is in French when LC_ALL/LANG starts with "fr", English otherwise.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>

typedef int CUresult;
typedef void *CUhandle;

/*
 * Same FMA loop as gpuload.c, plus timestamps. Each block's thread 0 records
 * { clock64 before, clock64 after, globaltimer before, globaltimer after } into
 * rec[blockIdx.x * 4 .. +3]. Every thread stores its final value in scr[block * 256 + tid]
 * (that also keeps the compiler from dropping the loop, and feeds the checksum).
 */
static const char *PTX =
    ".version 7.0\n"
    ".target sm_70\n"
    ".address_size 64\n"
    ".visible .entry clk(.param .u32 iters, .param .u64 rec, .param .u64 scr)\n"
    "{\n"
    "  .reg .u32 %r<8>; .reg .u64 %rd<14>; .reg .pred %p<3>; .reg .f32 %f<16>;\n"
    "  ld.param.u32 %r1, [iters];\n"
    "  ld.param.u64 %rd1, [rec];\n"
    "  ld.param.u64 %rd2, [scr];\n"
    "  mov.u32 %r2, %tid.x;\n"
    "  mov.u32 %r3, %ctaid.x;\n"
    "  cvt.rn.f32.u32 %f1, %r2;\n"
    "  mov.f32 %f2, 0f3F800001;\n"                       /* 1.0000001 */
    "  mov.f32 %f3, 0f3F7FFFFE;\n"                       /* 0.9999999 */
    "  mov.f32 %f4, 0f3A83126F;\n"                       /* 0.001 */
    "  mov.f32 %f5, %f1; mov.f32 %f6, %f1; mov.f32 %f7, %f1; mov.f32 %f8, %f1;\n"
    "  mov.f32 %f9, %f1; mov.f32 %f10, %f1; mov.f32 %f11, %f1; mov.f32 %f12, %f1;\n"
    "  mov.u64 %rd3, %clock64;\n"
    "  mov.u64 %rd4, %globaltimer;\n"
    "L:\n"
    "  fma.rn.f32 %f5, %f5, %f2, %f4;  fma.rn.f32 %f6, %f6, %f3, %f4;\n"
    "  fma.rn.f32 %f7, %f7, %f2, %f4;  fma.rn.f32 %f8, %f8, %f3, %f4;\n"
    "  fma.rn.f32 %f9, %f9, %f2, %f4;  fma.rn.f32 %f10, %f10, %f3, %f4;\n"
    "  fma.rn.f32 %f11, %f11, %f2, %f4; fma.rn.f32 %f12, %f12, %f3, %f4;\n"
    "  sub.u32 %r1, %r1, 1;\n"
    "  setp.ne.u32 %p1, %r1, 0;\n"
    "  @%p1 bra L;\n"
    "  mov.u64 %rd5, %clock64;\n"
    "  mov.u64 %rd6, %globaltimer;\n"
    "  add.f32 %f13, %f5, %f6;  add.f32 %f13, %f13, %f7;  add.f32 %f13, %f13, %f8;\n"
    "  add.f32 %f13, %f13, %f9; add.f32 %f13, %f13, %f10; add.f32 %f13, %f13, %f11;\n"
    "  add.f32 %f13, %f13, %f12;\n"
    /* every thread: scr[ctaid * 256 + tid] = result */
    "  mad.lo.u32 %r4, %r3, 256, %r2;\n"
    "  mul.wide.u32 %rd7, %r4, 4;\n"
    "  add.u64 %rd8, %rd2, %rd7;\n"
    "  st.global.f32 [%rd8], %f13;\n"
    /* thread 0 only: the four timestamps, 32 bytes per block */
    "  setp.ne.u32 %p2, %r2, 0;\n"
    "  @%p2 bra D;\n"
    "  mul.wide.u32 %rd9, %r3, 32;\n"
    "  add.u64 %rd10, %rd1, %rd9;\n"
    "  st.global.u64 [%rd10],      %rd3;\n"
    "  st.global.u64 [%rd10 + 8],  %rd5;\n"
    "  st.global.u64 [%rd10 + 16], %rd4;\n"
    "  st.global.u64 [%rd10 + 24], %rd6;\n"
    "D:\n"
    "  ret;\n"
    "}\n";

enum {
    THREADS_PER_BLOCK = 256,
    BLOCKS_PER_SM     = 6,
};
/* CUDA driver API device attribute numbers */
enum {
    ATTR_CLOCK_RATE_KHZ = 13,
    ATTR_SM_COUNT       = 16,
    ATTR_MEM_CLOCK_KHZ  = 36,
    ATTR_MEM_BUS_BITS   = 37,
    ATTR_L2_BYTES       = 38,
    ATTR_CC_MAJOR       = 75,
    ATTR_CC_MINOR       = 76,
};

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

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* FNV-1a, 64 bit: cheap and good enough to compare two result buffers */
static uint64_t fnv1a(const unsigned char *p, size_t n)
{
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

int main(int argc, char **argv)
{
    int launches = argc > 1 ? atoi(argv[1]) : 4;
    unsigned iters = argc > 2 ? (unsigned)atol(argv[2]) : 4000000;

    void *lib = dlopen("libcuda.so.1", RTLD_NOW);
    if (!lib) {
        puts(french() ? "libcuda introuvable (pilote NVIDIA installé ?)" : "libcuda not found (is the NVIDIA driver installed?)");
        return 2;
    }
    CUresult (*cuInit)(unsigned) = dlsym(lib, "cuInit");
    CUresult (*cuDeviceGet)(int *, int) = dlsym(lib, "cuDeviceGet");
    CUresult (*cuDeviceGetName)(char *, int, int) = dlsym(lib, "cuDeviceGetName");
    CUresult (*cuDeviceGetAttribute)(int *, int, int) = dlsym(lib, "cuDeviceGetAttribute");
    CUresult (*cuCtxCreate)(CUhandle *, unsigned, int) = dlsym(lib, "cuCtxCreate_v2");
    CUresult (*cuModuleLoadData)(CUhandle *, const void *) = dlsym(lib, "cuModuleLoadData");
    CUresult (*cuModuleGetFunction)(CUhandle *, CUhandle, const char *) = dlsym(lib, "cuModuleGetFunction");
    CUresult (*cuMemAlloc)(unsigned long long *, size_t) = dlsym(lib, "cuMemAlloc_v2");
    CUresult (*cuMemcpyDtoH)(void *, unsigned long long, size_t) = dlsym(lib, "cuMemcpyDtoH_v2");
    CUresult (*cuLaunchKernel)(CUhandle, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned,
                               unsigned, CUhandle, void **, void **) = dlsym(lib, "cuLaunchKernel");
    CUresult (*cuCtxSynchronize)(void) = dlsym(lib, "cuCtxSynchronize");

    int dev, sm_count = 0, clock_khz = 0, mem_khz = 0, bus_bits = 0, l2_bytes = 0, cc_major = 0, cc_minor = 0;
    char name[128];
    CUhandle ctx, module, kernel;
    unsigned long long rec_dev, scr_dev;

    CHECK(cuInit(0));
    CHECK(cuDeviceGet(&dev, 0));
    CHECK(cuDeviceGetName(name, sizeof name, dev));
    cuDeviceGetAttribute(&sm_count, ATTR_SM_COUNT, dev);
    cuDeviceGetAttribute(&clock_khz, ATTR_CLOCK_RATE_KHZ, dev);
    cuDeviceGetAttribute(&mem_khz, ATTR_MEM_CLOCK_KHZ, dev);
    cuDeviceGetAttribute(&bus_bits, ATTR_MEM_BUS_BITS, dev);
    cuDeviceGetAttribute(&l2_bytes, ATTR_L2_BYTES, dev);
    cuDeviceGetAttribute(&cc_major, ATTR_CC_MAJOR, dev);
    cuDeviceGetAttribute(&cc_minor, ATTR_CC_MINOR, dev);
    if (sm_count < 1)
        sm_count = 1;
    printf(french() ? "%s : %d SM, capacité %d.%d, horloge max annoncée %d MHz, mémoire %d MHz sur %d bits, L2 %d Ko\n"
                    : "%s: %d SMs, compute capability %d.%d, advertised max clock %d MHz, memory %d MHz on %d bits, L2 %d KiB\n",
           name, sm_count, cc_major, cc_minor, clock_khz / 1000, mem_khz / 1000, bus_bits, l2_bytes / 1024);

    int blocks = sm_count * BLOCKS_PER_SM;
    size_t rec_bytes = (size_t)blocks * 32;                           /* 4 x uint64 per block */
    size_t scr_bytes = (size_t)blocks * THREADS_PER_BLOCK * sizeof(float);

    CHECK(cuCtxCreate(&ctx, 0, dev));
    CHECK(cuModuleLoadData(&module, PTX));
    CHECK(cuModuleGetFunction(&kernel, module, "clk"));
    CHECK(cuMemAlloc(&rec_dev, rec_bytes));
    CHECK(cuMemAlloc(&scr_dev, scr_bytes));

    uint64_t *rec = malloc(rec_bytes);
    float *scr = malloc(scr_bytes);
    double *mhz = malloc(blocks * sizeof *mhz);
    void *params[] = { &iters, &rec_dev, &scr_dev };

    for (int k = 0; k < launches; k++) {
        CHECK(cuLaunchKernel(kernel, blocks, 1, 1, THREADS_PER_BLOCK, 1, 1, 0, NULL, params, NULL));
        CHECK(cuCtxSynchronize());
        CHECK(cuMemcpyDtoH(rec, rec_dev, rec_bytes));
        CHECK(cuMemcpyDtoH(scr, scr_dev, scr_bytes));

        /* per block: cycles / nanoseconds = GHz, times 1000 = MHz */
        uint64_t t_first = UINT64_MAX, t_last = 0;
        double sum = 0;
        for (int b = 0; b < blocks; b++) {
            uint64_t c0 = rec[b * 4], c1 = rec[b * 4 + 1], t0 = rec[b * 4 + 2], t1 = rec[b * 4 + 3];
            mhz[b] = t1 > t0 ? (double)(c1 - c0) * 1e3 / (double)(t1 - t0) : 0;
            sum += mhz[b];
            if (t0 < t_first) t_first = t0;
            if (t1 > t_last) t_last = t1;
        }
        qsort(mhz, blocks, sizeof *mhz, cmp_double);

        /* the first launch often shows the clock still ramping up: read the later ones */
        printf(french() ? "lancement %d : %.3f s ; fréquence réelle des SM : moyenne %.0f MHz (min %.0f, médiane %.0f, max %.0f) ; somme de contrôle des résultats %016llx\n"
                        : "launch %d: %.3f s; real SM clock: mean %.0f MHz (min %.0f, median %.0f, max %.0f); results checksum %016llx\n",
               k + 1, (t_last - t_first) * 1e-9, sum / blocks, mhz[0], mhz[blocks / 2], mhz[blocks - 1],
               (unsigned long long)fnv1a((const unsigned char *)scr, scr_bytes));
    }
    return 0;
}
