// RV32I instruction decoder.
//
// Pure combinational logic: instruction word in, control bundle out.
// CSR existence and write permission are checked in EX, where the
// architectural CSR read data is available.

`default_nettype none
`include "rv32_defs.svh"

module rv32_decoder (
  input logic [31:0] instr,
  output logic [4:0] rs1,
  output logic [4:0] rs2,
  output logic [4:0] rd,
  output logic [2:0] funct3,
  output logic [31:0] imm,
  output logic use_rs1,
  output logic use_rs2,
  output logic alu_b_imm,
  output logic alu_a_pc,
  output logic [3:0] alu_op,
  output logic regwrite,
  output logic is_load,
  output logic is_store,
  output logic is_branch,
  output logic is_jal,
  output logic is_jalr,
  output logic is_csr,
  output logic csr_uimm,
  output logic [1:0] csr_op,
  output logic [11:0] csr_addr,
  output logic illegal,
  output logic ecall,
  output logic ebreak,
  output logic mret,
  output logic sret,
  output logic is_sfence,
  output logic is_fence_i
);

  always_comb begin
    rs1 = instr[19:15];
    rs2 = instr[24:20];
    rd = instr[11:7];
    funct3 = instr[14:12];
    imm = '0;
    use_rs1 = 1'b0;
    use_rs2 = 1'b0;
    alu_b_imm = 1'b0;
    alu_a_pc = 1'b0;
    alu_op = `RV32_ALU_ADD;
    regwrite = 1'b0;
    is_load = 1'b0;
    is_store = 1'b0;
    is_branch = 1'b0;
    is_jal = 1'b0;
    is_jalr = 1'b0;
    is_csr = 1'b0;
    csr_uimm = 1'b0;
    csr_op = `RV32_CSR_RW;
    csr_addr = instr[31:20];
    illegal = 1'b0;
    ecall = 1'b0;
    ebreak = 1'b0;
    mret = 1'b0;
    sret = 1'b0;
    is_sfence = 1'b0;
    is_fence_i = 1'b0;

    case (instr[6:0])
      7'b0110111: begin  // LUI
        imm = {instr[31:12], 12'b0};
        regwrite = 1'b1;
        alu_b_imm = 1'b1;
        alu_op = `RV32_ALU_PASS_B;
      end
      7'b0010111: begin  // AUIPC
        imm = {instr[31:12], 12'b0};
        regwrite = 1'b1;
        alu_b_imm = 1'b1;
        alu_a_pc = 1'b1;
        alu_op = `RV32_ALU_ADD;
      end
      7'b1101111: begin  // JAL
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
        regwrite = 1'b1;
        is_jal = 1'b1;
        alu_b_imm = 1'b1;
        alu_a_pc = 1'b1;
        alu_op = `RV32_ALU_ADD;
      end
      7'b1100111: begin  // JALR
        imm = {{20{instr[31]}}, instr[31:20]};
        use_rs1 = 1'b1;
        alu_b_imm = 1'b1;
        alu_op = `RV32_ALU_ADD;
        if (instr[14:12] == 3'b000) begin
          regwrite = 1'b1;
          is_jalr = 1'b1;
        end else begin
          illegal = 1'b1;
        end
      end
      7'b1100011: begin  // branches
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        use_rs1 = 1'b1;
        use_rs2 = 1'b1;
        case (instr[14:12])
          3'b000, 3'b001: begin
            alu_op = `RV32_ALU_SUB;
          end
          3'b100, 3'b101: begin
            alu_op = `RV32_ALU_SLT;
          end
          3'b110, 3'b111: begin
            alu_op = `RV32_ALU_SLTU;
          end
          default: begin
            illegal = 1'b1;
          end
        endcase
        if (!illegal) begin
          is_branch = 1'b1;
        end
      end
      7'b0000011: begin  // loads
        imm = {{20{instr[31]}}, instr[31:20]};
        use_rs1 = 1'b1;
        alu_b_imm = 1'b1;
        alu_op = `RV32_ALU_ADD;
        if ((instr[14:12] == 3'b011) || (instr[14:12] == 3'b110) || (instr[14:12] == 3'b111)) begin
          illegal = 1'b1;
        end else begin
          regwrite = 1'b1;
          is_load = 1'b1;
        end
      end
      7'b0100011: begin  // stores
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        use_rs1 = 1'b1;
        use_rs2 = 1'b1;
        alu_b_imm = 1'b1;
        alu_op = `RV32_ALU_ADD;
        if (instr[14:12] > 3'b010) begin
          illegal = 1'b1;
        end else begin
          is_store = 1'b1;
        end
      end
      7'b0010011: begin  // OP-IMM
        imm = {{20{instr[31]}}, instr[31:20]};
        use_rs1 = 1'b1;
        alu_b_imm = 1'b1;
        regwrite = 1'b1;
        case (instr[14:12])
          3'b000: begin
            alu_op = `RV32_ALU_ADD;
          end
          3'b010: begin
            alu_op = `RV32_ALU_SLT;
          end
          3'b011: begin
            alu_op = `RV32_ALU_SLTU;
          end
          3'b100: begin
            alu_op = `RV32_ALU_XOR;
          end
          3'b110: begin
            alu_op = `RV32_ALU_OR;
          end
          3'b111: begin
            alu_op = `RV32_ALU_AND;
          end
          3'b001: begin
            alu_op = `RV32_ALU_SLL;
            if (instr[31:25] != 7'b0) begin
              illegal = 1'b1;
            end
          end
          3'b101: begin
            if (instr[31:25] == 7'b0) begin
              alu_op = `RV32_ALU_SRL;
            end else if (instr[31:25] == 7'h20) begin
              alu_op = `RV32_ALU_SRA;
            end else begin
              illegal = 1'b1;
            end
          end
          default: begin
            illegal = 1'b1;
          end
        endcase
      end
      7'b0110011: begin  // OP
        use_rs1 = 1'b1;
        use_rs2 = 1'b1;
        regwrite = 1'b1;
        case (instr[14:12])
          3'b000: begin
            alu_op = (instr[31:25] == 7'h20) ? `RV32_ALU_SUB : `RV32_ALU_ADD;
          end
          3'b001: begin
            alu_op = `RV32_ALU_SLL;
          end
          3'b010: begin
            alu_op = `RV32_ALU_SLT;
          end
          3'b011: begin
            alu_op = `RV32_ALU_SLTU;
          end
          3'b100: begin
            alu_op = `RV32_ALU_XOR;
          end
          3'b101: begin
            alu_op = (instr[31:25] == 7'h20) ? `RV32_ALU_SRA : `RV32_ALU_SRL;
          end
          3'b110: begin
            alu_op = `RV32_ALU_OR;
          end
          3'b111: begin
            alu_op = `RV32_ALU_AND;
          end
          default: begin
            illegal = 1'b1;
          end
        endcase
        if (!((instr[31:25] == 7'h00) ||
              ((instr[31:25] == 7'h20) &&
               ((instr[14:12] == 3'b000) || (instr[14:12] == 3'b101))))) begin
          illegal = 1'b1;
        end
      end
      7'b0001111: begin  // FENCE is a NOP; FENCE.I flushes the I-cache
        if (instr[14:12] == 3'b001) begin
          is_fence_i = 1'b1;
        end else if (instr[14:12] != 3'b000) begin
          illegal = 1'b1;
        end
      end
      7'b1110011: begin  // SYSTEM
        if (instr[14:12] == 3'b000) begin
          case (instr[31:20])
            12'h000: begin
              ecall = 1'b1;
            end
            12'h001: begin
              ebreak = 1'b1;
            end
            12'h102: begin
              sret = 1'b1;
            end
            12'h302: begin
              mret = 1'b1;
            end
            default: begin
              if (instr[31:25] == 7'b0001001) begin
                is_sfence = 1'b1;
              end else begin
                illegal = 1'b1;
              end
            end
          endcase
        end else if (instr[14:12] == 3'b100) begin
          illegal = 1'b1;
        end else begin
          is_csr = 1'b1;
          regwrite = 1'b1;
          use_rs1 = 1'b1;
          csr_uimm = instr[14];
          // funct3[1:0]: 01 = CSRRW, 10 = CSRRS, 11 = CSRRC.
          if (instr[13:12] == 2'b01) begin
            csr_op = `RV32_CSR_RW;
          end else if (instr[13:12] == 2'b10) begin
            csr_op = `RV32_CSR_RS;
          end else begin
            csr_op = `RV32_CSR_RC;
          end
        end
      end
      default: begin
        illegal = 1'b1;
      end
    endcase
  end

endmodule
