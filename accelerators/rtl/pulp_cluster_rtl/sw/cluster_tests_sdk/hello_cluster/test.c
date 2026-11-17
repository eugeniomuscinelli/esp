/*
 * hello_cluster - first pulp-sdk (PulpOS 2 / PMSIS) test for the ESP-integrated
 * PULP cluster. Counterpart of sw/cluster_tests/matmul_selfcheck, but built
 * against the retargeted pulp-sdk instead of pulp-runtime.
 *
 * What it proves, in one run:
 *   1. the SDK-built image boots on the cluster at all (crt0, no-FC init path)
 *   2. all eight PEs are released and reach main (per-core presence words)
 *   3. the hardware barrier works in the SPMD entry model (pi_cl_team_barrier)
 *   4. printf reaches the wrapper's mock UART
 *   5. the cluster can write the L2 window where the host can read it back
 *   6. end-of-computation propagates to acc_done
 *
 * Host side needs no changes: gen_header.sh emits RUNG2_CHECK_OFFSET and
 * RUNG2_MAGIC64 into the generated header, which switches on the existing
 * rung-2 verification in sw/baremetal/pulp_cluster.c.
 *
 * printf is deliberately core-0 only. The wrapper's mock UART decodes
 * (addr >> 2) & 0x7 and only register index 0 prints, while PulpOS's stdout
 * address is ARCHI_STDOUT_ADDR + (core_id << 3): cores 1,2,3,5,6,7 would land
 * on FCR/MCR/MSR and vanish silently, and cores 0 and 4 would interleave into
 * one garbled line.
 */

#include "pmsis.h"
#include <stdint.h>

/* Written last by core 0. The host compares it against RUNG2_MAGIC64.
 * Deliberately an *initialised* L2 global rather than a hard-coded window
 * offset: that keeps it inside the program image, so it is covered by the
 * stimuli (and therefore by the host's DMA buffer) automatically, and
 * gen_header.sh derives its offset from the ELF symbol table. The initial
 * value is a sentinel - if the host reads it back, the cluster never got as
 * far as writing the magic. */
#define ESP_SENTINEL64  0xDEADBEEFDEADBEEFULL
#define ESP_MAGIC32     0x5DC0FFEEu

volatile uint64_t esp_check_word = ESP_SENTINEL64;

/* One slot per PE, so the host (and a waveform) can see which cores ran. */
#define ESP_NB_PE 8
volatile uint32_t esp_core_seen[ESP_NB_PE];

int main(void)
{
    unsigned int core = pi_core_id();

    /* Every PE marks itself present. */
    if (core < ESP_NB_PE)
        esp_core_seen[core] = 0xC0DE0000u | core;

    /* Hardware barrier: all PEs must arrive before core 0 reports. */
    pi_cl_team_barrier();

    if (core == 0)
    {
        unsigned int seen = 0;

        for (unsigned int i = 0; i < ESP_NB_PE; i++)
            if (esp_core_seen[i] == (0xC0DE0000u | i))
                seen++;

        printf("[sdk] hello from cluster %d, %d/%d cores reported! wow\n",
               pi_cluster_id(), seen, ESP_NB_PE);

        /* Written last: the host treats it as the completion flag. Only claim
         * success if every PE actually checked in. */
        if (seen == ESP_NB_PE)
            esp_check_word = ((uint64_t)ESP_MAGIC32 << 32) | ESP_MAGIC32;

        /* Read back before returning, to push the posted write out through the
         * serialising AXI-to-DMA translator ahead of the EoC that follows. */
        (void)esp_check_word;
    }

    /* Runtime raises EoC on core 0 after main returns on every PE. */
    return 0;
}
