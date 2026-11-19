// A single element width is selected per program. All matching vsetivli
// AVLs, register choices and unmasked unit-stride loads/stores can mix.
function automatic logic stream_vector_word(input logic [31:0] word, input logic [1:0] width);
  case (word[6:0])
    7'h57:
    stream_vector_word = word[31:28] == 4'hc && word[25:20] == {1'b0, width, 3'b000} &&
                                word[14:12] == 7;
    7'h07, 7'h27:
    stream_vector_word = word[31:20] == 12'h020 &&
                                       word[14:12] == (width == 0 ? 3'd0 : width == 1 ? 3'd5 : 3'd6);
    7'h13: stream_vector_word = word[14:12] == 0;
    7'h37: stream_vector_word = 1;
    default: stream_vector_word = 0;
  endcase
endfunction
