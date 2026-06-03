`timescale 1ns / 1ps
// ============================================================================
// 256-bit Linear Feedback Shift Register (LFSR)
//
// Maximal-length LFSR using primitive polynomial over GF(2^256)
// Taps at bits 255, 253, 250, 245 (feedback: x^256 + x^253 + x^250 + x^245 + 1)
//
// Used by the controller to generate a masking sequence for PUF response
// dispersion before error correction decoding.
//
// Feature: advanced-sram-puf
// ============================================================================

module lfsr_256 #(
    parameter WIDTH = 256
)(
    input  wire              clk,
    input  wire              rst,
    input  wire [WIDTH-1:0]  seed,       // Initial seed value
    input  wire              load,       // Load seed (synchronous)
    input  wire              enable,     // Shift enable
    output wire [WIDTH-1:0]  lfsr_out,   // Full parallel output
    output wire              lfsr_bit    // Serial output (LSB)
);

    // ========================================================================
    // LFSR Register
    // ========================================================================

    reg [WIDTH-1:0] lfsr_reg;

    // Feedback taps: bits 255, 253, 250, 245
    // Primitive polynomial: x^256 + x^253 + x^250 + x^245 + 1
    wire feedback;
    assign feedback = lfsr_reg[255] ^ lfsr_reg[253] ^ lfsr_reg[250] ^ lfsr_reg[245];

    // ========================================================================
    // Shift Logic
    // ========================================================================

    always @(posedge clk) begin
        if (rst) begin
            lfsr_reg <= {WIDTH{1'b1}};  // Non-zero default to avoid lock-up
        end
        else if (load) begin
            // Load seed; ensure non-zero to prevent LFSR lock-up
            if (seed == {WIDTH{1'b0}})
                lfsr_reg <= {WIDTH{1'b1}};
            else
                lfsr_reg <= seed;
        end
        else if (enable) begin
            lfsr_reg <= {lfsr_reg[WIDTH-2:0], feedback};
        end
    end

    // ========================================================================
    // Outputs
    // ========================================================================

    assign lfsr_out = lfsr_reg;
    assign lfsr_bit = lfsr_reg[0];

endmodule