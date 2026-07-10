/* Bare-metal host application for the PULP cluster accelerator tile.
 *
 * Ported from the reference integration
 * (esp_first_pulp_integration .../sw/baremetal/pulp_cluster.c) with the Step 7
 * fixes from the integration plan:
 *   - the program image header is selected below and must exist (the reference
 *     shipped including a non-existent file);
 *   - the boot_offset user register carries the entry offset within the buffer
 *     (default 0x8080 = pulp-runtime _start); the reference wrote the raw buffer
 *     pointer into reg1 and relied on an allocator coincidence;
 *   - the buffer is sized from the actual stimuli span (works for both dense
 *     generate_padded_stimuli.py headers and sparse hand-generated ones);
 *   - rung-2 self-check: if the header defines RUNG2_MAGIC64, the host verifies
 *     the cluster's memory write after completion.
 *
 * Program image headers (Stimulus{address,instruction}/BASE_ADDRESS/NUM_STIMULI):
 *   rung2_smoke.h       - toolchain-free smoke test (validation rung 2)
 *   stimuli.h           - pulp-runtime printf test  (validation rung 3)
 *   optmatmul_M8_8x8.h  - 8x8 matmul benchmark      (validation rung 4)
 */

#ifndef HEADER_FILE
#define HEADER_FILE "rung2_smoke.h"
#endif

#include <stdio.h>
#ifndef __riscv
#include <stdlib.h>
#endif

#include <esp_accelerator.h>
#include <esp_probe.h>

#include HEADER_FILE

#define SLD_PULP_CLUSTER 0x075
#define DEV_NAME "sld,pulp_cluster_rtl"

/* user registers (bank indices 16/17/18, see hw/pulp_cluster.xml) */
#define PULP_CLUSTER_BOOT_OFFSET_REG 0x40
#define PULP_CLUSTER_SPARE0_REG 0x44
#define PULP_CLUSTER_SPARE1_REG 0x48

/* entry offset within the accelerator buffer: pulp-runtime _start
 * (vector table at L2+0x8000, entry at +0x80) */
#ifndef BOOT_OFFSET
#define BOOT_OFFSET 0x8080
#endif

#define CHUNK_SHIFT 20
#define CHUNK_SIZE  BIT(CHUNK_SHIFT)
#define NCHUNK(_sz) ((_sz % CHUNK_SIZE == 0) ? (_sz / CHUNK_SIZE) : (_sz / CHUNK_SIZE) + 1)

int main(int argc, char *argv[])
{
    int n;
    int ndev;
    struct esp_device *espdevs;
    struct esp_device *dev;
    unsigned done;
    unsigned **ptable;
    uint64_t *mem;
    unsigned mem_size;
    unsigned span_words;
    unsigned coherence;
    unsigned i;

    /* buffer must span every stimulus address (dense or sparse headers) */
    span_words = (unsigned)((stimuli[NUM_STIMULI - 1].address - BASE_ADDRESS) / sizeof(uint64_t)) + 1;
    for (i = 0; i < NUM_STIMULI; i++) {
        unsigned w = (unsigned)((stimuli[i].address - BASE_ADDRESS) / sizeof(uint64_t)) + 1;
        if (w > span_words)
            span_words = w;
    }
    mem_size = span_words * sizeof(uint64_t);

    printf("[pulp] image: %s (%d stimuli, buffer %u KiB)\n", HEADER_FILE, NUM_STIMULI,
           mem_size >> 10);

    ndev = probe(&espdevs, VENDOR_SLD, SLD_PULP_CLUSTER, DEV_NAME);
    if (ndev == 0) {
        printf("[pulp] %s not found\n", DEV_NAME);
        return 0;
    }

    for (n = 0; n < ndev; n++) {

        dev = &espdevs[n];
        printf("[pulp] **************** %s.%d ****************\n", DEV_NAME, n);

        if (ioread32(dev, PT_NCHUNK_MAX_REG) == 0) {
            printf("[pulp] scatter-gather DMA not supported\n");
            return 0;
        }
        if (ioread32(dev, PT_NCHUNK_MAX_REG) < NCHUNK(mem_size)) {
            printf("[pulp] not enough TLB entries for %u chunks\n", NCHUNK(mem_size));
            return 0;
        }

        mem = aligned_malloc(mem_size);
        ptable = aligned_malloc(NCHUNK(mem_size) * sizeof(unsigned *));
        for (i = 0; i < NCHUNK(mem_size); i++)
            ptable[i] = (unsigned *)&mem[i * (CHUNK_SIZE / sizeof(uint64_t))];

        printf("[pulp] buffer @%p, %u chunk(s)\n", (void *)mem, NCHUNK(mem_size));

        /* zero the buffer, then load the program image:
         * word index = (cluster address - L2 window base) / 8 */
        for (i = 0; i < span_words; i++)
            mem[i] = 0;
        for (i = 0; i < NUM_STIMULI; i++)
            mem[(stimuli[i].address - BASE_ADDRESS) / sizeof(uint64_t)] = stimuli[i].instruction;

        coherence = ACC_COH_NONE;

        iowrite32(dev, COHERENCE_REG, coherence);
        iowrite32(dev, PT_ADDRESS_REG, (unsigned)(unsigned long)ptable);
        iowrite32(dev, PT_NCHUNK_REG, NCHUNK(mem_size));
        iowrite32(dev, PT_SHIFT_REG, CHUNK_SHIFT);
        iowrite32(dev, SRC_OFFSET_REG, 0x0);
        iowrite32(dev, DST_OFFSET_REG, 0x0);

        /* user registers: entry offset within the buffer (NOT a pointer) */
        iowrite32(dev, PULP_CLUSTER_BOOT_OFFSET_REG, BOOT_OFFSET);
        iowrite32(dev, PULP_CLUSTER_SPARE0_REG, 0);
        iowrite32(dev, PULP_CLUSTER_SPARE1_REG, 0);

        esp_flush(coherence);

        printf("[pulp] start (boot = window base + 0x%x)\n", BOOT_OFFSET);
        iowrite32(dev, CMD_REG, CMD_MASK_START);

        done = 0;
        while (!done) {
            done = ioread32(dev, STATUS_REG);
            done &= STATUS_MASK_DONE;
        }
        iowrite32(dev, CMD_REG, 0x0);
        printf("[pulp] done (cluster raised eoc)\n");

#ifdef RUNG2_MAGIC64
        {
            uint64_t got = mem[RUNG2_CHECK_OFFSET / sizeof(uint64_t)];
            if (got == RUNG2_MAGIC64) {
                printf("[pulp] RUNG2 PASS: buffer[0x%x] = expected magic\n", RUNG2_CHECK_OFFSET);
            } else {
                printf("[pulp] RUNG2 FAIL: buffer[0x%x] = %08x%08x (expected %08x%08x)\n",
                       RUNG2_CHECK_OFFSET,
                       (unsigned)(got >> 32), (unsigned)got,
                       (unsigned)(RUNG2_MAGIC64 >> 32), (unsigned)RUNG2_MAGIC64);
            }
        }
#else
        /* generic result window dump for visual inspection */
        printf("[pulp] buffer tail dump:\n");
        for (i = span_words > 8 ? span_words - 8 : 0; i < span_words; i++)
            printf("[pulp]   [0x%08x] = %08x%08x\n",
                   (unsigned)(BASE_ADDRESS + i * sizeof(uint64_t)),
                   (unsigned)(mem[i] >> 32), (unsigned)mem[i]);
#endif

        aligned_free(ptable);
        aligned_free(mem);
    }

    return 0;
}
