// ============================================================================
// SRAM-PUF System Parameters
// Common parameters and definitions for the Advanced SRAM-PUF system
// ============================================================================

`ifndef SRAM_PUF_PARAMS_VH
`define SRAM_PUF_PARAMS_VH

// Default PUF Configuration
`define DEFAULT_PUF_SIZE        256
`define DEFAULT_BIAS_WIDTH      8
`define DEFAULT_NOISE_PROB      8'h0A    // ~4% noise (10/256)
`define DEFAULT_META_THRESHOLD  10       // cycles
`define DEFAULT_ENROLL_CYCLES   10
`define DEFAULT_STABILITY_THRESH 8       // out of 10

// Error Correction Codes
`define USE_HAMMING             0
`define USE_BCH                 1

// Hamming(7,4) Parameters
`define HAMMING_N               7
`define HAMMING_K               4

// BCH Default Parameters (31,16,3)
`define BCH_M                   5
`define BCH_T                   3
`define BCH_N                   31
`define BCH_K                   16

// SHA-256 Parameters
`define SHA256_DIGEST_WIDTH     256
`define SHA256_BLOCK_WIDTH      512

// FSM States for Controller
`define STATE_IDLE              4'd0
`define STATE_ENROLL_POWERUP    4'd1
`define STATE_ENROLL_WAIT_READ  4'd2
`define STATE_ENROLL_ANALYZE    4'd3
`define STATE_ENROLL_SELECT     4'd4
`define STATE_ENROLL_EXTRACT    4'd5
`define STATE_RECONSTRUCT_POWERUP 4'd6
`define STATE_RECONSTRUCT_READ  4'd7
`define STATE_RECONSTRUCT_DECODE 4'd8
`define STATE_KEYGEN            4'd9
`define STATE_DONE              4'd10
`define STATE_ERROR             4'd11
`define STATE_LFSR              4'd12

`endif // SRAM_PUF_PARAMS_VH