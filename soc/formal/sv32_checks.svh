// Port-level AXI monitor. An accepted AR owns one response, which can
// be delayed indefinitely. An error response need not carry useful data.
logic seen_clock = 1'b0;
logic outstanding, sampled;
logic [31:0] response_pte;
always @(posedge clk) begin
  seen_clock <= 1'b1;
  if (!seen_clock) assume (rst);
  assume (priv_fetch == PRIV_U || priv_fetch == PRIV_S || priv_fetch == PRIV_M);
  assume (priv_data == PRIV_U || priv_data == PRIV_S || priv_data == PRIV_M);
  if (rst) begin
    outstanding <= 0;
    sampled <= 0;
  end else begin
    if (ptw_r.valid) assume (outstanding && ptw_r.last && ptw_r.id == 0);
    if (ptw_ar.valid && p_ready) outstanding <= 1;
    if (ptw_r.valid) begin
      outstanding <= 0;
      response_pte <= ptw_r.resp == `AXI4_RESP_OKAY ? ptw_r.data : 0;
    end
    sampled <= ptw_r.valid;
  end
end

function automatic logic table_address(logic [31:0] address);
  table_address = address[31:25] == 7'h08;
endfunction

function automatic logic allow(logic [7:0] flags, logic fetch, logic store, logic [1:0] mode,
                               logic sum, logic mxr);
  logic privilege_ok, access_ok;
  privilege_ok = mode == PRIV_U ? flags[4] : (!flags[4] || (!fetch && sum));
  access_ok = fetch ? flags[3] : store ? (flags[2] && flags[7]) : (flags[1] || (mxr && flags[3]));
  allow = flags[6] && privilege_ok && access_ok;
endfunction

logic root_reply, leaf_reply, accept_leaf, follow_pointer, reject;
logic [31:0] next_address;
logic [19:0] leaf_page;
logic [7:0] leaf_flags;
assign root_reply = sampled && wstate == W_PTE1_WAIT;
assign leaf_reply = sampled && wstate == W_PTE0_WAIT;
assign next_address = {response_pte[29:10], w_vaddr[21:12], 2'b00};
assign leaf_page = root_reply ? {response_pte[29:20], w_vaddr[21:12]} : response_pte[29:10];
assign leaf_flags = response_pte[7:0];
always_comb begin
  accept_leaf = 0;
  follow_pointer = 0;
  if ((root_reply || leaf_reply) && leaf_flags[0] && leaf_flags[2:1] != 2'b10) begin
    if (leaf_flags[1] || leaf_flags[3]) begin
      accept_leaf = (leaf_reply || response_pte[19:10] == 0) &&
          allow(leaf_flags, w_is_if, w_is_store, w_priv, mstatus_sum, mstatus_mxr);
    end else begin
      // U/A/D are reserved in non-leaf PTEs. G and RSW are allowed.
      follow_pointer = root_reply && table_address(next_address) && !leaf_flags[4] &&
          !leaf_flags[6] && !leaf_flags[7];
    end
  end
end
assign reject = (root_reply || leaf_reply) && !accept_leaf && !follow_pointer;

// Retain the reference leaf over the separate TLB installation cycle.
logic [TLB_W-1:0] leaf_entry;
always @(posedge clk) begin
  if (accept_leaf) begin
    leaf_entry <= {
      leaf_flags[1],
      leaf_flags[2],
      leaf_flags[3],
      leaf_flags[4],
      leaf_flags[7],
      leaf_flags[6],
      leaf_page,
      w_vaddr[31:12+IDX_BITS]
    };
  end
end

(* anyconst *) logic [IDX_BITS-1:0] watch_row;
logic ref_i_valid, ref_d_valid;
logic [TLB_W-1:0] ref_i_entry, ref_d_entry;
always @(posedge clk) begin
  if (rst || flush) begin
    ref_i_valid <= 0;
    ref_d_valid <= 0;
  end else if (wstate == W_INSTALL && !w_discard && w_idx == watch_row) begin
    if (w_is_if) begin
      ref_i_valid <= !iflush;
      ref_i_entry <= leaf_entry;
    end else begin
      ref_d_valid <= 1;
      ref_d_entry <= leaf_entry;
    end
  end
end

logic [31:0] root_i_address, root_d_address;
logic select_d_walk, select_i_walk, root_d_in_range, root_i_in_range;
assign root_i_address = {satp[19:0], i_vaddr[31:22], 2'b00};
assign root_d_address = {satp[19:0], d_vaddr[31:22], 2'b00};
assign root_d_in_range = table_address(root_d_address);
assign root_i_in_range = table_address(root_i_address);
assign select_d_walk = wstate == W_IDLE && !flush && d_miss_pending && satp[31] &&
                         priv_data != PRIV_M && d_req;
assign select_i_walk = wstate == W_IDLE && !flush && !iflush && !select_d_walk &&
                         i_miss_pending && satp[31] && priv_fetch != PRIV_M && i_req;
logic watched_d_match, watched_d_allowed;
logic [7:0] watched_d_flags;
assign watched_d_match = ref_d_valid && ref_d_entry[TAG_BITS-1:0] == d_vaddr[31:12+IDX_BITS];
assign watched_d_flags = {
  ref_d_entry[P_D],
  ref_d_entry[P_A],
  1'b0,
  ref_d_entry[P_U],
  ref_d_entry[P_X],
  ref_d_entry[P_W],
  ref_d_entry[P_R],
  1'b1
};
assign watched_d_allowed = watched_d_match && allow(
    watched_d_flags, 0, d_we, priv_data, mstatus_sum, mstatus_mxr
);

always @(posedge clk) begin
  if (!rst && seen_clock) begin
    assert (pte_valid_q == sampled);
    if (sampled) assert (pte_data_q == response_pte);
    assert ((outstanding || sampled) == (wstate == W_PTE1_WAIT || wstate == W_PTE0_WAIT));
    assert (!(outstanding && sampled));
    assert (ptw_r_ready);
    if (ptw_ar.valid) begin
      assert (ptw_ar.addr[1:0] == 0 && table_address(ptw_ar.addr));
      assert (ptw_ar.len == 0 && ptw_ar.size == 2 && ptw_ar.id == 0);
    end
    if (wstate != W_IDLE) assert (w_priv == PRIV_U || w_priv == PRIV_S);
    if (wstate == W_INSTALL) assert (w_install_word == leaf_entry);
    assert (i_valid[watch_row] == ref_i_valid && d_valid[watch_row] == ref_d_valid);
    if (ref_i_valid) assert (itlb[watch_row] == ref_i_entry);
    if (ref_d_valid) assert (dtlb[watch_row] == ref_d_entry);
    if (i_hot_valid && i_hot_vpn[IDX_BITS-1:0] == watch_row) begin
      assert (ref_i_valid && ref_i_entry[TAG_BITS-1:0] == i_hot_vpn[19:IDX_BITS]);
      assert (ref_i_entry[TAG_BITS+:20] == i_hot_ppn);
      assert (ref_i_entry[P_X] && ref_i_entry[P_A]);
      assert ((i_hot_priv == PRIV_U && ref_i_entry[P_U]) ||
                (i_hot_priv == PRIV_S && !ref_i_entry[P_U]));
    end
    if (!satp[31] || priv_fetch == PRIV_M) begin
      assert (i_hit && ic_addr == i_vaddr);
    end else if (i_hit) begin
      assert (ic_addr == {i_hot_ppn, i_vaddr[11:0]});
    end
    if (!satp[31] || priv_data == PRIV_M) begin
      assert (d_hit && !d_fault && d_paddr == d_vaddr);
    end else if (d_idx == watch_row) begin
      assert (d_hit == watched_d_allowed);
      if (watched_d_allowed) assert (d_paddr == {ref_d_entry[TAG_BITS+:20], d_vaddr[11:0]});
      if (d_req && watched_d_match && !watched_d_allowed)
        assert (d_fault && d_fault_cause == (d_we ? 4'd15 : 4'd13));
    end

    if (!$past(rst)) begin
      if ($past(ptw_ar.valid && !p_ready)) assert (ptw_ar.valid && $stable(ptw_ar));
      if ($past(select_d_walk)) begin
        if ($past(root_d_in_range)) begin
          assert (ptw_ar.valid && ptw_ar.addr == $past(root_d_address) && !w_is_if && w_vaddr ==
                  $past(d_vaddr) && w_is_store == $past(d_we) && w_priv == $past(priv_data));
        end else begin
          assert (wstate == W_IDLE && d_fault_pending && d_fault_vpn == $past(d_vaddr[31:12]) &&
                  d_fault_cause_q == ($past(d_we) ? 4'd15 : 4'd13));
        end
      end
      if ($past(select_i_walk)) begin
        if ($past(root_i_in_range)) begin
          assert (ptw_ar.valid && ptw_ar.addr == $past(root_i_address) && w_is_if &&
                  w_vaddr == $past(i_vaddr) && !w_is_store && w_priv == $past(priv_fetch));
        end else begin
          assert (wstate == W_IDLE && i_fault && i_fault_addr == $past(i_vaddr));
        end
      end
      if ($past(follow_pointer && !w_discard && !flush && !(iflush && w_is_if)))
        assert (wstate == W_PTE0_REQ && ptw_ar.addr == $past(next_address));
      if ($past(accept_leaf && !w_discard && !flush && !(iflush && w_is_if)))
        assert (wstate == W_INSTALL);
      if ($past(reject && !w_discard && !flush && !(iflush && w_is_if))) begin
        assert (wstate == W_IDLE);
        if ($past(w_is_if)) begin
          assert (i_fault && i_fault_addr == $past(w_vaddr));
        end else begin
          assert (d_fault_pending && d_fault_vpn == $past(w_vaddr[31:12]) &&
                  d_fault_cause_q == ($past(w_is_store) ? 4'd15 : 4'd13));
        end
      end
      if ($past(sampled && (w_discard || flush || (iflush && w_is_if)))) assert (wstate == W_IDLE);
      if ($past(flush)) assert (!(|i_valid) && !(|d_valid) && !i_hot_valid);
    end

    cover (root_reply && accept_leaf && w_is_if && !w_discard && !flush && !iflush);
    cover (leaf_reply && accept_leaf && !w_is_if && !w_discard && !flush);
    cover (reject && leaf_reply && !w_discard && !flush);
    cover (ptw_ar.valid && !p_ready && flush);
    cover (sampled && w_discard);
    cover (i_translate && i_req && i_hit);
    cover (d_translate && d_req && d_hit && d_we);
  end
end
