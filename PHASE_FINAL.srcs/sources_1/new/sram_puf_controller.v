`timescale 1ns / 1ps
// ============================================================================
// SRAM PUF Controller - Top Level Module
//
// Workflow:
//   SRAM PUF (256 cells)
//     -> 10-cycle enrollment + stability filtering
//     -> Fuzzy Extractor (BCH error correction)
//     -> SHA-256 (128-bit secret -> 256-bit key)
//     -> 256-bit Galois LFSR (key expansion)
//     -> Final 256-bit cryptographic key
//
// Feature: advanced-sram-puf
// ============================================================================

`include "sram_puf_params.vh"

// HELPER_BITS must match codec geometry:
//   USE_BCH=0 (Hamming 7,4): 32 blocks * 7 bits = 224
//   USE_BCH=1 (BCH 31,16):    8 blocks * 31 bits = 248
module sram_puf_controller #(
    parameter N = `DEFAULT_PUF_SIZE,
    parameter SECRET_BITS = 128,
    parameter USE_BCH = 1,
    parameter HELPER_BITS = (USE_BCH == 0) ? 224 : 248,
    parameter ENROLL_CYCLES = `DEFAULT_ENROLL_CYCLES,
    parameter STABILITY_THRESHOLD = `DEFAULT_STABILITY_THRESH
)(
    input  wire clk,
    input  wire rst,
    input  wire start_enroll,
    input  wire start_reconstruct,
    input  wire [HELPER_BITS-1:0] helper_data_in,
    output reg  operation_done,
    output reg  [255:0] key_out,
    output reg  [HELPER_BITS-1:0] helper_data_out,
    output reg  error_flag
);

    // ========================================================================
    // FSM State Register
    // ========================================================================
    reg [3:0] state;

    // ========================================================================
    // PUF Core Signals
    // ========================================================================
    reg          puf_rst;
    reg          puf_read_enable;
    wire         puf_read_done;
    wire [N-1:0] puf_response;
    wire [N-1:0] meta_flags;
    wire         puf_bit;

    // ========================================================================
    // Fuzzy Extractor Signals
    // ========================================================================
    reg                      fuzzy_start;
    reg                      fuzzy_mode;   // 0=enroll, 1=reconstruct
    wire                     fuzzy_done;
    wire                     fuzzy_error;
    wire [SECRET_BITS-1:0]   fuzzy_secret;
    wire [HELPER_BITS-1:0]   fuzzy_helper;
    reg  [SECRET_BITS-1:0]   latched_secret;

    // ========================================================================
    // Key Generator (SHA-256) Signals
    // ========================================================================
    reg        keygen_start;
    wire       keygen_done;
    wire [255:0] keygen_key;

    // ========================================================================
    // LFSR Signals  -- key expansion stage AFTER SHA-256
    // Seeded with the 256-bit SHA-256 output; run 256 cycles; output is
    // the final cryptographic key.
    // ========================================================================
    reg  [255:0] lfsr_seed;
    reg          lfsr_load;
    reg          lfsr_enable;
    wire [255:0] lfsr_out;
    wire         lfsr_bit;
    reg  [8:0]   lfsr_cycle_count;

    // ========================================================================
    // Enrollment Tracking
    // ========================================================================
    reg [3:0]    powerup_count;
    reg [3:0]    stability_count [0:N-1];
    reg [N-1:0]  majority_value;
    reg [N-1:0]  stable_mask;
    reg [N-1:0]  powerup_history [0:ENROLL_CYCLES-1];
    reg [9:0]    stable_count_temp;
    reg [3:0]    ones_count;

    integer i, j;

    // ========================================================================
    // Module Instantiations
    // ========================================================================

    // SRAM PUF Core
    sram_puf_core #(.N(N)) puf_core_inst (
        .clk            (clk),
        .rst            (puf_rst),
        .enable_noise   (1'b1),
        .temp_factor    (8'd128),
        .voltage_factor (8'd128),
        .read_enable    (puf_read_enable),
        .read_done      (puf_read_done),
        .puf_response   (puf_response),
        .puf_bit        (puf_bit),
        .meta_flags     (meta_flags)
    );

    // Fuzzy Extractor (BCH error correction)
    fuzzy_extractor #(
        .PUF_BITS    (N),
        .SECRET_BITS (SECRET_BITS),
        .USE_BCH     (USE_BCH),
        .HELPER_BITS (HELPER_BITS)
    ) fuzzy_inst (
        .clk        (clk),
        .rst        (rst),
        .mode       (fuzzy_mode),
        .start      (fuzzy_start),
        .puf_in     (puf_response),
        .meta_mask  (meta_flags),
        .helper_in  (helper_data_in),
        .secret_out (fuzzy_secret),
        .helper_out (fuzzy_helper),
        .error_flag (fuzzy_error),
        .done       (fuzzy_done)
    );

    // SHA-256 Key Generator
    key_gen #(.SECRET_BITS(SECRET_BITS)) keygen_inst (
        .clk       (clk),
        .rst       (rst),
        .start     (keygen_start),
        .secret_in (latched_secret),
        .key_out   (keygen_key),
        .done      (keygen_done)
    );

    // 256-bit Galois LFSR -- key expansion (comes AFTER SHA-256)
    lfsr_256 #(.WIDTH(256)) lfsr_inst (
        .clk      (clk),
        .rst      (rst),
        .seed     (lfsr_seed),
        .load     (lfsr_load),
        .enable   (lfsr_enable),
        .lfsr_out (lfsr_out),
        .lfsr_bit (lfsr_bit)
    );

    // ========================================================================
    // Main FSM
    // ========================================================================
    always @(posedge clk) begin
        if (rst) begin
            state            <= `STATE_IDLE;
            operation_done   <= 1'b0;
            error_flag       <= 1'b0;
            puf_rst          <= 1'b0;
            puf_read_enable  <= 1'b0;
            fuzzy_start      <= 1'b0;
            keygen_start     <= 1'b0;
            lfsr_load        <= 1'b0;
            lfsr_enable      <= 1'b0;
            lfsr_cycle_count <= 0;
            powerup_count    <= 0;
            key_out          <= 256'b0;
            helper_data_out  <= {HELPER_BITS{1'b0}};
            latched_secret   <= {SECRET_BITS{1'b0}};
            lfsr_seed        <= 256'b0;
        end
        else begin
            case (state)

                // ------------------------------------------------------------
                // IDLE
                // ------------------------------------------------------------
                `STATE_IDLE: begin
                    operation_done <= 1'b0;
                    error_flag     <= 1'b0;
                    if (start_enroll) begin
                        powerup_count <= 0;
                        for (i = 0; i < N; i = i + 1)
                            stability_count[i] <= 0;
                        state <= `STATE_ENROLL_POWERUP;
                    end
                    else if (start_reconstruct) begin
                        state <= `STATE_RECONSTRUCT_POWERUP;
                    end
                end

                // ============================================================
                // ENROLLMENT PHASE
                // ============================================================

                `STATE_ENROLL_POWERUP: begin
                    if (powerup_count < ENROLL_CYCLES) begin
                        puf_rst        <= 1'b1;
                        puf_read_enable <= 1'b1;
                        state          <= `STATE_ENROLL_WAIT_READ;
                    end
                    else begin
                        state <= `STATE_ENROLL_ANALYZE;
                    end
                end

                `STATE_ENROLL_WAIT_READ: begin
                    puf_rst <= 1'b0;
                    if (puf_read_done) begin
                        powerup_history[powerup_count] <= puf_response;
                        powerup_count  <= powerup_count + 1;
                        puf_read_enable <= 1'b0;
                        state          <= `STATE_ENROLL_POWERUP;
                    end
                end

                `STATE_ENROLL_ANALYZE: begin
                    for (i = 0; i < N; i = i + 1) begin
                        ones_count = 0;
                        for (j = 0; j < ENROLL_CYCLES; j = j + 1)
                            if (powerup_history[j][i]) ones_count = ones_count + 1;

                        majority_value[i] = (ones_count > (ENROLL_CYCLES / 2)) ? 1'b1 : 1'b0;

                        stability_count[i] = 0;
                        for (j = 0; j < ENROLL_CYCLES; j = j + 1)
                            if (powerup_history[j][i] == majority_value[i])
                                stability_count[i] = stability_count[i] + 1;
                    end
                    state <= `STATE_ENROLL_SELECT;
                end

                `STATE_ENROLL_SELECT: begin
                    stable_count_temp = 0;
                    for (i = 0; i < N; i = i + 1) begin
                        stable_mask[i] = (stability_count[i] >= STABILITY_THRESHOLD &&
                                          !meta_flags[i]) ? 1'b1 : 1'b0;
                        if (stable_mask[i]) stable_count_temp = stable_count_temp + 1;
                    end

                    if (stable_count_temp < SECRET_BITS) begin
                        error_flag <= 1'b1;
                        state      <= `STATE_ERROR;
                    end
                    else begin
                        state <= `STATE_ENROLL_EXTRACT;
                    end
                end

                `STATE_ENROLL_EXTRACT: begin
                    fuzzy_mode <= 1'b0;  // enrollment
                    if (!fuzzy_done) begin
                        fuzzy_start <= 1'b1;
                    end
                    else begin
                        fuzzy_start <= 1'b0;
                        if (fuzzy_error) begin
                            error_flag <= 1'b1;
                            state      <= `STATE_ERROR;
                        end
                        else begin
                            helper_data_out <= fuzzy_helper;
                            latched_secret  <= fuzzy_secret;
                            state           <= `STATE_KEYGEN;
                        end
                    end
                end

                // ============================================================
                // RECONSTRUCTION PHASE
                // ============================================================

                `STATE_RECONSTRUCT_POWERUP: begin
                    puf_rst        <= 1'b1;
                    puf_read_enable <= 1'b1;
                    state          <= `STATE_RECONSTRUCT_READ;
                end

                `STATE_RECONSTRUCT_READ: begin
                    puf_rst <= 1'b0;
                    if (puf_read_done) begin
                        puf_read_enable <= 1'b0;
                        state           <= `STATE_RECONSTRUCT_DECODE;
                    end
                end

                `STATE_RECONSTRUCT_DECODE: begin
                    fuzzy_mode <= 1'b1;  // reconstruction
                    if (!fuzzy_done) begin
                        fuzzy_start <= 1'b1;
                    end
                    else begin
                        fuzzy_start <= 1'b0;
                        if (fuzzy_error) begin
                            error_flag <= 1'b1;
                            state      <= `STATE_ERROR;
                        end
                        else begin
                            latched_secret <= fuzzy_secret;
                            state          <= `STATE_KEYGEN;
                        end
                    end
                end

                // ============================================================
                // SHA-256 KEY GENERATION  (common to both phases)
                // ============================================================

                `STATE_KEYGEN: begin
                    if (!keygen_done) begin
                        keygen_start <= 1'b1;
                    end
                    else begin
                        keygen_start  <= 1'b0;
                        // Seed LFSR with the SHA-256 output for key expansion
                        lfsr_seed        <= keygen_key;
                        lfsr_load        <= 1'b1;
                        lfsr_cycle_count <= 0;
                        state            <= `STATE_LFSR;
                    end
                end

                // ============================================================
                // LFSR KEY EXPANSION  (256-bit Galois LFSR, 256 cycles)
                // ============================================================

                `STATE_LFSR: begin
                    lfsr_load <= 1'b0;
                    if (lfsr_cycle_count < 256) begin
                        lfsr_enable      <= 1'b1;
                        lfsr_cycle_count <= lfsr_cycle_count + 1;
                    end
                    else begin
                        lfsr_enable <= 1'b0;
                        key_out     <= lfsr_out;   // Final expanded key
                        state       <= `STATE_DONE;
                    end
                end

                // ============================================================
                // DONE / ERROR
                // ============================================================

                `STATE_DONE: begin
                    operation_done <= 1'b1;
                    if (!start_enroll && !start_reconstruct)
                        state <= `STATE_IDLE;
                end

                `STATE_ERROR: begin
                    operation_done <= 1'b1;
                    error_flag     <= 1'b1;
                    if (!start_enroll && !start_reconstruct)
                        state <= `STATE_IDLE;
                end

                default: state <= `STATE_IDLE;

            endcase
        end
    end

endmodule