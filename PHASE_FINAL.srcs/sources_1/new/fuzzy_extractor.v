//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11.04.2026 12:03:01
// Design Name: 
// Module Name: fuzzy_extractor
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
// ============================================================================
// Fuzzy Extractor Module
//
// Enrollment mode:
//   1. Filter metastable PUF bits -> stable_puf_bits (128 bits)
//   2. Use stable_puf_bits as secret
//   3. Encode secret block-by-block using selected ECC codec
//   4. helper_out = encoded codeword XOR stable_puf_bits (source coding)
//
// Reconstruction mode:
//   1. Filter metastable PUF bits -> stable_puf_bits (noisy, 128 bits)
//   2. noisy_codeword = stable_puf_bits XOR helper_in  (undo source coding)
//   3. Decode noisy_codeword block-by-block using selected ECC codec
//   4. secret_out = decoded data bits
//
// Hamming(7,4): 128-bit secret -> 32 blocks x 4 bits -> 32 x 7 = 224-bit helper
// BCH(31,16):   128-bit secret ->  8 blocks x 16 bits ->  8 x 31 = 248-bit helper
//
// HELPER_BITS parameter must match:
//   USE_BCH=0 -> 224  (32 * 7)
//   USE_BCH=1 -> 248  ( 8 * 31)
//
// Feature: advanced-sram-puf
// ============================================================================

`include "sram_puf_params.vh"

module fuzzy_extractor #(
    parameter PUF_BITS    = 256,
    parameter SECRET_BITS = 128,
    parameter USE_BCH     = 1,    // 0=Hamming(7,4), 1=BCH(31,16,3)
    parameter HELPER_BITS = 248   // 8*31 for BCH; set to 224 for Hamming
)(
    input  wire clk,
    input  wire rst,
    input  wire mode,                         // 0=enrollment, 1=reconstruction
    input  wire start,
    input  wire [PUF_BITS-1:0]    puf_in,    // PUF response
    input  wire [PUF_BITS-1:0]    meta_mask, // Metastability mask (1=exclude)
    input  wire [HELPER_BITS-1:0] helper_in, // Helper data (reconstruction)
    output reg  [SECRET_BITS-1:0] secret_out,
    output reg  [HELPER_BITS-1:0] helper_out,
    output reg  error_flag,
    output reg  done
);

    // ========================================================================
    // Codec geometry
    //   Hamming(7,4): data_bits=4, code_bits=7
    //   BCH(31,16,3): data_bits=16, code_bits=31
    // ========================================================================
    localparam DATA_BITS = (USE_BCH == 0) ? 4  : 16;
    localparam CODE_BITS = (USE_BCH == 0) ? 7  : 31;
    localparam N_BLOCKS  = SECRET_BITS / DATA_BITS; // 32 or 8

    // ========================================================================
    // Internal registers
    // ========================================================================
    reg [SECRET_BITS-1:0]  stable_puf_bits;
    reg [SECRET_BITS-1:0]  secret_bits;
    reg [HELPER_BITS-1:0]  encoded_cw;      // accumulated encoded codeword
    reg [HELPER_BITS-1:0]  decoded_secret;  // accumulated decoded data

    // Block-processing counter
    reg [5:0] blk_idx;   // up to 32 blocks

    // Codec I/O registers (driven by FSM)
    reg [15:0] codec_data_in;  // max DATA_BITS=16
    reg [30:0] codec_code_in;  // max CODE_BITS=31
    reg        codec_start;
    reg        codec_encode;

    // Codec outputs (wired from generate block)
    wire [30:0] codec_code_out;
    wire [15:0] codec_data_out;
    wire        codec_done;
    wire        codec_error;

    // ========================================================================
    // State machine
    // ========================================================================
    reg [3:0] state;
    localparam IDLE          = 4'd0;
    localparam FILTER_PUF    = 4'd1;
    localparam GEN_SECRET    = 4'd2;
    localparam ENCODE_START  = 4'd3;
    localparam ENCODE_WAIT   = 4'd4;
    localparam ENCODE_NEXT   = 4'd5;
    localparam BUILD_HELPER  = 4'd6;
    localparam DECODE_START  = 4'd7;
    localparam DECODE_WAIT   = 4'd8;
    localparam DECODE_NEXT   = 4'd9;
    localparam DONE_STATE    = 4'd10;

    integer i;
    reg [9:0] stable_count;

    // ========================================================================
    // Codec instantiation
    // ========================================================================
    generate
        if (USE_BCH == 0) begin : hamming_gen
            wire [6:0] ham_code_out;
            wire [3:0] ham_data_out;
            wire       ham_error;
            wire       ham_done;

            hamming_codec hamming_inst (
                .clk           (clk),
                .rst           (rst),
                .encode        (codec_encode),
                .start         (codec_start),
                .data_in       (codec_data_in[3:0]),
                .code_in       (codec_code_in[6:0]),
                .code_out      (ham_code_out),
                .data_out      (ham_data_out),
                .error_detected(ham_error),
                .done          (ham_done)
            );

            assign codec_code_out = {24'b0, ham_code_out};
            assign codec_data_out = {12'b0, ham_data_out};
            assign codec_done     = ham_done;
            assign codec_error    = ham_error;
        end
        else begin : bch_gen
            wire [30:0] bch_code_out;
            wire [15:0] bch_data_out;
            wire        bch_error;
            wire        bch_done;

            bch_codec #(
                .M(5),
                .T(3),
                .N(31),
                .K(16)
            ) bch_inst (
                .clk      (clk),
                .rst      (rst),
                .encode   (codec_encode),
                .start    (codec_start),
                .data_in  (codec_data_in[15:0]),
                .code_in  (codec_code_in[30:0]),
                .code_out (bch_code_out),
                .data_out (bch_data_out),
                .error_flag(bch_error),
                .done     (bch_done)
            );

            assign codec_code_out = bch_code_out;
            assign codec_data_out = {bch_data_out};
            assign codec_done     = bch_done;
            assign codec_error    = bch_error;
        end
    endgenerate

    // ========================================================================
    // Main FSM
    // ========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state          <= IDLE;
            done           <= 1'b0;
            error_flag     <= 1'b0;
            codec_start    <= 1'b0;
            codec_encode   <= 1'b0;
            codec_data_in  <= 16'b0;
            codec_code_in  <= 31'b0;
            secret_out     <= {SECRET_BITS{1'b0}};
            helper_out     <= {HELPER_BITS{1'b0}};
            blk_idx        <= 0;
            stable_count   <= 0;
            encoded_cw     <= {HELPER_BITS{1'b0}};
            decoded_secret <= {SECRET_BITS{1'b0}};
        end
        else begin
            case (state)

                // ------------------------------------------------------------
                IDLE: begin
                    done       <= 1'b0;
                    error_flag <= 1'b0;
                    if (start)
                        state <= FILTER_PUF;
                end

                // ------------------------------------------------------------
                // Filter metastable cells; collect SECRET_BITS stable bits
                // ------------------------------------------------------------
                FILTER_PUF: begin
                    begin : filter_block
                        integer fi, fj;
                        fj = 0;
                        for (fi = 0; fi < PUF_BITS; fi = fi + 1) begin
                            if (!meta_mask[fi] && fj < SECRET_BITS) begin
                                stable_puf_bits[fj] = puf_in[fi];
                                fj = fj + 1;
                            end
                        end
                        stable_count = fj;
                    end

                    if (stable_count < SECRET_BITS) begin
                        error_flag <= 1'b1;
                        state      <= DONE_STATE;
                    end
                    else if (mode == 1'b0)
                        state <= GEN_SECRET;   // enrollment
                    else begin
                        // reconstruction: prepare first decode block
                        blk_idx        <= 0;
                        decoded_secret <= {SECRET_BITS{1'b0}};
                        state          <= DECODE_START;
                    end
                end

                // ------------------------------------------------------------
                // Enrollment: latch secret, prepare encode loop
                // ------------------------------------------------------------
                GEN_SECRET: begin
                    secret_bits <= stable_puf_bits[SECRET_BITS-1:0];
                    blk_idx     <= 0;
                    encoded_cw  <= {HELPER_BITS{1'b0}};
                    state       <= ENCODE_START;
                end

                // ------------------------------------------------------------
                // ENCODE_START: load one block into codec and pulse start
                // ------------------------------------------------------------
                ENCODE_START: begin
                    if (blk_idx < N_BLOCKS) begin
                        // Extract DATA_BITS-wide slice from secret_bits
                        codec_data_in <= secret_bits[blk_idx*DATA_BITS +: DATA_BITS];
                        codec_encode  <= 1'b1;
                        codec_start   <= 1'b1;
                        state         <= ENCODE_WAIT;
                    end
                    else begin
                        // All blocks encoded -> build helper
                        state <= BUILD_HELPER;
                    end
                end

                // ------------------------------------------------------------
                // ENCODE_WAIT: wait for codec to finish one block
                // ------------------------------------------------------------
                ENCODE_WAIT: begin
                    codec_start <= 1'b0;  // deassert after one cycle
                    if (codec_done) begin
                        // Store CODE_BITS-wide result into encoded_cw
                        encoded_cw[blk_idx*CODE_BITS +: CODE_BITS] <= codec_code_out[CODE_BITS-1:0];
                        state <= ENCODE_NEXT;
                    end
                end

                // ------------------------------------------------------------
                // ENCODE_NEXT: advance block counter
                // ------------------------------------------------------------
                ENCODE_NEXT: begin
                    blk_idx <= blk_idx + 1;
                    state   <= ENCODE_START;
                end

                // ------------------------------------------------------------
                // BUILD_HELPER: helper = encoded_cw XOR stable_puf_bits
                // (source coding / secure sketch)
                // ------------------------------------------------------------
                BUILD_HELPER: begin
                    // Pad stable_puf_bits to HELPER_BITS for XOR
                    helper_out <= encoded_cw ^ {{(HELPER_BITS-SECRET_BITS){1'b0}}, secret_bits};
                    secret_out <= secret_bits;
                    state      <= DONE_STATE;
                end

                // ------------------------------------------------------------
                // DECODE_START: XOR noisy PUF with helper to recover noisy codeword,
                //               load one block into codec and pulse start
                // ------------------------------------------------------------
                DECODE_START: begin
                    if (blk_idx < N_BLOCKS) begin
                        begin : decode_load
                            reg [HELPER_BITS-1:0] noisy_cw;
                            // noisy_codeword = helper_in XOR stable_puf_bits (padded)
                            noisy_cw = helper_in ^ {{(HELPER_BITS-SECRET_BITS){1'b0}},
                                                     stable_puf_bits[SECRET_BITS-1:0]};
                            codec_code_in <= noisy_cw[blk_idx*CODE_BITS +: CODE_BITS];
                        end
                        codec_encode <= 1'b0;  // decode
                        codec_start  <= 1'b1;
                        state        <= DECODE_WAIT;
                    end
                    else begin
                        // All blocks decoded
                        secret_out <= decoded_secret[SECRET_BITS-1:0];
                        state      <= DONE_STATE;
                    end
                end

                // ------------------------------------------------------------
                // DECODE_WAIT: wait for codec to finish one block
                // ------------------------------------------------------------
                DECODE_WAIT: begin
                    codec_start <= 1'b0;
                    if (codec_done) begin
                        if (codec_error) begin
                            error_flag <= 1'b1;
                            state      <= DONE_STATE;
                        end
                        else begin
                            decoded_secret[blk_idx*DATA_BITS +: DATA_BITS]
                                <= codec_data_out[DATA_BITS-1:0];
                            state <= DECODE_NEXT;
                        end
                    end
                end

                // ------------------------------------------------------------
                // DECODE_NEXT: advance block counter
                // ------------------------------------------------------------
                DECODE_NEXT: begin
                    blk_idx <= blk_idx + 1;
                    state   <= DECODE_START;
                end

                // ------------------------------------------------------------
                DONE_STATE: begin
                    done <= 1'b1;
                    if (!start) begin
                        done       <= 1'b0;
                        error_flag <= 1'b0;
                        state      <= IDLE;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
