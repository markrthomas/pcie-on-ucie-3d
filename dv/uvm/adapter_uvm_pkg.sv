// ============================================================================
// dv/uvm/adapter_uvm_pkg.sv — UVM environment for pcie_ucie3d_adapter (DV env 3).
//
//   smoke_test      : reset/defaults + link-up contract (tie-off, no env)
//   frame_seq -> pcie_sequencer -> pcie_tx_driver  (PCIe AXI4-S source)
//   pcie_rx_monitor : tready responder + frame reassembly -> analysis port
//   ucie_phy_driver : remote die — bring-up (link_status/rx_active/rx_elec_idle),
//                     UCIe-3D Tx->Rx loopback, Tx flit monitor, 8-bit sideband
//                     target + ack, Tx-legality checker (mirror ucie_sb_model.sv)
//   csr_agent       : CSR read/write/poll tasks (ucie_clk)
//   adapter_sb      : in-order byte check + CRC-32 per scenario
//   scen_test       : runs the shared five-scenario set, writes results.json
// Drive with NBAs after @(posedge clk); sample right after @(posedge clk).
// ============================================================================
`include "uvm_macros.svh"

package adapter_uvm_pkg;
  import uvm_pkg::*;
  import pcie_ucie3d_pkg::*;

  `include "pcie_pat.svh"
  `include "scenarios.svh"

  // ------------------------------------------------------------------ items
  class pcie_frame_item extends uvm_sequence_item;
    int fid;
    int len;
    `uvm_object_utils(pcie_frame_item)
    function new(string name = "pcie_frame_item"); super.new(name); endfunction
  endclass

  class rx_frame extends uvm_object;
    byte unsigned data[$];
    bit err;
    `uvm_object_utils(rx_frame)
    function new(string name = "rx_frame"); super.new(name); endfunction
  endclass

  typedef uvm_sequencer #(pcie_frame_item) pcie_sequencer;

  class frame_seq extends uvm_sequence #(pcie_frame_item);
    int scen, lo, hi;
    `uvm_object_utils(frame_seq)
    function new(string name = "frame_seq"); super.new(name); endfunction
    task body();
      for (int i = lo; i < hi; i++) begin
        pcie_frame_item it = pcie_frame_item::type_id::create($sformatf("f%0d", i));
        start_item(it);
        it.fid = i;
        it.len = scen_len(scen, i);
        finish_item(it);
      end
    endtask
  endclass

  // ------------------------------------------------------------ PCIe tx driver
  class pcie_tx_driver extends uvm_driver #(pcie_frame_item);
    virtual adapter_if vif;
    int gap_pct = 10;
    `uvm_component_utils(pcie_tx_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      pcie_frame_item it;
      logic [PCIE_DATA_W-1:0] d;
      logic [PCIE_KEEP_W-1:0] k;
      int off, n;
      vif.pcie_tvalid <= 1'b0;
      vif.pcie_tlast  <= 1'b0;
      @(posedge vif.pcie_clk);
      forever begin
        seq_item_port.get_next_item(it);
        off = 0;
        while (off < it.len) begin
          if (gap_pct > 0 && $urandom_range(99, 0) < gap_pct) begin
            vif.pcie_tvalid <= 1'b0;
            @(posedge vif.pcie_clk);
            continue;
          end
          n = it.len - off;
          if (n > PCIE_KEEP_W) n = PCIE_KEEP_W;
          d = '0; k = '0;
          for (int i = 0; i < n; i++) begin
            d[8*i +: 8] = pat(it.fid, off + i);
            k[i] = 1'b1;
          end
          vif.pcie_tvalid <= 1'b1;
          vif.pcie_tdata  <= d;
          vif.pcie_tkeep  <= k;
          vif.pcie_tuser  <= '0;
          vif.pcie_tlast  <= (off + n == it.len);
          do @(posedge vif.pcie_clk); while (!(vif.pcie_tvalid && vif.pcie_tready));
          off += n;
        end
        vif.pcie_tvalid <= 1'b0;
        vif.pcie_tlast  <= 1'b0;
        seq_item_port.item_done();
        @(posedge vif.pcie_clk);
      end
    endtask
  endclass

  // ------------------------------------------------------------ PCIe rx monitor
  class pcie_rx_monitor extends uvm_component;
    virtual adapter_if vif;
    uvm_analysis_port #(rx_frame) ap;
    int ready_pct = 90;
    int errors = 0;
    `uvm_component_utils(pcie_rx_monitor)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      rx_frame fr = rx_frame::type_id::create("fr");
      int nb;
      vif.pcie_rx_tready <= 1'b0;
      forever begin
        @(posedge vif.pcie_clk);
        if (vif.pcie_rst_n && vif.pcie_rx_tvalid && vif.pcie_rx_tready) begin
          nb = 0;
          for (int i = 0; i < PCIE_KEEP_W; i++) nb += int'(vif.pcie_rx_tkeep[i]);
          if (nb == 0 || vif.pcie_rx_tkeep != PCIE_KEEP_W'((64'd1 << nb) - 1) ||
              (!vif.pcie_rx_tlast && nb != PCIE_KEEP_W) || (vif.pcie_rx_tuser[0] && !vif.pcie_rx_tlast)) begin
            errors++;
            `uvm_error("RXMON", $sformatf("illegal tkeep %h last %b", vif.pcie_rx_tkeep, vif.pcie_rx_tlast))
          end
          for (int i = 0; i < nb; i++) fr.data.push_back(vif.pcie_rx_tdata[8*i +: 8]);
          if (vif.pcie_rx_tlast) begin
            fr.err = vif.pcie_rx_tuser[0];
            ap.write(fr);
            fr = rx_frame::type_id::create("fr");
          end
        end
        vif.pcie_rx_tready <= vif.pcie_rst_n && ($urandom_range(99, 0) < ready_pct);
      end
    endtask
  endclass

  // ------------------------------------------------------------ UCIe remote die
  class ucie_phy_driver extends uvm_component;
    virtual adapter_if vif;
    int unsigned flits = 0;
    int unsigned cr_flits = 0;   // credit-only flits (FLOW_CTRL, D16)
    int unsigned fc_sent = 0;    // data flits since the last DUT reset (expected seq field)
    int unsigned sb_writes = 0;
    logic        in_frame = 1'b0;
    logic [FLIT_BYTES*8-1:0] fl;
    int errors = 0;
    `uvm_component_utils(ucie_phy_driver)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction

    // Flit legality + classification (mirror of ucie_phy_model.sv).
    function void check_flit();
      int plen;
      bit hv, hsof, heof, crflit, padbad;
      hv = fl[0]; hsof = fl[1]; heof = fl[2]; plen = int'(fl[15:8]);
      if (!hv) begin errors++; `uvm_error("PHY", "header valid bit clear") end
      if (fl[7:3] != 5'b0) begin errors++; `uvm_error("PHY", "header reserved bits nonzero") end
      if (plen > FLIT_PAYLOAD_B) begin errors++; `uvm_error("PHY", "payload length > 240") end
      crflit = FLOW_CTRL && plen == 0 && !hsof && !heof;
      if (plen == 0 && !crflit) begin errors++; `uvm_error("PHY", "empty flit emitted") end
      if (!crflit && hsof !== !in_frame) begin errors++; `uvm_error("PHY", "sof/frame state mismatch") end
      padbad = 1'b0;
      for (int b = FLIT_HDR_B + plen; b < FLIT_BYTES; b++)
        if (!(FLOW_CTRL && b >= FLIT_FC_OFF && b < FLIT_FC_OFF + 4) && fl[8*b +: 8] !== 8'h00) padbad = 1'b1;
      if (padbad) begin errors++; `uvm_error("PHY", "nonzero padding/DLP/FEC byte") end
      if (FLOW_CTRL && fl[8*FLIT_FC_OFF +: 16] !== 16'(fc_sent)) begin
        errors++; `uvm_error("PHY", "flow-control seq field != data flits sent before")
      end
      if (crflit) cr_flits++;
      else begin flits++; fc_sent++; in_frame = !heof; end
    endfunction

    task run_phase(uvm_phase phase);
      logic [1:0] pd, pd_q, wd, wd_q;
      logic [2:0] sp, sp_q;
      int rd_phase, rst_cnt, sb_cnt, mb_cnt, st_cnt, ack_cnt, beat, sb_ph;
      logic [SB_ADDR_W-1:0] sb_addr;
      logic [SB_W-1:0] m2s;
      bit change;
      localparam int LAT = 8, RST_CYCLES = 16, SB_LAT = 8, MB_LAT = 8;
      vif.ucie_link_status  <= 1'b1;
      vif.ucie_rx_active    <= 1'b0;
      vif.ucie_rx_elec_idle <= 1'b1;
      vif.ucie_sb_s2m       <= '0;
      vif.ucie_rx_data <= '0; vif.ucie_rx_valid <= 1'b0; vif.ucie_rx_start_flit <= 1'b0;
      rd_phase = 0; rst_cnt = 0; sb_cnt = 0; mb_cnt = 0; st_cnt = 0; ack_cnt = 0; beat = 0; sb_ph = 0;
      sb_addr = '0; pd_q = '0; sp_q = '0; wd_q = '0;
      forever begin
        @(posedge vif.ucie_clk);
        // registered UCIe-3D Tx -> Rx loopback
        vif.ucie_rx_data       <= vif.ucie_tx_data;
        vif.ucie_rx_valid      <= vif.ucie_tx_valid;
        vif.ucie_rx_start_flit <= vif.ucie_tx_start_flit;
        if (!vif.ucie_rst_n) begin
          vif.ucie_link_status  <= 1'b1;
          vif.ucie_rx_active    <= 1'b0;
          vif.ucie_rx_elec_idle <= 1'b1;
          vif.ucie_sb_s2m       <= '0;
          rd_phase = 0; rst_cnt = 0; sb_cnt = 0; mb_cnt = 0; st_cnt = 0; ack_cnt = 0;
          beat = 0; sb_ph = 0; fc_sent = 0; in_frame = 1'b0;
          pd_q = logic'(vif.ucie_powerdown); sp_q = logic'(vif.ucie_speed); wd_q = vif.ucie_width;
          continue;
        end
        // flit monitor (Tx side)
        if (vif.ucie_tx_valid) begin
          if (vif.ucie_tx_start_flit != (beat == 0)) begin errors++; `uvm_error("PHY", "start_flit misplaced") end
          fl[beat*UCIE_BUS_W +: UCIE_BUS_W] = vif.ucie_tx_data;
          if (beat == FLIT_BEATS - 1) check_flit();
          beat = (beat + 1) % FLIT_BEATS;
        end else if (beat != 0) begin
          errors++; `uvm_error("PHY", "tx_valid dropped mid-flit") beat = 0;
        end
        // bring-up sequencer + op-complete link_status pulse
        pd = logic'(vif.ucie_powerdown); sp = logic'(vif.ucie_speed); wd = vif.ucie_width;
        change = (pd != pd_q) || (sp != sp_q) || (wd != wd_q);
        vif.ucie_link_status <= 1'b0;
        if (rd_phase == 0) begin
          vif.ucie_link_status <= 1'b1;
          if (rst_cnt < RST_CYCLES) rst_cnt++;
          else begin vif.ucie_link_status <= 1'b0; rd_phase = 1; sb_cnt = 0; end
        end else if (rd_phase == 1) begin
          if (sb_cnt < SB_LAT) sb_cnt++;
          else begin vif.ucie_rx_elec_idle <= 1'b0; rd_phase = 2; mb_cnt = 0; end
        end else if (rd_phase == 2) begin
          if (mb_cnt < MB_LAT) mb_cnt++;
          else begin vif.ucie_rx_active <= 1'b1; rd_phase = 3; end
        end else begin
          if (change) st_cnt = LAT;
          else if (st_cnt == 1) begin st_cnt = 0; vif.ucie_link_status <= 1'b1; end
          else if (st_cnt > 1) st_cnt--;
        end
        // Tx legality
        if (vif.ucie_tx_valid && pd != PWR_L0) begin errors++; `uvm_error("PHY", "Tx valid while powerdown != L0") end
        if (vif.ucie_tx_valid && (st_cnt != 0 || change)) begin errors++; `uvm_error("PHY", "Tx valid during a change") end
        pd_q = pd; sp_q = sp; wd_q = wd;
        // sideband target (byte-serial write + ack)
        m2s = vif.ucie_sb_m2s;
        vif.ucie_sb_s2m <= '0;
        if (sb_ph == 1) begin sb_addr[SB_ADDR_W-1:8] = m2s; sb_ph = 2; end
        else if (sb_ph == 2) begin sb_addr[7:0] = m2s; sb_ph = 3; end
        else if (sb_ph == 3) begin sb_writes++; sb_ph = 0; ack_cnt = LAT; end
        else if (m2s != 8'h00) begin
          if (m2s[7:4] == SB_WR) sb_ph = 1;
          else begin errors++; `uvm_error("PHY", "unsupported M2S sideband command") end
        end
        if (ack_cnt == 1) begin ack_cnt = 0; vif.ucie_sb_s2m <= {SB_WR_ACK, 4'h0}; end
        else if (ack_cnt > 1) ack_cnt--;
      end
    endtask
  endclass

  // ------------------------------------------------------------ CSR agent
  class csr_agent extends uvm_component;
    virtual adapter_if vif;
    `uvm_component_utils(csr_agent)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      vif.csr_valid <= 1'b0; vif.csr_write <= 1'b0; vif.csr_addr <= '0; vif.csr_wdata <= '0;
    endtask
    task write(logic [7:0] a, logic [31:0] d);
      @(posedge vif.ucie_clk);
      vif.csr_valid <= 1'b1; vif.csr_write <= 1'b1; vif.csr_addr <= a; vif.csr_wdata <= d;
      @(posedge vif.ucie_clk);
      vif.csr_valid <= 1'b0; vif.csr_write <= 1'b0;
    endtask
    task read(logic [7:0] a, output logic [31:0] d);
      @(posedge vif.ucie_clk);
      vif.csr_addr <= a;
      @(posedge vif.ucie_clk);
      d = vif.csr_rdata;
    endtask
    task set_state(logic [1:0] pd, logic [2:0] sp, output bit ok);
      logic [31:0] s;
      write(CSR_CTRL, {25'b0, 2'b00, sp, pd});
      ok = 0;
      for (int t = 0; t < 40000 && !ok; t++) begin
        read(CSR_STATUS, s);
        ok = (s[1:0] == pd) && (s[4:2] == sp) && !s[11];
      end
    endtask
  endclass

  // ------------------------------------------------------------ scoreboard
  class adapter_sb extends uvm_subscriber #(rx_frame);
    int scen;
    int frames, errors;
    longint nbytes;
    logic [31:0] crc;
    `uvm_component_utils(adapter_sb)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void start(int s);
      scen = s; frames = 0; errors = 0; nbytes = 0; crc = 32'hFFFF_FFFF;
    endfunction
    function void write(rx_frame t);
      if (t.err || frames >= scen_nframes(scen) || t.data.size() != scen_len(scen, frames)) begin
        errors++;
        `uvm_error("SB", $sformatf("%s frame %0d len %0d err %b", scen_name(scen), frames, t.data.size(), t.err))
      end else begin
        foreach (t.data[i])
          if (t.data[i] != pat(frames, i)) begin
            errors++;
            `uvm_error("SB", $sformatf("%s frame %0d byte %0d", scen_name(scen), frames, i))
            break;
          end
      end
      foreach (t.data[i]) crc = crc32_byte(crc, t.data[i]);
      nbytes += t.data.size();
      frames++;
    endfunction
  endclass

  // ------------------------------------------------------------ env
  class adapter_env extends uvm_env;
    pcie_sequencer  seqr;
    pcie_tx_driver  drv;
    pcie_rx_monitor rxm;
    ucie_phy_driver phy;
    csr_agent       csr;
    adapter_sb      sb;
    `uvm_component_utils(adapter_env)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      seqr = pcie_sequencer::type_id::create("seqr", this);
      drv  = pcie_tx_driver::type_id::create("drv", this);
      rxm  = pcie_rx_monitor::type_id::create("rxm", this);
      phy  = ucie_phy_driver::type_id::create("phy", this);
      csr  = csr_agent::type_id::create("csr", this);
      sb   = adapter_sb::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(seqr.seq_item_export);
      rxm.ap.connect(sb.analysis_export);
    endfunction
  endclass

  // ------------------------------------------------------------ smoke test
  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    virtual adapter_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "adapter_if not set in config db")
    endfunction
    task run_phase(uvm_phase phase);
      int errors = 0;
      phase.raise_objection(this);
      vif.pcie_tvalid = 1'b0; vif.pcie_tlast = 1'b0; vif.pcie_tdata = '0;
      vif.pcie_tkeep = '0; vif.pcie_tuser = '0; vif.pcie_rx_tready = 1'b1;
      vif.ucie_rx_data = '0; vif.ucie_rx_valid = 1'b0; vif.ucie_rx_start_flit = 1'b0;
      vif.ucie_link_status = 1'b0; vif.ucie_rx_active = 1'b0; vif.ucie_rx_elec_idle = 1'b1;
      vif.ucie_sb_s2m = '0;
      vif.csr_valid = 1'b0; vif.csr_write = 1'b0; vif.csr_addr = '0; vif.csr_wdata = '0;
      vif.pcie_rst_n = 1'b0; vif.ucie_rst_n = 1'b0;
      repeat (10) @(posedge vif.ucie_clk);
      vif.pcie_rst_n = 1'b1; vif.ucie_rst_n = 1'b1;
      repeat (5) @(posedge vif.ucie_clk);
      if (vif.ucie_powerdown !== PWR_L1) begin errors++; `uvm_error("SMOKE", "powerdown != L1") end
      if (vif.ucie_speed !== SPEED_64)   begin errors++; `uvm_error("SMOKE", "speed != SPEED_64") end
      if (vif.ucie_tx_valid !== 1'b0)    begin errors++; `uvm_error("SMOKE", "Tx active out of reset") end
      if (vif.pcie_tready !== 1'b0)      begin errors++; `uvm_error("SMOKE", "ingress not closed before link-up (M3)") end
      if (errors == 0) `uvm_info("SMOKE", "UVM SMOKE PASS: reset defaults OK", UVM_NONE)
      else             `uvm_error("SMOKE", "UVM SMOKE FAIL")
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------ scenario test
  class scen_test extends uvm_test;
    adapter_env env;
    virtual adapter_if vif;
    int total_errors = 0;
    `uvm_component_utils(scen_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = adapter_env::type_id::create("env", this);
      void'(uvm_config_db#(virtual adapter_if)::get(this, "", "vif", vif));
    endfunction

    task do_reset(output bit ok);
      logic [31:0] s;
      vif.pcie_rst_n <= 1'b0;
      vif.ucie_rst_n <= 1'b0;
      repeat (10) @(posedge vif.ucie_clk);
      vif.pcie_rst_n <= 1'b1;
      vif.ucie_rst_n <= 1'b1;
      ok = 0;
      for (int t = 0; t < 40000 && !ok; t++) begin
        env.csr.read(CSR_STATUS, s);
        ok = s[12];                 // link active
      end
    endtask

    task wait_frames(int n, output bit ok);
      int t = 0;
      while (env.sb.frames < n && t < 400000) begin @(posedge vif.pcie_clk); t++; end
      ok = env.sb.frames >= n;
    endtask

    task run_phase(uvm_phase phase);
      int fd, nfr, f0, e0, errs;
      string rpath;
      bit ok, o;
      logic [31:0] pm;
      frame_seq seq;
      phase.raise_objection(this);
      rpath = "logs/results.json";
      void'($value$plusargs("results=%s", rpath));
      fd = $fopen(rpath, "w");
      $fwrite(fd, "{\"env\": \"uvm\", \"scenarios\": {");
      for (int sc = 0; sc < SCEN_N; sc++) begin
        nfr = scen_nframes(sc);
        env.sb.start(sc);
        do_reset(ok);
        f0 = env.phy.flits;
        e0 = env.phy.errors + env.rxm.errors;
        seq = frame_seq::type_id::create("seq");
        seq.scen = sc;
        if (scen_ctrl(sc) == 0) begin
          seq.lo = 0; seq.hi = nfr; seq.start(env.seqr);
        end else begin
          seq.lo = 0; seq.hi = nfr / 2; seq.start(env.seqr);
          wait_frames(nfr / 2, o); ok &= o;
          if (scen_ctrl(sc) == 1) begin
            env.csr.set_state(PWR_L1, SPEED_64, o); ok &= o;
            repeat (200) @(posedge vif.ucie_clk);
            env.csr.set_state(PWR_L0, SPEED_64, o); ok &= o;
          end else begin
            env.csr.set_state(PWR_L0, SPEED_32, o); ok &= o;
            repeat (200) @(posedge vif.ucie_clk);
            env.csr.set_state(PWR_L0, SPEED_64, o); ok &= o;
          end
          seq = frame_seq::type_id::create("seq_b");
          seq.scen = sc; seq.lo = nfr / 2; seq.hi = nfr; seq.start(env.seqr);
        end
        wait_frames(nfr, o); ok &= o;
        repeat (200) @(posedge vif.pcie_clk);
        env.csr.read(CSR_PMCNT, pm);
        errs = env.sb.errors + (env.phy.errors + env.rxm.errors - e0) + (ok ? 0 : 1);
        total_errors += errs;
        `uvm_info("SCEN", $sformatf("%-12s frames=%0d bytes=%0d flits=%0d crc32=%08x pmcnt=%0d errors=%0d",
                  scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0, ~env.sb.crc, pm[15:0], errs), UVM_LOW)
        $fwrite(fd, "%s\"%s\": {\"frames\": %0d, \"bytes\": %0d, \"flits\": %0d, \"crc32\": \"%08x\", \"pmcnt\": %0d, \"errors\": %0d}",
                (sc == 0) ? "" : ", ", scen_name(sc), env.sb.frames, env.sb.nbytes, env.phy.flits - f0,
                ~env.sb.crc, pm[15:0], errs);
      end
      $fwrite(fd, "}}\n");
      $fclose(fd);
      if (FLOW_CTRL) begin
        `uvm_info("FC", $sformatf("credit-only flits=%0d", env.phy.cr_flits), UVM_LOW)
        if (env.phy.cr_flits == 0) begin
          total_errors++; `uvm_error("FC", "flow control on but no credit-only flit seen (FC not exercised)")
        end
      end
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      if (total_errors == 0) `uvm_info("RESULT", "UVM SCEN PASS: 5 scenarios", UVM_NONE)
      else `uvm_error("RESULT", $sformatf("UVM SCEN FAIL: %0d error(s)", total_errors))
    endfunction
  endclass

endpackage
