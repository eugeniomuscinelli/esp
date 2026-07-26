/* Self-checking, performance-sampled NxN int32 matmul for the PULP cluster
 * in ESP (Phase 1 baseline test).
 *
 * Protocol (matmul_selfcheck_proto.h, shared with the host app):
 *   - the HOST writes A and B into the L2-window exchange region before start;
 *   - core 0 DMAs A,B into TCDM (mchan), all 8 cores compute a row-split
 *     product, core 0 DMAs C back and fills the perf block (magic last);
 *   - the HOST recomputes the product on Ariane and compares element-wise.
 *
 * Cycle windows are defined in the proto header; wall clock comes from the
 * free-running cluster timer (HI half, never clock-gated), the secondary
 * COMPUTE_ACT0 number from core-0's PCCR0 (active cycles). Rationale: the
 * RI5CY perf counters freeze while the event unit clock-gates a sleeping
 * core (DMA waits, barriers), so they would hide exactly the memory-path
 * latency the Phase-2 comparison needs to see.
 *
 * Structure modeled on the proven regression test
 * cluster_generator/regression-tests/astral/parMatrixMul32_esp/matrixMul.c
 * (same runtime APIs: plp_dma_memcpy/plp_dma_wait, synch_barrier,
 * reset_timer/start_timer/get_time, perf_reset/start/stop/cpu_perf_get);
 * builds generic RV32IMC per report section 10.3.
 */
#include <stdint.h>
#include "pulp.h"
#include "matmul_selfcheck_proto.h"

#define N MM_N
_Static_assert(N % 8 == 0 && N <= 64, "N must be a multiple of 8, <= 64");
_Static_assert(N * N * 4 < 65536, "mchan plp_dma_memcpy size field is 16-bit");

/* TCDM working set: uninitialized by design (DMA fills A/B, cores write C) */
__attribute__((section(".heapsram"))) static int32_t a_l1[N * N];
__attribute__((section(".heapsram"))) static int32_t b_l1[N * N];
__attribute__((section(".heapsram"))) static int32_t c_l1[N * N];

#define MM_A_L2 (MM_L2_BASE + MM_A_OFFS)
#define MM_B_L2 (MM_L2_BASE + MM_B_OFFS)
#define MM_C_L2 (MM_L2_BASE + MM_C_OFFS)
#define MM_PERF ((volatile uint32_t *)(MM_L2_BASE + MM_PERF_OFFS))

int main(void)
{
    const unsigned core = rt_core_id();
    const unsigned nc   = get_core_num();
    const int      cid  = (int)get_cluster_id();
    const unsigned rows = N / nc;
    uint32_t t0 = 0, t1 = 0, t2 = 0, t3 = 0, cal = 0, act0 = 0;

    if (core == 0) {
        reset_timer(cid);
        start_timer(cid); /* free-running from here on; we only take snapshots */
        {
            uint32_t ca = (uint32_t)get_time(cid);
            uint32_t cb = (uint32_t)get_time(cid);
            cal = cb - ca;
        }
        t0 = (uint32_t)get_time(cid);
        plp_dma_wait(plp_dma_memcpy(MM_A_L2, (unsigned int)a_l1,
                                    (unsigned short)(N * N * 4), PLP_DMA_EXT2LOC));
        plp_dma_wait(plp_dma_memcpy(MM_B_L2, (unsigned int)b_l1,
                                    (unsigned short)(N * N * 4), PLP_DMA_EXT2LOC));
        __asm__ volatile("" ::: "memory"); /* DMA'd data is outside compiler view */
        t1 = (uint32_t)get_time(cid);
    }
    synch_barrier();

    /* per-core active-cycle counter around the MAC slice only */
    perf_reset();
    perf_start();
    for (unsigned i = core * rows; i < (core + 1) * rows; i++)
        for (unsigned j = 0; j < N; j++) {
            int32_t acc = 0;
            for (unsigned k = 0; k < N; k++)
                acc += a_l1[i * N + k] * b_l1[k * N + j];
            c_l1[i * N + j] = acc;
        }
    perf_stop();
    if (core == 0)
        act0 = cpu_perf_get(0);
    synch_barrier();

    if (core == 0) {
        t2 = (uint32_t)get_time(cid);
        __asm__ volatile("" ::: "memory"); /* order c_l1 stores before DMA-out */
        plp_dma_wait(plp_dma_memcpy(MM_C_L2, (unsigned int)c_l1,
                                    (unsigned short)(N * N * 4), PLP_DMA_LOC2EXT));
        t3 = (uint32_t)get_time(cid);

        MM_PERF[MM_PERF_N]            = N;
        MM_PERF[MM_PERF_DMA_IN]       = t1 - t0;
        MM_PERF[MM_PERF_COMPUTE]      = t2 - t1;
        MM_PERF[MM_PERF_DMA_OUT]      = t3 - t2;
        MM_PERF[MM_PERF_TOTAL]        = t3 - t0;
        MM_PERF[MM_PERF_COMPUTE_ACT0] = act0;
        MM_PERF[MM_PERF_CAL]          = cal;
        MM_PERF[MM_PERF_MAGIC]        = MM_DONE_MAGIC; /* last */
        (void)MM_PERF[MM_PERF_MAGIC]; /* read-back: drains the posted writes
                                       * through the serializing translator
                                       * before the runtime raises EoC */

        printf("[mm] N=%d dma_in=%u compute=%u dma_out=%u total=%u act0=%u cal=%u\n",
               N, (unsigned)(t1 - t0), (unsigned)(t2 - t1), (unsigned)(t3 - t2),
               (unsigned)(t3 - t0), (unsigned)act0, (unsigned)cal);
    }
    synch_barrier();
    return 0; /* runtime: core 0 writes return reg + EoC, cores sleep */
}
