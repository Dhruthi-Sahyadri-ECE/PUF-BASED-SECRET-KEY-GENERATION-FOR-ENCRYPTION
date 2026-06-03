`timescale 1ns / 1ps
// ============================================================================
// Key Generator Module
// 
// Wrapper for SHA-256 that handles padding and formatting
// Converts recovered secret bits into 256-bit cryptographic key
//
// Feature: advanced-sram-puf
// ============================================================================

`include "sram_puf_params.vh"

module key_gen #(
    parameter SECRET_BITS = 128
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire [SECRET_BITS-1:0] secret_in,
    output reg  [255:0] key_out,
    output reg  done
);

    // ========================================================================
    // SHA-256 Padding
    // Message must be padded to 512-bit block
    // Format: message || 1 || 0...0 || length(64 bits)
    // ========================================================================
    
    reg [511:0] padded_message;
    reg [SECRET_BITS-1:0] latched_secret_in;  // Latch the input secret
    reg sha_start;
    wire [255:0] sha_hash;
    wire sha_done;
    
    // Instantiate SHA-256 core
    sha256_core sha256_inst (
        .clk(clk),
        .rst(rst),
        .start(sha_start),
        .message_block(padded_message),
        .hash_out(sha_hash),
        .done(sha_done)
    );
    
    // ========================================================================
    // Padding Logic
    // ========================================================================
    
    reg [1:0] state;
    localparam IDLE = 2'd0;
    localparam PAD = 2'd1;
    localparam HASH = 2'd2;
    localparam DONE_STATE = 2'd3;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            done <= 1'b0;
            sha_start <= 1'b0;
            key_out <= 256'b0;
            padded_message <= 512'b0;
            latched_secret_in <= {SECRET_BITS{1'b0}};
        end
        else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        // Latch the input secret when start is asserted
                        latched_secret_in <= secret_in;
                        state <= PAD;
                    end
                end
                
                PAD: begin
                    // Pad secret to 512 bits using the latched value
                    // Format: secret || 1 || zeros || length
                    padded_message <= {latched_secret_in, 
                                      1'b1, 
                                      {(512 - SECRET_BITS - 1 - 64){1'b0}}, 
                                      64'd0 + SECRET_BITS};
                    sha_start <= 1'b1;
                    state <= HASH;
                end
                
                HASH: begin
                    sha_start <= 1'b0;
                    if (sha_done) begin
                        key_out <= sha_hash;
                        done <= 1'b1;
                        state <= DONE_STATE;
                    end
                end
                
                DONE_STATE: begin
                    if (!start) begin
                        done <= 1'b0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule