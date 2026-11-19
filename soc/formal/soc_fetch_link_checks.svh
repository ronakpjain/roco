// Fence completion clears the queue before its coherent interval resumes.
// Physical response tags cross the real MMU alongside its virtual tag;
// the MMU data path and request-pair history are both checked here.
logic f_fetch_coherent;
logic [31:0] f_fetch_virtual_addr, f_fetch_physical_addr;
always_ff @(posedge clk) begin
  f_fetch_virtual_addr <= if_imem_addr;
  f_fetch_physical_addr <= imem_addr;
  if (rst) f_fetch_coherent <= 1'b1;
  else if (dmem_req && dmem_we && dmem_addr[31:2] == {7'd8, formal_watch_word})
    f_fetch_coherent <= 1'b0;
  else if (mem_redirect && !halt) f_fetch_coherent <= 1'b1;
  if (!rst) begin
    if (f_fetch_coherent) assert (formal_instruction_coherent);
    if (mem_redirect && !halt) assert (formal_instruction_coherent);
    if (if_imem_rsp_valid) begin
      assert (imem_rsp_valid && if_imem_rsp_data == imem_rsp_data);
      assert (if_imem_rsp_addr == f_fetch_virtual_addr);
      assert (imem_rsp_addr == f_fetch_physical_addr);
      if (formal_instruction_coherent && imem_rsp_addr[31:2] == {7'd8, formal_watch_word})
        assert (if_imem_rsp_data == formal_watch_data);
    end
    cover (if_imem_rsp_valid);
    cover (if_imem_rsp_valid && imem_rsp_addr[31:2] == {7'd8, formal_watch_word});
    cover (!f_fetch_coherent);
    cover (mem_redirect);
  end
end
