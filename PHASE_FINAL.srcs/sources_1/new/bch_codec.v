`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11.04.2026 12:01:39
// Design Name: 
// Module Name: bch_codec
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
// BCH(31,16,3) Codec Module
//
// Proper BCH code over GF(2^5) with:
//   n = 31  (codeword length)
//   k = 16  (message length)
//   t = 3   (error-correction capability)
//   n-k = 15 parity bits
//
// Generator polynomial g(x) = LCM(m1, m3, m5) over GF(2^5)
//   m1(x) = x^5 + x^2 + 1
//   m3(x) = x^5 + x^4 + x^3 + x^2 + 1
//   m5(x) = x^5 + x^4 + x^2 + x + 1
//   g(x)  = x^15 + x^11 + x^10 + x^9 + x^8 + x^7 + x^5 + x^3 + x^2 + x + 1
//         = 1000_1111_1010_1111 (MSB first, degree-15 to degree-0)
//
// Encoder: Systematic polynomial division
// Decoder: Syndrome computation + Berlekamp-Massey + Chien search
//
// Feature: advanced-sram-puf
// ============================================================================

module bch_codec #(
    parameter M = 5,        // GF(2^5)
    parameter T = 3,        // Correct up to 3 errors
    parameter N = 31,       // Codeword length
    parameter K = 16        // Message length
)(
    input  wire clk,
    input  wire rst,
    input  wire encode,                 // 1=encode, 0=decode
    input  wire start,                  // Start operation
    input  wire [K-1:0] data_in,        // Message bits (encoding)
    input  wire [N-1:0] code_in,        // Received codeword (decoding)
    output reg  [N-1:0] code_out,       // Encoded codeword
    output reg  [K-1:0] data_out,       // Decoded message
    output reg  error_flag,             // Uncorrectable error detected
    output reg  done                    // Operation complete
);

    // ========================================================================
    // Generator Polynomial: g(x) = x^15 + x^11 + x^10 + x^9 + x^8 +
    //                               x^7 + x^5 + x^3 + x^2 + x + 1
    // Binary (degree 15 down to 0): 1_000_1111_1010_1111
    // As [15:0] = 16'b1000_1111_1010_1111 = 16'h8FAF
    // ========================================================================

    localparam [15:0] GEN_POLY = 16'h8FAF;  // x^15+x^11+x^10+x^9+x^8+x^7+x^5+x^3+x^2+x+1

    // ========================================================================
    // GF(2^5) Arithmetic
    // Primitive polynomial: p(x) = x^5 + x^2 + 1  (binary 100101 = 6'h25)
    // Alpha = primitive element (root of p(x)), alpha = 0x02 in our representation
    // ========================================================================

    localparam PRIM_POLY = 6'h25;  // x^5 + x^2 + 1

    // GF(2^5) elements: alpha^i for i = 0..30
    // Stored as 5-bit values. alpha^0 = 1.
    reg [M-1:0] alpha_to [0:N-1]; // alpha_to[i] = alpha^i
    reg [M-1:0] index_of [0:N];   // index_of[x] = i such that alpha^i = x; index_of[0] = 31 (invalid)

    // ========================================================================
    // GF(2^5) Lookup Table Initialization
    // ========================================================================

    integer ii;
    reg [M:0] tmp_gf;

    initial begin
        alpha_to[0] = 5'd1;  // alpha^0 = 1
        for (ii = 1; ii < N; ii = ii + 1) begin
            tmp_gf = {1'b0, alpha_to[ii-1]} << 1;  // multiply by alpha
            if (tmp_gf[M])
                alpha_to[ii] = tmp_gf[M-1:0] ^ PRIM_POLY[M-1:0];
            else
                alpha_to[ii] = tmp_gf[M-1:0];
        end

        // Build index_of (log table)
        index_of[0] = N;  // log(0) is undefined, use N as sentinel
        for (ii = 0; ii < N; ii = ii + 1) begin
            index_of[alpha_to[ii]] = ii;
        end
    end

    // ========================================================================
    // GF(2^5) Multiply Function
    // ========================================================================

    function [M-1:0] gf_mult;
        input [M-1:0] a, b;
        reg [2*M-1:0] result;  // 10-bit intermediate for product before reduction
        integer k;
        begin
            result = {(2*M){1'b0}};
            for (k = 0; k < M; k = k + 1) begin
                if (b[k])
                    result = result ^ ({{M{1'b0}}, a} << k);
            end
            // Modular reduction using x^5 = x^2 + 1  (primitive poly x^5+x^2+1)
            // For each overflow bit n (8 down to 5):
            //   x^n = x^(n-5) * x^5 = x^(n-5) * (x^2+1) = x^(n-3) + x^(n-5)
            // Process from MSB to LSB to ensure cascading reductions
            if (result[8]) begin result[8] = 1'b0; result[5] = result[5] ^ 1'b1; result[3] = result[3] ^ 1'b1; end
            if (result[7]) begin result[7] = 1'b0; result[4] = result[4] ^ 1'b1; result[2] = result[2] ^ 1'b1; end
            if (result[6]) begin result[6] = 1'b0; result[3] = result[3] ^ 1'b1; result[1] = result[1] ^ 1'b1; end
            if (result[5]) begin result[5] = 1'b0; result[2] = result[2] ^ 1'b1; result[0] = result[0] ^ 1'b1; end
            gf_mult = result[M-1:0];
        end
    endfunction

    // ========================================================================
    // Internal State Machine
    // ========================================================================

    reg [3:0] state;
    localparam IDLE          = 4'd0;
    localparam ENCODE_OP     = 4'd1;
    localparam SYNDROME_CALC = 4'd2;
    localparam BM_INIT       = 4'd3;
    localparam BM_ITER       = 4'd4;
    localparam CHIEN_SEARCH  = 4'd5;
    localparam CORRECT_ERRS  = 4'd6;
    localparam DONE_STATE    = 4'd7;

    // ========================================================================
    // Encoding Registers
    // ========================================================================

    reg [N-1:0] enc_shift_reg;
    reg [4:0] enc_bit_idx;

    // ========================================================================
    // Decoding Registers
    // ========================================================================

    // Syndromes: S[1], S[2], S[3], S[4], S[5], S[6]  (2*T = 6 syndromes)
    reg [M-1:0] S [1:2*T];

    // Berlekamp-Massey registers
    reg [M-1:0] sigma  [0:T];   // Error-locator polynomial coefficients
    reg [M-1:0] prev_sigma [0:T]; // Previous sigma
    reg [M-1:0] delta;           // Discrepancy
    reg [M-1:0] B [0:T];        // Correction polynomial
    reg [4:0] bm_L;             // Current error count estimate
    reg [4:0] bm_step;          // BM iteration counter (1..2T)
    reg [4:0] chien_idx;        // Chien search position counter

    // Error locations and correction
    reg [4:0] err_loc [0:T-1];  // Error locations found
    reg [2:0] err_count;        // Number of errors found
    reg [N-1:0] corrected;      // Corrected codeword

    // Working variables
    reg [M-1:0] disc;           // Discrepancy value in BM
    reg [4:0] bm_m;             // m parameter in BM

    integer i, j;

    // ========================================================================
    // Main Sequential Logic
    // ========================================================================

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            done <= 1'b0;
            error_flag <= 1'b0;
            code_out <= {N{1'b0}};
            data_out <= {K{1'b0}};
            err_count <= 0;
        end
        else begin
            case (state)

                // ============================================================
                // IDLE: Wait for start
                // ============================================================
                IDLE: begin
                    done <= 1'b0;
                    error_flag <= 1'b0;
                    err_count <= 0;

                    if (start) begin
                        if (encode) begin
                            state <= ENCODE_OP;
                        end
                        else begin
                            corrected <= code_in;
                            state <= SYNDROME_CALC;
                        end
                    end
                end

                // ============================================================
                // ENCODING: Systematic BCH encoding via polynomial division
                // codeword = [data(K bits) | parity(N-K bits)]
                // ============================================================
                ENCODE_OP: begin
                    begin : encode_block
                        reg [N-1:0] msg_poly;
                        reg [14:0] remainder;  // N-K = 15 bits

                        // Place message in high-order K bits
                        msg_poly = {data_in, {(N-K){1'b0}}};
                        remainder = 15'b0;

                        // Polynomial long division: divide msg_poly by GEN_POLY
                        for (i = N-1; i >= 0; i = i - 1) begin
                            if (remainder[14]) begin
                                remainder = {remainder[13:0], msg_poly[i]} ^ GEN_POLY[14:0];
                            end else begin
                                remainder = {remainder[13:0], msg_poly[i]};
                            end
                        end

                        // Systematic codeword: [data | parity]
                        code_out <= {data_in, remainder};
                    end

                    done <= 1'b1;
                    state <= DONE_STATE;
                end

                // ============================================================
                // SYNDROME CALCULATION: Evaluate received poly at alpha^1..alpha^6
                // S_j = r(alpha^j) for j = 1..2T
                // ============================================================
                SYNDROME_CALC: begin
                    begin : synd_block
                        reg [M-1:0] syn_val;
                        reg [M-1:0] alpha_j;   // alpha^j
                        reg [M-1:0] alpha_ji;   // alpha^(j*i)
                        integer sj, si;
                        reg all_zero;

                        all_zero = 1'b1;

                        for (sj = 1; sj <= 2*T; sj = sj + 1) begin
                            syn_val = {M{1'b0}};
                            for (si = 0; si < N; si = si + 1) begin
                                if (code_in[si]) begin
                                    // Add alpha^(sj * si) mod 31
                                    syn_val = syn_val ^ alpha_to[(sj * si) % N];
                                end
                            end
                            S[sj] = syn_val;
                            if (syn_val != {M{1'b0}})
                                all_zero = 1'b0;
                        end

                        if (all_zero) begin
                            // No errors detected
                            data_out <= code_in[N-1:N-K];
                            done <= 1'b1;
                            state <= DONE_STATE;
                        end
                        else begin
                            state <= BM_INIT;
                        end
                    end
                end

                // ============================================================
                // BERLEKAMP-MASSEY: Initialize
                // ============================================================
                BM_INIT: begin
                    // Initialize sigma(x) = 1, B(x) = 1
                    for (i = 0; i <= T; i = i + 1) begin
                        sigma[i] <= {M{1'b0}};
                        B[i] <= {M{1'b0}};
                    end
                    sigma[0] <= 5'd1;
                    B[0] <= 5'd1;
                    bm_L <= 0;
                    bm_step <= 1;
                    bm_m <= 1;
                    state <= BM_ITER;
                end

                // ============================================================
                // BERLEKAMP-MASSEY: Iterative step
                // ============================================================
                BM_ITER: begin
                    if (bm_step <= 2*T) begin
                        begin : bm_block
                            reg [M-1:0] d_val;
                            reg [M-1:0] d_inv;
                            reg [M-1:0] new_sigma [0:T];
                            reg [M-1:0] new_B [0:T];
                            integer bi;

                            // Compute discrepancy: d = S[bm_step] + sum(sigma[i]*S[bm_step-i])
                            d_val = S[bm_step];
                            for (bi = 1; bi <= T; bi = bi + 1) begin
                                if (bi <= bm_L && (bm_step - bi) >= 1) begin
                                    d_val = d_val ^ gf_mult(sigma[bi], S[bm_step - bi]);
                                end
                            end

                            if (d_val == {M{1'b0}}) begin
                                // d = 0: no update to sigma, just shift B
                                for (bi = T; bi >= 1; bi = bi - 1)
                                    B[bi] <= B[bi-1];
                                B[0] <= {M{1'b0}};
                                bm_m <= bm_m + 1;
                            end
                            else begin
                                // d != 0: update sigma
                                // new_sigma(x) = sigma(x) - d * x * B(x)
                                // But we need d * B[i] for each i, shifted by 1
                                for (bi = 0; bi <= T; bi = bi + 1)
                                    new_sigma[bi] = sigma[bi];
                                for (bi = 1; bi <= T; bi = bi + 1)
                                    new_sigma[bi] = sigma[bi] ^ gf_mult(d_val, B[bi-1]);

                                if (2 * bm_L <= bm_step - 1) begin
                                    // Update L and B
                                    // B(x) = sigma(x) / d  (multiply by d_inv)
                                    // d_inv = alpha^(31 - index_of[d])
                                    d_inv = alpha_to[(N - index_of[d_val]) % N];
                                    for (bi = 0; bi <= T; bi = bi + 1)
                                        B[bi] <= gf_mult(sigma[bi], d_inv);
                                    bm_L <= bm_step - bm_L;
                                end
                                else begin
                                    // Just shift B
                                    for (bi = T; bi >= 1; bi = bi - 1)
                                        B[bi] <= B[bi-1];
                                    B[0] <= {M{1'b0}};
                                end

                                for (bi = 0; bi <= T; bi = bi + 1)
                                    sigma[bi] <= new_sigma[bi];
                            end

                            bm_step <= bm_step + 1;
                        end
                    end
                    else begin
                        // BM complete; check degree of sigma
                        if (bm_L > T) begin
                            // Too many errors to correct
                            error_flag <= 1'b1;
                            data_out <= code_in[N-1:N-K];
                            done <= 1'b1;
                            state <= DONE_STATE;
                        end
                        else begin
                            chien_idx <= 0;
                            err_count <= 0;
                            state <= CHIEN_SEARCH;
                        end
                    end
                end

                // ============================================================
                // CHIEN SEARCH: Evaluate sigma(x) at x = alpha^(-i) for i=0..30
                // If sigma(alpha^(-i)) = 0, then position i is an error
                // ============================================================
                CHIEN_SEARCH: begin
                    if (chien_idx < N) begin
                        begin : chien_block
                            reg [M-1:0] eval;
                            reg [M-1:0] alpha_neg_i;
                            reg [M-1:0] power;
                            integer ci;

                            // alpha^(-chien_idx) = alpha^(31 - chien_idx) mod 31
                            // But alpha^0 = 1, alpha^(-i) = alpha^(N-i)

                            eval = sigma[0];  // sigma_0 = 1 always
                            for (ci = 1; ci <= T; ci = ci + 1) begin
                                if (sigma[ci] != {M{1'b0}}) begin
                                    // sigma[ci] * alpha^(-ci * chien_idx)
                                    // = sigma[ci] * alpha^((N - ci*chien_idx % N) % N)
                                    power = alpha_to[((N - ((ci * chien_idx) % N)) % N)];
                                    eval = eval ^ gf_mult(sigma[ci], power);
                                end
                            end

                            if (eval == {M{1'b0}}) begin
                                // Found error at position chien_idx
                                if (err_count < T) begin
                                    err_loc[err_count] <= chien_idx;
                                    err_count <= err_count + 1;
                                end
                            end
                        end
                        chien_idx <= chien_idx + 1;
                    end
                    else begin
                        // Verify we found exactly bm_L errors
                        if (err_count != bm_L[2:0]) begin
                            error_flag <= 1'b1;
                            data_out <= code_in[N-1:N-K];
                            done <= 1'b1;
                            state <= DONE_STATE;
                        end
                        else begin
                            state <= CORRECT_ERRS;
                        end
                    end
                end

                // ============================================================
                // ERROR CORRECTION: Flip error bits
                // ============================================================
                CORRECT_ERRS: begin
                    begin : correct_block
                        reg [N-1:0] corr;
                        integer ei;

                        corr = code_in;
                        for (ei = 0; ei < T; ei = ei + 1) begin
                            if (ei < err_count)
                                corr[err_loc[ei]] = ~corr[err_loc[ei]];
                        end

                        corrected <= corr;
                        data_out <= corr[N-1:N-K];
                    end

                    done <= 1'b1;
                    state <= DONE_STATE;
                end

                // ============================================================
                // DONE: Hold outputs until start deasserted
                // ============================================================
                DONE_STATE: begin
                    if (!start) begin
                        done <= 1'b0;
                        error_flag <= 1'b0;
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule