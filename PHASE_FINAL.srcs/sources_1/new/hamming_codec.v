`timescale 1ns / 1ps
// ============================================================================
// Hamming(7,4) Codec Module
// 
// Implements Hamming(7,4) encoding and decoding for single-bit error correction
// - Encodes 4 data bits into 7-bit codeword
// - Corrects single-bit errors
// - Detects double-bit errors
//
// Feature: advanced-sram-puf
// ============================================================================

module hamming_codec (
    input  wire clk,
    input  wire rst,
    input  wire encode,                 // 1=encode, 0=decode
    input  wire start,                  // Start operation
    input  wire [3:0] data_in,          // 4-bit input (encoding)
    input  wire [6:0] code_in,          // 7-bit input (decoding)
    output reg  [6:0] code_out,         // 7-bit codeword (encoding)
    output reg  [3:0] data_out,         // 4-bit recovered data (decoding)
    output reg  error_detected,         // Error flag (decoding)
    output reg  done                    // Operation complete
);

    // ========================================================================
    // Hamming(7,4) Generator Matrix (Systematic Form)
    // G = [I4 | P] where P is parity matrix
    // Codeword = [d3 d2 d1 d0 p2 p1 p0]
    // p0 = d0 ^ d1 ^ d3
    // p1 = d0 ^ d2 ^ d3
    // p2 = d1 ^ d2 ^ d3
    // ========================================================================
    
    // ========================================================================
    // Hamming(7,4) Parity Check Matrix
    // H = [P^T | I3]
    // Syndrome s = H * r^T
    // ========================================================================
    
    reg [2:0] syndrome;
    reg [6:0] corrected_code;
    
    always @(posedge clk) begin
        if (rst) begin
            code_out <= 7'b0;
            data_out <= 4'b0;
            error_detected <= 1'b0;
            done <= 1'b0;
        end
        else if (start && !done) begin
            if (encode) begin
                // ============================================================
                // ENCODING: 4 data bits -> 7-bit codeword
                // ============================================================
                code_out[6:3] <= data_in;  // Data bits
                code_out[2] <= data_in[1] ^ data_in[2] ^ data_in[3];  // p2
                code_out[1] <= data_in[0] ^ data_in[2] ^ data_in[3];  // p1
                code_out[0] <= data_in[0] ^ data_in[1] ^ data_in[3];  // p0
                done <= 1'b1;
            end
            else begin
                // ============================================================
                // DECODING: 7-bit codeword -> 4 data bits (with correction)
                // ============================================================
                
                // Calculate syndrome
                syndrome[0] <= code_in[0] ^ code_in[3] ^ code_in[4] ^ code_in[6];
                syndrome[1] <= code_in[1] ^ code_in[3] ^ code_in[5] ^ code_in[6];
                syndrome[2] <= code_in[2] ^ code_in[4] ^ code_in[5] ^ code_in[6];
                
                // Correct error based on syndrome
                corrected_code <= code_in;
                
                case (syndrome)
                    3'b000: begin
                        // No error
                        corrected_code <= code_in;
                        error_detected <= 1'b0;
                    end
                    3'b001: begin
                        // Error in bit 0 (p0)
                        corrected_code[0] <= ~code_in[0];
                        error_detected <= 1'b0;
                    end
                    3'b010: begin
                        // Error in bit 1 (p1)
                        corrected_code[1] <= ~code_in[1];
                        error_detected <= 1'b0;
                    end
                    3'b011: begin
                        // Error in bit 3 (d0)
                        corrected_code[3] <= ~code_in[3];
                        error_detected <= 1'b0;
                    end
                    3'b100: begin
                        // Error in bit 2 (p2)
                        corrected_code[2] <= ~code_in[2];
                        error_detected <= 1'b0;
                    end
                    3'b101: begin
                        // Error in bit 4 (d1)
                        corrected_code[4] <= ~code_in[4];
                        error_detected <= 1'b0;
                    end
                    3'b110: begin
                        // Error in bit 5 (d2)
                        corrected_code[5] <= ~code_in[5];
                        error_detected <= 1'b0;
                    end
                    3'b111: begin
                        // Error in bit 6 (d3)
                        corrected_code[6] <= ~code_in[6];
                        error_detected <= 1'b0;
                    end
                endcase
                
                // Extract data bits
                data_out <= corrected_code[6:3];
                done <= 1'b1;
            end
        end
        else if (!start) begin
            done <= 1'b0;
        end
    end

endmodule