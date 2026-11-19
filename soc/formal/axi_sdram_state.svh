// Shared handshake scoreboard and induction observations.
logic past_valid, active, writing, supported, issued, final_w, drained;
logic ar_fire, aw_fire, w_fire, req_fire, r_fire, b_fire;
logic [31:0] base;
logic [3:0] id;
logic [8:0] length, transferred;
logic [4:0] received;
`ifdef ROCO_SOC_SDRAM_MEMORY_FORMAL
// The SoC checker follows the arbitrary device word in each accepted burst.
// The standalone adapter checker independently quantifies every buffer slot.
logic [3:0] f_watch;
`else
(* anyconst *) logic [3:0] f_watch;
`endif
logic [31:0] watched_data, f_read_word;
logic [5:0] f_phase;
logic [4:0] f_captured;
logic [7:0] f_beat, f_len;
logic [3:0] f_id;
logic [22:0] f_addr;
logic f_write, f_error;
