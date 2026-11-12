/*
 * minictx.c — only creates/destroys CUDA contexts, no DMA at all
 *
 * Purpose (reports/195):
 *   It has been proven that `_nv017281rm` runs on every cuCtxCreate, and when
 *   sp==1 it goes through `_nv053912rm(CX=0x8c040, R8=SPEED)` to write
 *   0x8C040's SPEED as SPEED=2 (2.5GT/s). The patch changes that site to
 *   SPEED=1 (5.0GT/s).
 *
 *   To verify "can the link rise to Gen2 by itself after the patch", bwtest2
 *   must not be used — it does tens of MB of real DMA right after creating the
 *   context, and if the link re-speeds after RM has already initialized, that
 *   easily triggers Xid 79 (GPU fallen off the bus).
 *
 *   This program only does cuInit -> cuCtxCreate -> cuCtxDestroy, letting that
 *   SPEED write happen (that is exactly what we want to observe) while moving
 *   no data.
 *
 * No CUDA toolkit dependency: dlopen libcuda.so.1 and fetch the driver API
 * entry points by hand.
 * Build:  gcc -O2 -o minictx minictx.c -ldl
 * Usage:  ./minictx [rounds]
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int CUresult;
typedef int CUdevice;
typedef void *CUcontext;

int main(int argc, char **argv)
{
    int rounds = (argc > 1) ? atoi(argv[1]) : 1;
    if (rounds < 1) rounds = 1;

    void *h = dlopen("libcuda.so.1", RTLD_NOW);
    if (!h) h = dlopen("libcuda.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen libcuda failed: %s\n", dlerror()); return 1; }

    CUresult (*cuInit)(unsigned) = dlsym(h, "cuInit");
    CUresult (*cuDeviceGet)(CUdevice *, int) = dlsym(h, "cuDeviceGet");
    CUresult (*cuCtxCreate)(CUcontext *, unsigned, CUdevice) = dlsym(h, "cuCtxCreate_v2");
    CUresult (*cuCtxDestroy)(CUcontext) = dlsym(h, "cuCtxDestroy_v2");
    const char *(*cuGetErrorString)(CUresult, const char **) = dlsym(h, "cuGetErrorString");

    if (!cuInit || !cuDeviceGet || !cuCtxCreate || !cuCtxDestroy) {
        fprintf(stderr, "missing driver API entry points\n");
        return 1;
    }
    /* fall back to the unsuffixed names when cuCtxCreate_v2 is absent */
    if (!cuCtxCreate) cuCtxCreate = dlsym(h, "cuCtxCreate");
    if (!cuCtxDestroy) cuCtxDestroy = dlsym(h, "cuCtxDestroy");

    CUresult r = cuInit(0);
    if (r) { fprintf(stderr, "cuInit failed %d\n", r); return 1; }

    CUdevice dev;
    r = cuDeviceGet(&dev, 0);
    if (r) { fprintf(stderr, "cuDeviceGet failed %d\n", r); return 1; }

    for (int i = 0; i < rounds; i++) {
        CUcontext ctx = NULL;
        r = cuCtxCreate(&ctx, 0, dev);   /* ★ this triggers _nv017281rm */
        if (r) {
            const char *s = NULL;
            if (cuGetErrorString) cuGetErrorString(r, &s);
            fprintf(stderr, "round %d cuCtxCreate failed %d (%s)\n", i + 1, r, s ? s : "?");
            return 2;
        }
        printf("round %d ctx created (%p)\n", i + 1, ctx);
        fflush(stdout);
        usleep(200000);
        r = cuCtxDestroy(ctx);
        if (r) { fprintf(stderr, "round %d cuCtxDestroy failed %d\n", i + 1, r); return 3; }
        printf("round %d ctx destroyed\n", i + 1);
        fflush(stdout);
        usleep(200000);
    }
    printf("done %d rounds, no DMA\n", rounds);
    return 0;
}
