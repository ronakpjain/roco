// Syntactic test used at fetch and as an asserted live-word invariant.
// There is no ISA-legality assumption for the scalar ALU/load/store sets.
function automatic logic irq_fetch_allowed(input logic [31:0] word);
  case (word[6:0])
    7'h37, 7'h17, 7'h6f, 7'h67, 7'h63, 7'h03, 7'h23, 7'h13, 7'h2f, 7'h33: irq_fetch_allowed = 1;
    7'h0f: irq_fetch_allowed = word[14:12] == 0;
    7'h73:
    irq_fetch_allowed = word[14:12] != 0 ?
                              (word[31:20] != 12'h180 && word[31:20] != 12'h302 &&
                               word[31:20] != 12'h303) :
                              (word == 32'h3020_0073 || word == 32'h0000_0073 ||
                               word == 32'h0010_0073);
    default: irq_fetch_allowed = word == 0;
  endcase
endfunction
