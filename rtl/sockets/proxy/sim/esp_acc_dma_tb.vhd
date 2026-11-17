-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
--
-- Directed testbench for the accelerator socket (esp_acc_dma + esp_acc_tlb).
-- The socket is driven from both sides: an accelerator-side model issues
-- read/write requests and checks every data beat, and a memory-side model
-- answers the requests the socket puts on the DMA plane. The data pattern is
-- a function of the physical address, so a wrong address, a lost beat or a
-- reordered beat all show up as a data mismatch.
--
-- The scenarios target the paths the full-SoC regressions cannot reach
-- (multi-fragment requests, out-of-order responses, software reset with
-- reads in flight, P2P next to counted reads, no scatter-gather):
--
--   generic SG = 1 (scatter-gather, 4 KiB chunks alternating on two memory tiles)
--     T1   single read
--     T2   two back-to-back reads, in-order responses
--     T3   two back-to-back reads, responses swapped (reorder buffer)
--     T3b  three-fragment read + a second read, responses swapped pairwise
--     T4   three-fragment read with the next read requested right after its
--          grant (a grant must never be lost)
--     T4w  same for writes
--     T5a  software reset with two reads in flight
--     T5b  software reset in the middle of a three-fragment read
--     T6   write then read, single-beat transfers included
--     T7   mixed reads/writes with random back-pressure on every channel
--     T8   P2P read requested while a counted read is in flight
--   generic SG = 0 (no scatter-gather)
--     N1   write then read at different addresses
--     N2   two back-to-back reads
--     N3   two back-to-back writes
--
-- The expected number of outstanding reads follows CFG_DMA_MAX_READS, so the
-- same testbench runs in classic and multiOT configurations.
--
-- Run from an existing SoC modelsim workspace (all packages precompiled):
--   see run_dma_tb.sh next to this file.

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
use work.monitor_pkg.all;
use work.nocpackage.all;
use work.cachepackage.all;
use work.tile.all;
use work.esp_acc_regmap.all;

entity esp_acc_dma_tb is
  generic (
    SG : integer range 0 to 1 := 1);
end esp_acc_dma_tb;

architecture tb of esp_acc_dma_tb is

  constant TLB_ENTRIES : integer := 16;
  constant NCHUNK      : integer := 8;
  constant CHUNK_SHIFT : integer := 12;
  constant CHUNK_BYTES : integer := 2**CHUNK_SHIFT;
  constant FLIT_BYTES  : integer := DMA_NOC_WIDTH / 8;
  constant MAX_OT      : integer := CFG_DMA_MAX_READS;

  constant PT_ADDR         : unsigned(31 downto 0) := x"10000000";
  constant NOSG_SRC_OFFSET : unsigned(31 downto 0) := x"40000000";
  constant NOSG_DST_OFFSET : unsigned(31 downto 0) := x"80000000";

  subtype word_t is std_logic_vector(DMA_NOC_WIDTH - 1 downto 0);
  subtype tag_t is std_logic_vector(DMA_ACC_TAG_WIDTH - 1 downto 0);

  -- Two memory tiles: 0x4xxxxxxx and 0x8xxxxxxx
  constant TB_MEM_INFO : tile_mem_info_vector(0 to CFG_NMEM_TILE + CFG_NSLM_TILE + CFG_NSLMDDR_TILE) := (
    0      => (x => std_logic_vector(to_unsigned(0, YX_WIDTH)),
               y => std_logic_vector(to_unsigned(0, YX_WIDTH)),
               haddr => 16#400#, hmask => 16#C00#),
    1      => (x => std_logic_vector(to_unsigned(1, YX_WIDTH)),
               y => std_logic_vector(to_unsigned(1, YX_WIDTH)),
               haddr => 16#800#, hmask => 16#C00#),
    others => tile_mem_info_none);

  -- Physical base of virtual chunk c: even chunks on tile 0, odd on tile 1
  function chunk_base (c : natural) return unsigned is
    variable b : unsigned(31 downto 0);
  begin
    if c mod 2 = 0 then
      b := x"40000000";
    else
      b := x"80000000";
    end if;
    return b + to_unsigned(c * 16#100000#, 32);
  end chunk_base;

  -- Virtual byte offset -> physical address (scatter-gather)
  function v2p (v : natural) return unsigned is
  begin
    return chunk_base(v / CHUNK_BYTES) + to_unsigned(v mod CHUNK_BYTES, 32);
  end v2p;

  -- Memory content at physical address a
  function pattern (a : unsigned(31 downto 0)) return word_t is
    variable w : word_t := (others => '0');
  begin
    w(63 downto 32) := std_logic_vector(a);
    w(31 downto 0)  := not std_logic_vector(a);
    return w;
  end pattern;

  -- Data produced by the P2P source model
  function p2p_pattern (k : natural) return word_t is
    variable w : word_t := (others => '0');
  begin
    w(63 downto 32) := x"B2B2B2B2";
    w(31 downto 0)  := std_logic_vector(to_unsigned(k, 32));
    return w;
  end p2p_pattern;

  constant QMAX : integer := 16384;
  type word_arr is array (0 to QMAX - 1) of word_t;
  type tag_arr is array (0 to QMAX - 1) of tag_t;
  type bit_arr is array (0 to QMAX - 1) of std_ulogic;

  -- Scoreboard for the accelerator read channel (filled at request time)
  shared variable exp_data     : word_arr;
  shared variable exp_tag      : tag_arr;
  shared variable exp_last     : bit_arr;
  shared variable exp_wr       : integer := 0;
  shared variable exp_rd       : integer := 0;
  -- Data the accelerator model will write
  shared variable wq_data      : word_arr;
  shared variable wq_wr        : integer := 0;
  shared variable wq_rd        : integer := 0;
  shared variable w_flits_exp  : integer := 0;
  -- Memory-model statistics
  shared variable w_flits_rx   : integer := 0;
  shared variable stat_max_ot  : integer := 0;
  shared variable errors       : integer := 0;

  procedure err (msg : string) is
  begin
    errors := errors + 1;
    if errors <= 25 then
      report "ERROR: " & msg severity error;
    end if;
  end err;

  signal clk : std_ulogic := '0';
  signal rst : std_ulogic := '0';
  signal done : boolean := false;

  -- Testbench control
  signal tb_flush  : std_ulogic := '0';
  signal m_latency : integer := 0;      -- cycles before a counted read is answered
  signal m_swap    : boolean := false;  -- answer counted reads pairwise swapped
  signal m_bp      : boolean := false;  -- random dma_snd_full
  signal a_bp      : boolean := false;  -- random bufdin_ready
  signal w_bp      : boolean := false;  -- random bufdout_valid

  -- DUT ports
  signal apbi : apb_slv_in_type;
  signal apbo : apb_slv_out_type;
  signal bank : bank_type(0 to MAXREGNUM - 1);
  signal bankdef : bank_type(0 to MAXREGNUM - 1) := (others => (others => '0'));
  signal acc_rst, conf_done : std_ulogic;
  signal rd_request : std_ulogic := '0';
  signal rd_index, rd_length : std_logic_vector(31 downto 0) := (others => '0');
  signal rd_size : std_logic_vector(2 downto 0) := "011";
  signal rd_source : std_logic_vector(5 downto 0) := (others => '0');
  signal rd_tag_in : tag_t := (others => '0');
  signal rd_grant : std_ulogic;
  signal bufdin_ready : std_ulogic := '0';
  signal bufdin_data : word_t;
  signal bufdin_valid : std_ulogic;
  signal bufdin_tag : tag_t;
  signal bufdin_last : std_ulogic;
  signal wr_request : std_ulogic := '0';
  signal wr_index, wr_length : std_logic_vector(31 downto 0) := (others => '0');
  signal wr_size : std_logic_vector(2 downto 0) := "011";
  signal wr_ndests : std_logic_vector(5 downto 0) := (others => '0');
  signal wr_grant : std_ulogic;
  signal bufdout_ready : std_ulogic;
  signal bufdout_data : word_t := (others => '0');
  signal bufdout_valid : std_ulogic := '0';
  signal acc_done : std_ulogic := '0';
  signal dma_rcv_rdreq : std_ulogic;
  signal dma_rcv_data_out : dma_noc_flit_type := (others => '0');
  signal dma_rcv_empty : std_ulogic := '1';
  signal dma_snd_wrreq : std_ulogic;
  signal dma_snd_data_in : dma_noc_flit_type;
  signal dma_snd_full : std_ulogic := '0';

  -- The accelerator model is idle between a software reset and the next start
  signal acc_soft_reset_seen : std_ulogic := '0';

begin

  assert DMA_NOC_WIDTH = 64 and ARCH_BITS = 64 and GLOB_PHYS_ADDR_BITS = 32
    report "esp_acc_dma_tb assumes a 64-bit DMA NoC, 64-bit CPU and 32-bit physical addresses"
    severity failure;

  clk <= not clk after 5 ns when not done else '0';

  dut : entity work.esp_acc_dma
    generic map (
      tech           => virtex7,
      mem_num        => 2,
      mem_info       => TB_MEM_INFO,
      io_y           => std_logic_vector(to_unsigned(1, YX_WIDTH)),
      io_x           => std_logic_vector(to_unsigned(0, YX_WIDTH)),
      pindex         => 0,
      devid          => 16#075#,
      scatter_gather => SG,
      has_l2         => 0,
      tlb_entries    => TLB_ENTRIES)
    port map (
      rst                          => rst,
      clk                          => clk,
      local_y                      => std_logic_vector(to_unsigned(0, YX_WIDTH)),
      local_x                      => std_logic_vector(to_unsigned(1, YX_WIDTH)),
      paddr                        => 16#100#,
      pmask                        => 16#fff#,
      pirq                         => 6,
      apbi                         => apbi,
      apbo                         => apbo,
      bank                         => bank,
      bankdef                      => bankdef,
      acc_rst                      => acc_rst,
      conf_done                    => conf_done,
      rd_request                   => rd_request,
      rd_index                     => rd_index,
      rd_length                    => rd_length,
      rd_size                      => rd_size,
      rd_source                    => rd_source,
      rd_tag_in                    => rd_tag_in,
      rd_grant                     => rd_grant,
      bufdin_ready                 => bufdin_ready,
      bufdin_data                  => bufdin_data,
      bufdin_valid                 => bufdin_valid,
      bufdin_tag                   => bufdin_tag,
      bufdin_last                  => bufdin_last,
      wr_request                   => wr_request,
      wr_index                     => wr_index,
      wr_length                    => wr_length,
      wr_size                      => wr_size,
      wr_ndests                    => wr_ndests,
      wr_grant                     => wr_grant,
      bufdout_ready                => bufdout_ready,
      bufdout_data                 => bufdout_data,
      bufdout_valid                => bufdout_valid,
      acc_done                     => acc_done,
      flush                        => open,
      acc_flush_done               => '0',
      mon_dvfs                     => open,
      acc_activity                 => open,
      coherent_dma_read            => open,
      coherent_dma_write           => open,
      coherent_dma_length          => open,
      coherent_dma_address         => open,
      coherent_dma_ready           => '0',
      llc_coherent_dma_rcv_rdreq   => open,
      llc_coherent_dma_rcv_data_out => (others => '0'),
      llc_coherent_dma_rcv_empty   => '1',
      llc_coherent_dma_snd_wrreq   => open,
      llc_coherent_dma_snd_data_in => open,
      llc_coherent_dma_snd_full    => '0',
      dma_rcv_rdreq                => dma_rcv_rdreq,
      dma_rcv_data_out             => dma_rcv_data_out,
      dma_rcv_empty                => dma_rcv_empty,
      dma_snd_wrreq                => dma_snd_wrreq,
      dma_snd_data_in              => dma_snd_data_in,
      dma_snd_full                 => dma_snd_full,
      interrupt_wrreq              => open,
      interrupt_data_in            => open,
      interrupt_full               => '0');

  -----------------------------------------------------------------------------
  -- Memory-side model: collects the requests the socket sends on the DMA
  -- plane and answers reads (page table, memory, P2P source) on the receive
  -- queue. Write bursts are checked against the address-derived pattern.
  -----------------------------------------------------------------------------
  mem_model : process (clk)
    constant PMAX : integer := 256;
    type pk_t is (k_read, k_pt, k_p2p);
    type pend_t is record
      kind   : pk_t;
      id     : dma_tran_id_type;
      addr   : unsigned(31 downto 0);
      len    : integer;
      t      : integer;
      rel    : boolean;
      served : boolean;
    end record;
    type pend_arr is array (0 to PMAX - 1) of pend_t;
    variable pq     : pend_arr;
    variable p_tail : integer := 0;
    variable tmp    : pend_t;
    type flit_arr is array (0 to QMAX - 1) of dma_noc_flit_type;
    variable ff     : flit_arr;
    variable f_wr   : integer := 0;
    variable f_rd   : integer := 0;
    type rx_t is (rx_hdr, rx_addr, rx_len, rx_wdata);
    variable rx      : rx_t := rx_hdr;
    variable cur_msg : noc_msg_type;
    variable cur_id  : dma_tran_id_type;
    variable cur_addr : unsigned(31 downto 0);
    variable cur_len : integer;
    variable cur_cnt : integer;
    variable cyc     : integer := 0;
    variable fl      : dma_noc_flit_type;
    variable pre     : noc_preamble_type;
    variable n_ot    : integer;
    variable i1, i2  : integer;
  begin
    if rising_edge(clk) then
      if tb_flush = '1' then
        p_tail := 0;
        f_wr := 0;
        f_rd := 0;
        rx := rx_hdr;
        dma_rcv_empty <= '1';
      else
        cyc := cyc + 1;

        -- the socket pops the head of the receive queue
        if dma_rcv_rdreq = '1' and f_rd < f_wr then
          f_rd := f_rd + 1;
        end if;

        -- the socket pushes a request flit
        if dma_snd_wrreq = '1' then
          fl := dma_snd_data_in;
          pre := fl(DMA_NOC_FLIT_SIZE - 1 downto DMA_NOC_FLIT_SIZE - PREAMBLE_WIDTH);
          case rx is
            when rx_hdr =>
              if pre /= PREAMBLE_HEADER then
                err("memory model: expected a header flit");
              end if;
              cur_msg := get_msg_type(DMA_NOC_FLIT_SIZE, dma_noc_flit_pad & fl);
              cur_id := get_dma_tran_id(fl);
              cur_addr := (others => '0');
              if cur_msg = REQ_P2P then
                rx := rx_len;
              else
                rx := rx_addr;
              end if;
            when rx_addr =>
              cur_addr := unsigned(fl(31 downto 0));
              rx := rx_len;
            when rx_len =>
              cur_len := to_integer(unsigned(fl(31 downto 0)));
              if cur_msg = DMA_FROM_DEV then
                cur_cnt := 0;
                rx := rx_wdata;
              else
                if pre /= PREAMBLE_TAIL then
                  err("memory model: read request length flit is not the tail");
                end if;
                pq(p_tail).id := cur_id;
                pq(p_tail).addr := cur_addr;
                pq(p_tail).len := cur_len;
                pq(p_tail).t := cyc;
                pq(p_tail).rel := false;
                pq(p_tail).served := false;
                if cur_msg = REQ_P2P then
                  pq(p_tail).kind := k_p2p;
                elsif cur_msg = DMA_TO_DEV and cur_addr = PT_ADDR then
                  pq(p_tail).kind := k_pt;
                elsif cur_msg = DMA_TO_DEV then
                  pq(p_tail).kind := k_read;
                else
                  pq(p_tail).kind := k_read;
                  err("memory model: unexpected message type on a read-like request");
                end if;
                p_tail := p_tail + 1;
                rx := rx_hdr;
              end if;
            when rx_wdata =>
              if fl(DMA_NOC_WIDTH - 1 downto 0) /= pattern(cur_addr + to_unsigned(FLIT_BYTES * cur_cnt, 32)) then
                err("memory model: write data mismatch at address 0x" &
                    integer'image(to_integer(cur_addr(31 downto 28))) & "... beat " &
                    integer'image(cur_cnt));
              end if;
              cur_cnt := cur_cnt + 1;
              w_flits_rx := w_flits_rx + 1;
              if pre = PREAMBLE_TAIL then
                if cur_cnt /= cur_len then
                  err("memory model: write burst of " & integer'image(cur_cnt) &
                      " beats, header announced " & integer'image(cur_len));
                end if;
                rx := rx_hdr;
              elsif cur_cnt >= cur_len then
                err("memory model: write burst longer than announced");
                rx := rx_hdr;
              end if;
          end case;
        end if;

        -- outstanding counted reads as seen from memory
        n_ot := 0;
        for i in 0 to p_tail - 1 loop
          if pq(i).kind = k_read and not pq(i).served then
            n_ot := n_ot + 1;
          end if;
        end loop;
        if n_ot > stat_max_ot then
          stat_max_ot := n_ot;
        end if;

        -- release policy
        i1 := -1;
        i2 := -1;
        for i in 0 to p_tail - 1 loop
          if not pq(i).rel then
            if pq(i).kind /= k_read then
              pq(i).rel := true;
            elsif not m_swap then
              if cyc - pq(i).t >= m_latency then
                pq(i).rel := true;
              end if;
            elsif i1 < 0 then
              i1 := i;
            elsif i2 < 0 then
              i2 := i;
            end if;
          end if;
        end loop;
        if m_swap and i1 >= 0 then
          if i2 >= 0 then
            -- two counted reads pending: answer the younger one first
            tmp := pq(i1);
            pq(i1) := pq(i2);
            pq(i2) := tmp;
            pq(i1).rel := true;
            pq(i2).rel := true;
          elsif cyc - pq(i1).t >= m_latency then
            pq(i1).rel := true;
          end if;
        end if;

        -- serve released requests, in queue order
        for i in 0 to p_tail - 1 loop
          if pq(i).rel and not pq(i).served then
            pq(i).served := true;
            fl := (others => '0');
            fl(DMA_NOC_FLIT_SIZE - 1 downto DMA_NOC_FLIT_SIZE - PREAMBLE_WIDTH) := PREAMBLE_HEADER;
            fl := set_dma_tran_id(fl, pq(i).id);
            ff(f_wr) := fl;
            f_wr := f_wr + 1;
            for k in 0 to pq(i).len - 1 loop
              fl := (others => '0');
              if k = pq(i).len - 1 then
                fl(DMA_NOC_FLIT_SIZE - 1 downto DMA_NOC_FLIT_SIZE - PREAMBLE_WIDTH) := PREAMBLE_TAIL;
              else
                fl(DMA_NOC_FLIT_SIZE - 1 downto DMA_NOC_FLIT_SIZE - PREAMBLE_WIDTH) := PREAMBLE_BODY;
              end if;
              case pq(i).kind is
                when k_read =>
                  fl(DMA_NOC_WIDTH - 1 downto 0) := pattern(pq(i).addr + to_unsigned(FLIT_BYTES * k, 32));
                when k_pt =>
                  fl(31 downto 0) := std_logic_vector(chunk_base(k));
                when k_p2p =>
                  fl(DMA_NOC_WIDTH - 1 downto 0) := p2p_pattern(k);
              end case;
              ff(f_wr) := fl;
              f_wr := f_wr + 1;
            end loop;
          end if;
        end loop;

        if f_rd < f_wr then
          dma_rcv_empty <= '0';
          dma_rcv_data_out <= ff(f_rd);
        else
          dma_rcv_empty <= '1';
        end if;
      end if;
    end if;
  end process mem_model;

  -- Back-pressure generators and accelerator-side channels
  channels : process (clk)
    variable lfsr : unsigned(15 downto 0) := x"ACE1";
    variable fb   : std_ulogic;
  begin
    if rising_edge(clk) then
      fb := lfsr(0) xor lfsr(2) xor lfsr(3) xor lfsr(5);
      lfsr := fb & lfsr(15 downto 1);

      if m_bp then
        dma_snd_full <= lfsr(4);
      else
        dma_snd_full <= '0';
      end if;

      -- accelerator model state
      if rst = '0' or tb_flush = '1' or conf_done = '1' then
        acc_soft_reset_seen <= '0';
      elsif acc_rst = '0' then
        acc_soft_reset_seen <= '1';
      end if;

      if acc_soft_reset_seen = '1' or (rst = '1' and acc_rst = '0') then
        bufdin_ready <= '0';
      elsif a_bp then
        bufdin_ready <= lfsr(7);
      else
        bufdin_ready <= '1';
      end if;

      -- write data source
      if bufdout_valid = '1' and bufdout_ready = '1' then
        wq_rd := wq_rd + 1;
      end if;
      if wq_rd < wq_wr and not (w_bp and lfsr(9) = '1') then
        bufdout_valid <= '1';
        bufdout_data <= wq_data(wq_rd);
      else
        bufdout_valid <= '0';
      end if;
    end if;
  end process channels;

  -- Scoreboard on the accelerator read channel
  checker : process (clk)
    variable flagged : boolean := false;
  begin
    if rising_edge(clk) then
      if tb_flush = '1' then
        flagged := false;
      end if;
      if bufdin_valid = '1' and acc_soft_reset_seen = '1' and not flagged then
        flagged := true;
        err("read data offered to the accelerator after it was reset");
      end if;
      if bufdin_valid = '1' and bufdin_ready = '1' then
        if exp_rd >= exp_wr then
          err("unexpected read data beat");
        else
          if bufdin_data /= exp_data(exp_rd) then
            err("read data mismatch at beat " & integer'image(exp_rd) &
                ": got address field 0x" & integer'image(to_integer(unsigned(bufdin_data(63 downto 60)))) &
                "..., low " & integer'image(to_integer(unsigned(bufdin_data(42 downto 32)))));
          end if;
          if bufdin_tag /= exp_tag(exp_rd) then
            err("read tag mismatch at beat " & integer'image(exp_rd));
          end if;
          if bufdin_last /= exp_last(exp_rd) then
            err("read last-marker mismatch at beat " & integer'image(exp_rd));
          end if;
          exp_rd := exp_rd + 1;
        end if;
      end if;
    end if;
  end process checker;

  -----------------------------------------------------------------------------
  -- Stimulus
  -----------------------------------------------------------------------------
  stim : process
    variable e0 : integer;
    variable n  : integer;

    procedure tick (cycles : natural) is
    begin
      for i in 1 to cycles loop
        wait until rising_edge(clk);
      end loop;
    end tick;

    procedure apb_write (reg : natural; data : std_logic_vector(31 downto 0)) is
    begin
      wait until falling_edge(clk);
      apbi.paddr <= std_logic_vector(to_unsigned(reg * 4, 32));
      apbi.pwdata <= data;
      apbi.psel(0) <= '1';
      apbi.penable <= '1';
      apbi.pwrite <= '1';
      wait until falling_edge(clk);
      apbi.psel(0) <= '0';
      apbi.penable <= '0';
      apbi.pwrite <= '0';
      -- park the address bus away from PT_ADDRESS (its decode clears the TLB)
      apbi.paddr <= std_logic_vector(to_unsigned(STATUS_REG * 4, 32));
      wait until rising_edge(clk);
    end apb_write;

    procedure start_run (name : string) is
      variable k : integer := 0;
    begin
      apb_write(CMD_REG, x"00000001");
      loop
        exit when conf_done = '1';
        wait until rising_edge(clk);
        k := k + 1;
        if k > 2000 then
          err(name & ": the accelerator was never started (no conf_done)");
          exit;
        end if;
      end loop;
      tick(2);
    end start_run;

    -- Full reset, register setup and start
    procedure boot (name : string) is
    begin
      report "---- " & name severity note;
      rd_request <= '0';
      wr_request <= '0';
      tb_flush <= '1';
      rst <= '0';
      tick(5);
      exp_wr := 0;
      exp_rd := 0;
      wq_wr := 0;
      wq_rd := 0;
      w_flits_exp := 0;
      w_flits_rx := 0;
      stat_max_ot := 0;
      tb_flush <= '0';
      rst <= '1';
      tick(3);
      apb_write(COHERENCE_REG, x"00000000");
      apb_write(P2P_REG, x"00000000");
      if SG = 1 then
        apb_write(PT_NCHUNK_REG, std_logic_vector(to_unsigned(NCHUNK, 32)));
        apb_write(PT_SHIFT_REG, std_logic_vector(to_unsigned(CHUNK_SHIFT, 32)));
        apb_write(SRC_OFFSET_REG, x"00000000");
        apb_write(DST_OFFSET_REG, x"00000000");
        apb_write(PT_ADDRESS_REG, std_logic_vector(PT_ADDR));
      else
        apb_write(SRC_OFFSET_REG, std_logic_vector(NOSG_SRC_OFFSET));
        apb_write(DST_OFFSET_REG, std_logic_vector(NOSG_DST_OFFSET));
      end if;
      start_run(name);
    end boot;

    -- Physical address of beat k of a transfer starting at flit index idx
    impure function beat_addr (idx, k : natural; is_write : boolean) return unsigned is
    begin
      if SG = 1 then
        return v2p((idx + k) * FLIT_BYTES);
      elsif is_write then
        return NOSG_DST_OFFSET + to_unsigned((idx + k) * FLIT_BYTES, 32);
      else
        return NOSG_SRC_OFFSET + to_unsigned((idx + k) * FLIT_BYTES, 32);
      end if;
    end beat_addr;

    -- Read request: index and length in DMA flits
    procedure rd_req (name : string; idx, len : natural; tag : natural; src : natural := 0) is
      variable k : integer := 0;
      variable t : tag_t;
    begin
      if SG = 1 then
        t := std_logic_vector(to_unsigned(tag mod 2**DMA_ACC_TAG_WIDTH, DMA_ACC_TAG_WIDTH));
      else
        t := (others => '0');
      end if;
      for i in 0 to len - 1 loop
        if src /= 0 then
          exp_data(exp_wr) := p2p_pattern(i);
        else
          exp_data(exp_wr) := pattern(beat_addr(idx, i, false));
        end if;
        exp_tag(exp_wr) := t;
        if i = len - 1 then
          exp_last(exp_wr) := '1';
        else
          exp_last(exp_wr) := '0';
        end if;
        exp_wr := exp_wr + 1;
      end loop;
      if SG = 1 then
        rd_index <= std_logic_vector(to_unsigned(idx, 32));
        rd_length <= std_logic_vector(to_unsigned(len, 32));
      else
        -- without scatter-gather the socket counts 32-bit words
        rd_index <= std_logic_vector(to_unsigned(idx * 2, 32));
        rd_length <= std_logic_vector(to_unsigned(len * 2, 32));
      end if;
      rd_tag_in <= t;
      rd_source <= std_logic_vector(to_unsigned(src, 6));
      rd_request <= '1';
      loop
        wait until rising_edge(clk);
        exit when rd_grant = '1';
        k := k + 1;
        if k > 20000 then
          err(name & ": read request never granted");
          exit;
        end if;
      end loop;
      rd_request <= '0';
    end rd_req;

    -- Write request: index and length in DMA flits; data follows on bufdout
    procedure wr_req (name : string; idx, len : natural) is
      variable k : integer := 0;
    begin
      for i in 0 to len - 1 loop
        wq_data(wq_wr) := pattern(beat_addr(idx, i, true));
        wq_wr := wq_wr + 1;
      end loop;
      w_flits_exp := w_flits_exp + len;
      if SG = 1 then
        wr_index <= std_logic_vector(to_unsigned(idx, 32));
        wr_length <= std_logic_vector(to_unsigned(len, 32));
      else
        wr_index <= std_logic_vector(to_unsigned(idx * 2, 32));
        wr_length <= std_logic_vector(to_unsigned(len * 2, 32));
      end if;
      wr_request <= '1';
      loop
        wait until rising_edge(clk);
        exit when wr_grant = '1';
        k := k + 1;
        if k > 20000 then
          err(name & ": write request never granted");
          exit;
        end if;
      end loop;
      wr_request <= '0';
    end wr_req;

    -- Wait until every expected beat has moved
    procedure wait_all (name : string; timeout : natural) is
      variable k : integer := 0;
    begin
      loop
        wait until rising_edge(clk);
        exit when exp_rd = exp_wr and w_flits_rx = w_flits_exp;
        k := k + 1;
        if k > timeout then
          err(name & ": timeout, " & integer'image(exp_wr - exp_rd) & " read beats and " &
              integer'image(w_flits_exp - w_flits_rx) & " write beats missing");
          exit;
        end if;
      end loop;
      tick(20);
    end wait_all;

    procedure verdict (name : string; e_before : integer) is
    begin
      if errors = e_before then
        report name & " PASS" severity note;
      else
        report name & " FAIL (" & integer'image(errors - e_before) & " errors)" severity note;
      end if;
    end verdict;

    -- Software reset: must be taken only once nothing is in flight
    procedure soft_reset (name : string) is
      variable k : integer := 0;
    begin
      apb_write(CMD_REG, x"00000000");
      loop
        exit when acc_soft_reset_seen = '1';
        wait until rising_edge(clk);
        k := k + 1;
        if k > 20000 then
          err(name & ": software reset never taken");
          exit;
        end if;
      end loop;
      if exp_rd /= exp_wr then
        err(name & ": software reset taken with " & integer'image(exp_wr - exp_rd) &
            " read beats still in flight");
      end if;
      tick(10);
    end soft_reset;

  begin
    apbi.psel <= (others => '0');
    apbi.penable <= '0';
    apbi.paddr <= std_logic_vector(to_unsigned(STATUS_REG * 4, 32));
    apbi.pwrite <= '0';
    apbi.pwdata <= (others => '0');
    apbi.pirq <= (others => '0');
    apbi.testen <= '0';
    apbi.testrst <= '0';
    apbi.scanen <= '0';
    apbi.testoen <= '0';
    apbi.testin <= (others => '0');
    tick(2);

    report "esp_acc_dma_tb: scatter_gather = " & integer'image(SG) &
      ", CFG_DMA_MAX_READS = " & integer'image(MAX_OT) severity note;

    if SG = 1 then
      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 20; m_swap <= false; m_bp <= false; a_bp <= false; w_bp <= false;
      boot("T1 single read");
      rd_req("T1", 3, 16, 5);
      wait_all("T1", 5000);
      verdict("T1", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 100;
      boot("T2 two back-to-back reads");
      rd_req("T2", 0, 16, 1);
      rd_req("T2", 100, 16, 2);
      wait_all("T2", 5000);
      if MAX_OT > 1 then
        n := 2;
      else
        n := 1;
      end if;
      if stat_max_ot /= n then
        err("T2: memory saw at most " & integer'image(stat_max_ot) &
            " reads outstanding, expected " & integer'image(n));
      end if;
      verdict("T2", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 80; m_swap <= true;
      boot("T3 swapped responses");
      rd_req("T3", 10, 16, 3);
      rd_req("T3", 200, 24, 4);
      wait_all("T3", 5000);
      verdict("T3", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      boot("T3b swapped responses, multi-fragment");
      rd_req("T3b", 0, 600, 6);
      rd_req("T3b", 700, 200, 7);
      wait_all("T3b", 20000);
      verdict("T3b", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 20; m_swap <= false;
      boot("T4 request right after a multi-fragment grant (read)");
      rd_req("T4", 0, 600, 8);
      rd_req("T4", 700, 16, 9);
      rd_req("T4", 1000, 16, 10);
      wait_all("T4", 20000);
      verdict("T4", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      boot("T4w request right after a multi-fragment grant (write)");
      wr_req("T4w", 0, 600);
      wr_req("T4w", 700, 16);
      wr_req("T4w", 1000, 16);
      wait_all("T4w", 20000);
      verdict("T4w", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 200;
      boot("T5a software reset with reads in flight");
      rd_req("T5a", 0, 16, 1);
      rd_req("T5a", 100, 16, 2);
      tick(10);
      soft_reset("T5a");
      m_latency <= 20;
      start_run("T5a second run");
      rd_req("T5a second run", 300, 16, 3);
      wait_all("T5a", 5000);
      verdict("T5a", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 30;
      boot("T5b software reset in the middle of a multi-fragment read");
      rd_req("T5b", 0, 600, 4);
      tick(6);
      soft_reset("T5b");
      m_latency <= 20;
      start_run("T5b second run");
      rd_req("T5b second run", 800, 16, 5);
      wait_all("T5b", 20000);
      verdict("T5b", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 20;
      boot("T6 write then read");
      wr_req("T6", 50, 32);
      wr_req("T6", 90, 1);
      wait_all("T6", 5000);
      rd_req("T6", 50, 32, 11);
      rd_req("T6", 90, 1, 12);
      wait_all("T6", 5000);
      verdict("T6", e0);

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 15; m_bp <= true; a_bp <= true; w_bp <= true;
      boot("T7 random back-pressure");
      rd_req("T7", 0, 300, 1);
      rd_req("T7", 400, 40, 2);
      wr_req("T7", 1000, 300);
      rd_req("T7", 2000, 17, 3);
      wr_req("T7", 1500, 20);
      rd_req("T7", 5, 1, 4);
      rd_req("T7", 3000, 520, 5);
      wait_all("T7", 60000);
      verdict("T7", e0);
      m_bp <= false; a_bp <= false; w_bp <= false;

      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 400;
      boot("T8 P2P read while a counted read is in flight");
      rd_req("T8", 0, 16, 1);
      rd_req("T8", 0, 8, 2, 1);
      wait_all("T8", 20000);
      m_latency <= 20;
      rd_req("T8", 64, 16, 3);
      wait_all("T8", 5000);
      verdict("T8", e0);

    else
      -------------------------------------------------------------------------
      e0 := errors;
      m_latency <= 20;
      boot("N1 write then read (no scatter-gather)");
      wr_req("N1", 128, 8);
      wait_all("N1", 5000);
      rd_req("N1", 16, 4, 0);
      wait_all("N1", 5000);
      verdict("N1", e0);

      e0 := errors;
      boot("N2 two back-to-back reads (no scatter-gather)");
      rd_req("N2", 32, 4, 0);
      rd_req("N2", 48, 6, 0);
      wait_all("N2", 5000);
      verdict("N2", e0);

      e0 := errors;
      boot("N3 two back-to-back writes (no scatter-gather)");
      wr_req("N3", 512, 4);
      wr_req("N3", 768, 6);
      wait_all("N3", 5000);
      verdict("N3", e0);
    end if;

    if errors = 0 then
      report "TB PASSED: esp_acc_dma (scatter_gather = " & integer'image(SG) &
        ", CFG_DMA_MAX_READS = " & integer'image(MAX_OT) & ")" severity note;
    else
      report "TB FAILED: esp_acc_dma, " & integer'image(errors) & " errors (scatter_gather = " &
        integer'image(SG) & ", CFG_DMA_MAX_READS = " & integer'image(MAX_OT) & ")" severity note;
    end if;
    done <= true;
    wait;
  end process stim;

end tb;
