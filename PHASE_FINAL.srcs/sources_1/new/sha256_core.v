`timescale 1ns / 1ps
// ============================================================================
// SHA-256 Core Module
// 
// Implements SHA-256 cryptographic hash function
// - 64-round compression function
// - 256-bit output
// - Processes 512-bit blocks
//
// Feature: advanced-sram-puf
// ============================================================================

module sha256_core (
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [511:0] message_block,  // 512-bit input block
    output reg  [255:0] hash_out,       // 256-bit hash output
    output reg  done
);

    // ========================================================================
    // SHA-256 Constants (first 32 bits of fractional parts of cube roots)
    // ========================================================================
    
    reg [31:0] K [0:63];
    
    initial begin
        K[0]  = 32'h428a2f98; K[1]  = 32'h71374491; K[2]  = 32'hb5c0fbcf; K[3]  = 32'he9b5dba5;
        K[4]  = 32'h3956c25b; K[5]  = 32'h59f111f1; K[6]  = 32'h923f82a4; K[7]  = 32'hab1c5ed5;
        K[8]  = 32'hd807aa98; K[9]  = 32'h12835b01; K[10] = 32'h243185be; K[11] = 32'h550c7dc3;
        K[12] = 32'h72be5d74; K[13] = 32'h80deb1fe; K[14] = 32'h9bdc06a7; K[15] = 32'hc19bf174;
        K[16] = 32'he49b69c1; K[17] = 32'hefbe4786; K[18] = 32'h0fc19dc6; K[19] = 32'h240ca1cc;
        K[20] = 32'h2de92c6f; K[21] = 32'h4a7484aa; K[22] = 32'h5cb0a9dc; K[23] = 32'h76f988da;
        K[24] = 32'h983e5152; K[25] = 32'ha831c66d; K[26] = 32'hb00327c8; K[27] = 32'hbf597fc7;
        K[28] = 32'hc6e00bf3; K[29] = 32'hd5a79147; K[30] = 32'h06ca6351; K[31] = 32'h14292967;
        K[32] = 32'h27b70a85; K[33] = 32'h2e1b2138; K[34] = 32'h4d2c6dfc; K[35] = 32'h53380d13;
        K[36] = 32'h650a7354; K[37] = 32'h766a0abb; K[38] = 32'h81c2c92e; K[39] = 32'h92722c85;
        K[40] = 32'ha2bfe8a1; K[41] = 32'ha81a664b; K[42] = 32'hc24b8b70; K[43] = 32'hc76c51a3;
        K[44] = 32'hd192e819; K[45] = 32'hd6990624; K[46] = 32'hf40e3585; K[47] = 32'h106aa070;
        K[48] = 32'h19a4c116; K[49] = 32'h1e376c08; K[50] = 32'h2748774c; K[51] = 32'h34b0bcb5;
        K[52] = 32'h391c0cb3; K[53] = 32'h4ed8aa4a; K[54] = 32'h5b9cca4f; K[55] = 32'h682e6ff3;
        K[56] = 32'h748f82ee; K[57] = 32'h78a5636f; K[58] = 32'h84c87814; K[59] = 32'h8cc70208;
        K[60] = 32'h90befffa; K[61] = 32'ha4506ceb; K[62] = 32'hbef9a3f7; K[63] = 32'hc67178f2;
    end
    
    // ========================================================================
    // Initial Hash Values (first 32 bits of fractional parts of square roots)
    // ========================================================================
    
    reg [31:0] H0, H1, H2, H3, H4, H5, H6, H7;
    
    initial begin
        H0 = 32'h6a09e667;
        H1 = 32'hbb67ae85;
        H2 = 32'h3c6ef372;
        H3 = 32'ha54ff53a;
        H4 = 32'h510e527f;
        H5 = 32'h9b05688c;
        H6 = 32'h1f83d9ab;
        H7 = 32'h5be0cd19;
    end
    
    // ========================================================================
    // Working Variables
    // ========================================================================
    
    reg [31:0] a, b, c, d, e, f, g, h;
    reg [31:0] W [0:63];
    reg [6:0] round;
    reg [2:0] state;
    
    localparam IDLE = 3'd0;
    localparam PREPARE = 3'd1;
    localparam COMPRESS = 3'd2;
    localparam FINALIZE = 3'd3;
    
    // ========================================================================
    // SHA-256 Functions
    // ========================================================================
    
    function [31:0] rotr;
        input [31:0] x;
        input [4:0] n;
        begin
            rotr = (x >> n) | (x << (32 - n));
        end
    endfunction
    
    function [31:0] Ch;
        input [31:0] x, y, z;
        begin
            Ch = (x & y) ^ (~x & z);
        end
    endfunction
    
    function [31:0] Maj;
        input [31:0] x, y, z;
        begin
            Maj = (x & y) ^ (x & z) ^ (y & z);
        end
    endfunction
    
    function [31:0] Sigma0;
        input [31:0] x;
        begin
            Sigma0 = rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
        end
    endfunction
    
    function [31:0] Sigma1;
        input [31:0] x;
        begin
            Sigma1 = rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
        end
    endfunction
    
    function [31:0] sigma0;
        input [31:0] x;
        begin
            sigma0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
        end
    endfunction
    
    function [31:0] sigma1;
        input [31:0] x;
        begin
            sigma1 = rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
        end
    endfunction
    
    // ========================================================================
    // Main SHA-256 Logic
    // ========================================================================
    
    integer i;
    reg [31:0] T1, T2;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            done <= 1'b0;
            round <= 0;
            hash_out <= 256'b0;
        end
        else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        // Reset H values to initial state for each new hash
                        H0 <= 32'h6a09e667;
                        H1 <= 32'hbb67ae85;
                        H2 <= 32'h3c6ef372;
                        H3 <= 32'ha54ff53a;
                        H4 <= 32'h510e527f;
                        H5 <= 32'h9b05688c;
                        H6 <= 32'h1f83d9ab;
                        H7 <= 32'h5be0cd19;
                        // Initialize working variables
                        a <= 32'h6a09e667; b <= 32'hbb67ae85; c <= 32'h3c6ef372; d <= 32'ha54ff53a;
                        e <= 32'h510e527f; f <= 32'h9b05688c; g <= 32'h1f83d9ab; h <= 32'h5be0cd19;
                        round <= 0;
                        state <= PREPARE;
                    end
                end
                
                PREPARE: begin
                    // Prepare message schedule
                    if (round < 16) begin
                        // First 16 words from message block
                        W[round] <= message_block[511 - round*32 -: 32];
                        round <= round + 1;
                    end
                    else if (round < 64) begin
                        // Extend to 64 words
                        W[round] <= sigma1(W[round-2]) + W[round-7] + 
                                    sigma0(W[round-15]) + W[round-16];
                        round <= round + 1;
                    end
                    else begin
                        round <= 0;
                        state <= COMPRESS;
                    end
                end
                
                COMPRESS: begin
                    // 64 rounds of compression
                    if (round < 64) begin
                        T1 = h + Sigma1(e) + Ch(e, f, g) + K[round] + W[round];
                        T2 = Sigma0(a) + Maj(a, b, c);
                        
                        h <= g;
                        g <= f;
                        f <= e;
                        e <= d + T1;
                        d <= c;
                        c <= b;
                        b <= a;
                        a <= T1 + T2;
                        
                        round <= round + 1;
                    end
                    else begin
                        state <= FINALIZE;
                    end
                end
                
                FINALIZE: begin
                    // Add compressed chunk to current hash value
                    H0 <= H0 + a;
                    H1 <= H1 + b;
                    H2 <= H2 + c;
                    H3 <= H3 + d;
                    H4 <= H4 + e;
                    H5 <= H5 + f;
                    H6 <= H6 + g;
                    H7 <= H7 + h;
                    
                    // Output final hash
                    hash_out <= {H0 + a, H1 + b, H2 + c, H3 + d, 
                                 H4 + e, H5 + f, H6 + g, H7 + h};
                    done <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule