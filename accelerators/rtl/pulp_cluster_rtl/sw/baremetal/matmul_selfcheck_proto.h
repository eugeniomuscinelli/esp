/* Shared host<->cluster protocol for the self-checking matmul (Phase 1).
 *
 * Single source of truth for the exchange-region layout: included by BOTH the
 * host app (pulp_cluster.c, via the generated stimuli header) and the cluster
 * test (sw/cluster_tests/matmul_selfcheck/matmul_selfcheck.c). If the two
 * sides are built from different versions of this file the run fails loudly
 * (the host checks MM_PERF_MAGIC and MM_PERF_N after completion).
 *
 * All offsets are relative to the L2 window base = the DMA buffer start
 * (= BASE_ADDRESS of the program-image header; equality is _Static_assert'ed
 * in the host app - four-constant invariant, plan risk R7).
 *
 * Region choice (evidence in the Phase-1 report section): the program image +
 * pulp-runtime data end below window+0x14000 and the runtime's shared-L2 heap
 * has no consumers in this test, so +0x80000..+0x90000 is conflict-free; the
 * host buffer (bump-allocated at 0xa0100000 in simulated DDR) ends ~434 KiB
 * clear of the 2 MiB axi_ram_sim wrap. 16 KiB per matrix slot = room up to
 * 64x64 int32; N=8/16/32 supported today.
 */
#ifndef MATMUL_SELFCHECK_PROTO_H
#define MATMUL_SELFCHECK_PROTO_H

#define MM_L2_BASE 0xA0103680u /* must equal BASE_ADDRESS / wrapper L2BaseAddr */

#ifndef MM_N
#define MM_N 8 /* matrix dimension: 8, 16 or 32 - REBUILD BOTH SIDES on change */
#endif

/* exchange region: int32 row-major matrices + a small perf/status block */
#define MM_A_OFFS    0x00080000u /* A[N][N], written by the host before start  */
#define MM_B_OFFS    0x00084000u /* B[N][N], written by the host before start  */
#define MM_C_OFFS    0x00088000u /* C[N][N], written by the cluster            */
#define MM_PERF_OFFS 0x0008C000u /* perf/status block, written by the cluster  */
#define MM_END_OFFS  0x00090000u /* host DMA buffer must span at least this    */

#define MM_DONE_MAGIC 0x4D4D4F4Bu /* "MMOK" - cluster completed + wrote perf */

/* perf block layout: uint32 word indices at MM_PERF_OFFS. MAGIC is written
 * LAST by the cluster, so the host never sees it before the data words.
 *
 * Cycle counts and their windows (load-bearing definitions for the Phase-2
 * comparison - full rationale in the report):
 *   DMA_IN/COMPUTE/DMA_OUT/TOTAL are WALL-CLOCK cluster cycles from the
 *   free-running cluster timer (never clock-gated), snapshotted on core 0:
 *     t0 | mchan DMA A+B (L2->TCDM) | t1 | barrier, 8-core MAC, barrier | t2 |
 *     mchan DMA C (TCDM->L2) | t3
 *   DMA_IN=t1-t0  COMPUTE=t2-t1  DMA_OUT=t3-t2  TOTAL=t3-t0.
 *   COMPUTE includes the two barrier crossings and the per-core counter
 *   enable (same convention as the reference test's 'execution time').
 *   Excluded everywhere: boot/crt0, host setup, result checking, printf.
 *   COMPUTE_ACT0 is core-0's PCCR0 (ACTIVE cycles - frozen while the event
 *   unit clock-gates the core, so NOT wall clock) over its own MAC slice.
 *   CAL is one back-to-back timer-read pair (per-snapshot read overhead). */
#define MM_PERF_MAGIC        0 /* MM_DONE_MAGIC when the cluster finished    */
#define MM_PERF_N            1 /* MM_N the cluster image was built with      */
#define MM_PERF_DMA_IN       2 /* wall cycles: DMA A+B, L2 window -> TCDM    */
#define MM_PERF_COMPUTE      3 /* wall cycles: barrier + 8-core MAC + barrier */
#define MM_PERF_DMA_OUT      4 /* wall cycles: DMA C, TCDM -> L2 window      */
#define MM_PERF_TOTAL        5 /* wall cycles: t3 - t0 (superset)            */
#define MM_PERF_COMPUTE_ACT0 6 /* PCCR0 active cycles, core 0 MAC slice only */
#define MM_PERF_CAL          7 /* timer read-to-read overhead (cycles)       */
#define MM_PERF_WORDS        8

/* deterministic input pattern: the host fills A and B with these values and
 * computes the golden result from the same buffer it hands to the cluster.
 * Small magnitudes: |A|<=30, |B|<=26 -> |C| <= 32*780 = 24960, no int32
 * overflow at any supported MM_N. */
#define MM_A_VAL(i, j) ((int32_t)((((i) * 7 + (j) * 3) % 61) - 30))
#define MM_B_VAL(i, j) ((int32_t)((((i) * 5 + (j) * 11) % 53) - 26))

#endif /* MATMUL_SELFCHECK_PROTO_H */
