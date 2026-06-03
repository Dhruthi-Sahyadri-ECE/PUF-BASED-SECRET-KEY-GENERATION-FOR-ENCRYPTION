`timescale 1ns / 1ps
// ============================================================================
// SRAM PUF Core Module
// 
// Implements an SRAM array with realistic PUF behavior including:
// - Per-cell bias (manufacturing variation)
// - Per-read noise injection
// - Metastability detection
// - Environmental variation (temperature/voltage)
// - Serial and parallel readout modes
//
// Feature: advanced-sram-puf
// ============================================================================

`include "sram_puf_params.vh"

module sram_puf_core #(
    parameter N = `DEFAULT_PUF_SIZE,           // Number of SRAM cells
    parameter BIAS_WIDTH = `DEFAULT_BIAS_WIDTH, // Bit width for bias values
    parameter NOISE_PROB = `DEFAULT_NOISE_PROB, // Default noise probability
    parameter META_THRESHOLD = `DEFAULT_META_THRESHOLD // Metastability threshold
)(
    input  wire clk,
    input  wire rst,                    // Power-up reset (active high)
    input  wire enable_noise,           // Enable noise injection
    input  wire [7:0] temp_factor,      // Temperature scaling (128=nominal)
    input  wire [7:0] voltage_factor,   // Voltage scaling (128=nominal)
    input  wire read_enable,            // Start PUF readout
    output reg  read_done,              // Readout complete
    output reg  [N-1:0] puf_response,   // Parallel PUF output
    output reg  puf_bit,                // Serial PUF output
    output reg  [N-1:0] meta_flags      // Metastability flags (1=unstable)
);

    // ========================================================================
    // Internal Signals
    // ========================================================================
    
    // SRAM cell array
    reg [N-1:0] sram_cells;
    
    // Bias values for each cell (deterministic, based on cell index)
    reg [BIAS_WIDTH-1:0] cell_bias [0:N-1];
    
    // Settling time for metastability detection
    reg [3:0] settling_time [0:N-1];
    
    // Read index for serial output
    reg [$clog2(N):0] read_index;
    
    // Noise generation using PUF cells
    reg [N-1:0] noise_source;
    reg [7:0] noise_counter;
    
    // Noise calculation variables
    reg [15:0] effective_noise;
    reg [7:0] noise_threshold;
    reg noise_bit;
    
    // ========================================================================
    // Bias Generation Function
    // Deterministic but varied bias based on cell index
    // Simulates manufacturing variation
    // ========================================================================
    
    function [BIAS_WIDTH-1:0] compute_bias;
        input integer index;
        reg [31:0] temp;
        begin
            // Pseudo-random but deterministic function
            temp = (index * 214013 + 2531011);
            temp = temp ^ (temp >> 16);
            temp = temp * 1103515245 + 12345;
            compute_bias = temp[BIAS_WIDTH-1:0];
        end
    endfunction
    
    // ========================================================================
    // Power-Up Initialization
    // Each cell initializes based on its bias with probabilistic behavior
    // ========================================================================
    
    integer i;
    
    always @(posedge rst) begin
        // Initialize bias values (deterministic per cell)
        for (i = 0; i < N; i = i + 1) begin
            cell_bias[i] <= compute_bias(i);
        end
        
        // Power-up: each cell settles based on bias with some randomness
        for (i = 0; i < N; i = i + 1) begin
            // Use bias to determine power-up state with probabilistic behavior
            // Higher bias -> more likely to be '1'
            // Add small random variation to simulate real PUF behavior
            if (cell_bias[i] > 8'h80 + ($urandom % 16) - 8) begin
                sram_cells[i] <= 1'b1;
            end else begin
                sram_cells[i] <= 1'b0;
            end
            
            // Simulate settling time for metastability
            // Cells near threshold (bias ~0.5) take longer to settle
            if ((cell_bias[i] > 8'h70) && (cell_bias[i] < 8'h90)) begin
                settling_time[i] <= META_THRESHOLD + 2; // Metastable
            end else begin
                settling_time[i] <= $urandom % META_THRESHOLD; // Stable
            end
        end
        
        // Generate metastability flags
        for (i = 0; i < N; i = i + 1) begin
            meta_flags[i] <= (settling_time[i] > META_THRESHOLD);
        end
        
        // Initialize noise source from PUF cells with randomization
        noise_source <= sram_cells ^ $urandom;
        noise_counter <= $urandom % 256;
    end
    
    // ========================================================================
    // Readout Logic with Noise Injection
    // ========================================================================
    
    always @(posedge clk) begin
        if (rst) begin
            read_index <= 0;
            read_done <= 0;
            puf_response <= {N{1'b0}};
            puf_bit <= 1'b0;
        end
        else if (read_enable && !read_done) begin
            // Read current cell
            puf_bit <= sram_cells[read_index];
            
            // Apply noise if enabled
            if (enable_noise) begin
                // Calculate effective noise probability based on environmental factors
                
                // Environmental factors increase noise
                // nominal = 128, higher values = more stress = more noise
                effective_noise = NOISE_PROB * temp_factor * voltage_factor;
                effective_noise = effective_noise >> 14; // Scale back down
                
                if (effective_noise > 255) begin
                    noise_threshold = 8'hFF;
                end else begin
                    noise_threshold = effective_noise[7:0];
                end
                
                // Use PUF cells as entropy source for noise
                // Rotate through noise_source bits
                noise_bit = noise_source[noise_counter];
                noise_counter = noise_counter + 1;
                
                // Apply noise: flip bit if noise_bit and within threshold
                if (noise_bit && (noise_counter < noise_threshold)) begin
                    puf_bit <= ~sram_cells[read_index];
                    puf_response[read_index] <= ~sram_cells[read_index];
                end else begin
                    puf_response[read_index] <= sram_cells[read_index];
                end
            end else begin
                // No noise: return exact power-up state
                puf_response[read_index] <= sram_cells[read_index];
            end
            
            // Advance to next cell
            if (read_index == N-1) begin
                read_done <= 1;
            end else begin
                read_index <= read_index + 1;
            end
        end
        else if (!read_enable) begin
            // Reset for next readout
            read_index <= 0;
            read_done <= 0;
        end
    end

endmodule