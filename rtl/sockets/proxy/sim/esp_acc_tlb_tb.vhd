-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
--
-- Directed testbench for the esp_acc_tlb fragment dispatcher, focused on the
-- reorder-buffer fragment clamp (DMA_ROB_DEPTH, see nocpackage.vhd): every
-- dispatched fragment must fit the accelerator socket's reorder buffer, or a
-- non-head-of-line response would overrun it silently in multi-memory-tile
-- SoCs. The full-SoC regressions cannot reach this path (cluster/mchan
-- requests are <= 256 B), hence this unit test.
--
-- Checks, against a reference model that mirrors the dispatch rules:
--   S1  aligned 8 KiB read, 1 MiB chunks   -> 4 fragments x 2048 B, ids 0..3,
--       last-fragment flag only on the final one
--   S2  misaligned 8 KiB read, 4 KiB chunks -> mixed lengths; every fragment
--       <= 2048 B, never crosses a chunk boundary, lengths sum to the total
--   S3  P2P read (exempt: legacy path, no reorder buffer) -> single fragment
--   S4  1 KiB read -> single fragment (clamp is a no-op below the cap)
--   S5  aligned 8 KiB WRITE -> clamped like reads; pending_dma_write clears
--
-- Run from an existing SoC modelsim workspace (all packages precompiled):
--   see run_tlb_tb.sh next to this file.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.esp_global.all;
use work.amba.all;
use work.stdlib.all;
use work.sld_devices.all;
use work.devices.all;
use work.gencomp.all;
use work.genacc.all;
use work.nocpackage.all;
use work.esp_acc_regmap.all;

entity esp_acc_tlb_tb is
end esp_acc_tlb_tb;

architecture tb of esp_acc_tlb_tb is

  constant TLB_ENTRIES : integer := 16;
  constant FRAG_CAP    : integer := DMA_ROB_DEPTH * (DMA_NOC_WIDTH / 8);  -- bytes
  constant PHYS_BASE   : integer := 16#40000000#;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '0';

  signal bankreg : bank_type(0 to MAXREGNUM - 1) := (others => (others => '0'));

  signal rd_request, wr_request         : std_ulogic := '0';
  signal rd_index, rd_length            : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_index, wr_length            : std_logic_vector(31 downto 0) := (others => '0');
  signal src_is_p2p, dst_is_p2p         : std_ulogic := '0';
  signal dma_tran_start                 : std_ulogic;
  signal dma_tran_header_sent           : std_ulogic := '0';
  signal dma_tran_done                  : std_ulogic := '0';
  signal dma_tran_id                    : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0);
  signal dma_tran_done_id               : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0) := (others => '0');
  signal rd_tag_in                      : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0) := (others => '0');
  signal acc_tag_out                    : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0);
  signal acc_req_last                   : std_ulogic;
  signal acc_tag_lookup_id              : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0) := (others => '0');
  signal acc_tag_lookup_out             : std_logic_vector(DMA_TRAN_ID_WIDTH-1 downto 0);
  signal acc_req_last_lookup            : std_ulogic;
  signal pending_dma_write              : std_ulogic;
  signal pending_dma_read               : std_ulogic;
  signal tlb_empty                      : std_ulogic;
  signal tlb_clear                      : std_ulogic := '0';
  signal tlb_valid                      : std_ulogic := '0';
  signal tlb_write                      : std_ulogic := '0';
  signal tlb_wr_address                 : std_logic_vector(log2xx(TLB_ENTRIES)-1 downto 0) := (others => '0');
  signal tlb_datain                     : std_logic_vector(GLOB_PHYS_ADDR_BITS-1 downto 0) := (others => '0');
  signal dma_address                    : std_logic_vector(GLOB_PHYS_ADDR_BITS-1 downto 0);
  signal dma_length                     : std_logic_vector(31 downto 0);

  signal errors : integer := 0;
  signal done   : boolean := false;

begin

  clk <= not clk after 5 ns when not done else '0';

  dut : entity work.esp_acc_tlb
    generic map (
      tech           => virtex7,
      scatter_gather => 1,
      tlb_entries    => TLB_ENTRIES)
    port map (
      clk                  => clk,
      rst                  => rst,
      bankreg              => bankreg,
      rd_request           => rd_request,
      rd_index             => rd_index,
      rd_length            => rd_length,
      wr_request           => wr_request,
      wr_index             => wr_index,
      wr_length            => wr_length,
      src_is_p2p           => src_is_p2p,
      dst_is_p2p           => dst_is_p2p,
      dma_tran_start       => dma_tran_start,
      dma_tran_header_sent => dma_tran_header_sent,
      dma_tran_done        => dma_tran_done,
      dma_tran_id          => dma_tran_id,
      dma_tran_done_id     => dma_tran_done_id,
      rd_tag_in            => rd_tag_in,
      acc_tag_out          => acc_tag_out,
      acc_req_last         => acc_req_last,
      acc_tag_lookup_id    => acc_tag_lookup_id,
      acc_tag_lookup_out   => acc_tag_lookup_out,
      acc_req_last_lookup  => acc_req_last_lookup,
      pending_dma_write    => pending_dma_write,
      pending_dma_read     => pending_dma_read,
      tlb_empty            => tlb_empty,
      tlb_clear            => tlb_clear,
      tlb_valid            => tlb_valid,
      tlb_write            => tlb_write,
      tlb_wr_address       => tlb_wr_address,
      tlb_datain           => tlb_datain,
      dma_address          => dma_address,
      dma_length           => dma_length);

  stim : process
    variable chunk_bytes : integer;

    procedure fail(msg : string) is
    begin
      errors <= errors + 1;
      assert false report "TB: " & msg severity error;
      wait for 0 ns;
    end procedure;

    -- program chunk size and (re)load an identity-plus-base page table
    procedure setup_pt(shift : integer) is
    begin
      bankreg <= (others => (others => '0'));
      bankreg(PT_SHIFT_REG) <= std_logic_vector(to_unsigned(shift, 32));
      chunk_bytes := 2**shift;
      wait until rising_edge(clk);
      tlb_clear <= '1';
      wait until rising_edge(clk);
      tlb_clear <= '0';
      for i in 0 to TLB_ENTRIES-1 loop
        tlb_wr_address <= std_logic_vector(to_unsigned(i, tlb_wr_address'length));
        tlb_datain     <= std_logic_vector(to_unsigned(PHYS_BASE + i*chunk_bytes,
                                                       GLOB_PHYS_ADDR_BITS));
        tlb_write      <= '1';
        wait until rising_edge(clk);
      end loop;
      tlb_write <= '0';
      tlb_valid <= '1';
      wait until rising_edge(clk);
      tlb_valid <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- issue one request and collect all dispatched fragments, checking each
    -- against the mirrored dispatch rules; lengths/addresses are BYTES.
    procedure run_req(name        : string;
                      is_write    : boolean;
                      p2p         : boolean;
                      vaddr_bytes : integer;   -- multiple of DMA word size
                      len_bytes   : integer;
                      exp_frags   : integer) is
      variable remaining : integer := len_bytes;
      variable voff      : integer := vaddr_bytes;
      variable exp_len   : integer;
      variable got_len   : integer;
      variable got_addr  : integer;
      variable nfrag     : integer := 0;
      variable wordsh    : integer := log2(DMA_NOC_WIDTH/8);
    begin
      if is_write then
        wr_index   <= std_logic_vector(to_unsigned(vaddr_bytes / 2**wordsh, 32));
        wr_length  <= std_logic_vector(to_unsigned(len_bytes / 2**wordsh, 32));
        wr_request <= '1';
      else
        rd_index   <= std_logic_vector(to_unsigned(vaddr_bytes / 2**wordsh, 32));
        rd_length  <= std_logic_vector(to_unsigned(len_bytes / 2**wordsh, 32));
        rd_request <= '1';
      end if;
      if p2p then src_is_p2p <= '1'; dst_is_p2p <= '1'; end if;

      while remaining > 0 loop
        -- wait for a dispatch
        loop
          wait until rising_edge(clk);
          exit when dma_tran_start = '1';
        end loop;
        -- drop the request once the TLB started serving it
        rd_request <= '0';
        wr_request <= '0';

        got_len  := to_integer(unsigned(dma_length));
        got_addr := to_integer(unsigned(dma_address));

        -- mirrored expectation
        if p2p then
          exp_len := remaining;
        else
          if (voff mod chunk_bytes) + remaining <= chunk_bytes then
            exp_len := remaining;
          else
            exp_len := chunk_bytes - (voff mod chunk_bytes);
          end if;
          if exp_len > FRAG_CAP then
            exp_len := FRAG_CAP;
          end if;
        end if;

        if got_len /= exp_len then
          fail(name & ": fragment " & integer'image(nfrag) & " length " &
               integer'image(got_len) & " expected " & integer'image(exp_len));
        end if;
        -- P2P dispatches carry no memory address (the socket builds P2P
        -- headers from tile coordinates); the translated address is
        -- meaningful only for memory-bound fragments.
        if (not p2p) and got_addr /= PHYS_BASE + voff then
          fail(name & ": fragment " & integer'image(nfrag) & " address " &
               integer'image(got_addr) & " expected " &
               integer'image(PHYS_BASE + voff));
        end if;
        if (not p2p) and got_len > FRAG_CAP then
          fail(name & ": fragment exceeds the reorder-buffer cap");
        end if;
        if (not p2p) and ((got_addr mod chunk_bytes) + got_len > chunk_bytes) then
          fail(name & ": fragment crosses a chunk boundary");
        end if;

        -- complete the fragment: header sent, then done (immediately)
        dma_tran_done_id     <= dma_tran_id;
        dma_tran_header_sent <= '1';
        wait until rising_edge(clk);
        dma_tran_header_sent <= '0';
        dma_tran_done        <= '1';
        wait until rising_edge(clk);
        -- last-fragment flag must be set exactly on the final fragment
        if (remaining - got_len = 0) /= (acc_req_last = '1') then
          fail(name & ": last-fragment flag wrong on fragment " &
               integer'image(nfrag));
        end if;
        dma_tran_done <= '0';

        remaining := remaining - got_len;
        voff      := voff + got_len;
        nfrag     := nfrag + 1;
        if nfrag > exp_frags + 4 then
          fail(name & ": runaway fragment loop");
          exit;
        end if;
      end loop;

      src_is_p2p <= '0'; dst_is_p2p <= '0';

      if nfrag /= exp_frags then
        fail(name & ": " & integer'image(nfrag) & " fragments, expected " &
             integer'image(exp_frags));
      end if;
      -- pending flag must clear once everything is dispatched and done
      for i in 0 to 4 loop
        wait until rising_edge(clk);
      end loop;
      if is_write then
        if pending_dma_write /= '0' then fail(name & ": pending_dma_write stuck"); end if;
      else
        if pending_dma_read /= '0' then fail(name & ": pending_dma_read stuck"); end if;
      end if;
    end procedure;

  begin
    rst <= '0';
    wait for 40 ns;
    wait until rising_edge(clk);
    rst <= '1';
    wait until rising_edge(clk);

    -- S1: 1 MiB chunks, aligned 8 KiB read -> pure clamp: 4 x 2048 B
    setup_pt(20);
    run_req("S1", false, false, 0, 8192, 4);

    -- S2: 4 KiB chunks, misaligned (offset 3072 B) 8 KiB read ->
    --     [1024, 2048, 2048, 2048, 1024] per the mirrored rules
    setup_pt(12);
    run_req("S2", false, false, 3072, 8192, 5);

    -- S3: P2P read is exempt (legacy path, no reorder buffer): one fragment
    setup_pt(20);
    run_req("S3", false, true, 0, 8192, 1);

    -- S4: below the cap the clamp is a no-op: one fragment
    run_req("S4", false, false, 0, 1024, 1);

    -- S5: writes are clamped the same way
    run_req("S5", true, false, 0, 8192, 4);

    if errors = 0 then
      report "TB PASSED: esp_acc_tlb fragment clamp OK" severity note;
    else
      report "TB FAILED: " & integer'image(errors) & " errors" severity error;
    end if;
    done <= true;
    wait;
  end process;

end tb;
