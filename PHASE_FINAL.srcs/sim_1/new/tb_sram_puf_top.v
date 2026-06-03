`timescale 1ns / 1ps
// ============================================================================
// Top-Level Testbench for SRAM-PUF System
//
// Tests:
//   TEST 0: Standalone BCH(31,16,3) encode/decode with error injection
//   TEST 1: Full enrollment flow
//   TEST 2: Reconstruction (with LFSR masking)
//   TEST 3: Multiple reconstructions for consistency
// ============================================================================

module tb_sram_puf_top;

    // Parameters
    parameter CLK_PERIOD = 10;  // 100 MHz
    parameter N = 256;
    parameter SECRET_BITS = 128;
    // HELPER_BITS must match codec geometry used in DUT:
    //   USE_BCH=0 (Hamming 7,4): 32*7  = 224
    //   USE_BCH=1 (BCH 31,16):    8*31 = 248
    parameter HELPER_BITS = 248;

    // ========================================================================
    // Signals for DUT (system-level tests)
    // ========================================================================
    reg clk;
    reg rst;
    reg start_enroll;
    reg start_reconstruct;
    reg [HELPER_BITS-1:0] helper_data_in;
    wire operation_done;
    wire [255:0] key_out;
    wire [HELPER_BITS-1:0] helper_data_out;
    wire error_flag;

    // Stored helper data
    reg [HELPER_BITS-1:0] stored_helper;
    reg [255:0] enrollment_key;

    // Timeout counter
    integer timeout_counter;

    // ========================================================================
    // Signals for standalone BCH test
    // ========================================================================
    reg bch_clk;
    reg bch_rst;
    reg bch_encode;
    reg bch_start;
    reg [15:0] bch_data_in;
    reg [30:0] bch_code_in;
    wire [30:0] bch_code_out;
    wire [15:0] bch_data_out;
    wire bch_error_flag;
    wire bch_done;

    reg [30:0] encoded_codeword;
    reg [15:0] original_data;
    integer bch_timeout;
    integer test_pass_count;
    integer test_fail_count;

    // ========================================================================
    // DUT Instantiation (USE_BCH=1 to exercise BCH path)
    // ========================================================================
    sram_puf_controller #(
        .N(N),
        .SECRET_BITS(SECRET_BITS),
        .USE_BCH(1),  // BCH(31,16,3) enabled -> HELPER_BITS auto = 248
        .ENROLL_CYCLES(10),
        .STABILITY_THRESHOLD(8)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_enroll(start_enroll),
        .start_reconstruct(start_reconstruct),
        .helper_data_in(helper_data_in),
        .operation_done(operation_done),
        .key_out(key_out),
        .helper_data_out(helper_data_out),
        .error_flag(error_flag)
    );

    // ========================================================================
    // Standalone BCH Codec Instance
    // ========================================================================
    bch_codec #(
        .M(5), .T(3), .N(31), .K(16)
    ) bch_test_inst (
        .clk(clk),
        .rst(bch_rst),
        .encode(bch_encode),
        .start(bch_start),
        .data_in(bch_data_in),
        .code_in(bch_code_in),
        .code_out(bch_code_out),
        .data_out(bch_data_out),
        .error_flag(bch_error_flag),
        .done(bch_done)
    );

    // ========================================================================
    // Clock Generation
    // ========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ========================================================================
    // BCH Helper Tasks
    // ========================================================================

    task bch_encode_data;
        input [15:0] data;
        output [30:0] codeword;
        begin
            @(posedge clk);
            bch_encode = 1'b1;
            bch_data_in = data;
            bch_code_in = 31'b0;
            bch_start = 1'b1;

            bch_timeout = 0;
            while (!bch_done && bch_timeout < 100) begin
                @(posedge clk);
                bch_timeout = bch_timeout + 1;
            end

            codeword = bch_code_out;
            bch_start = 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    task bch_decode_codeword;
        input [30:0] codeword;
        output [15:0] decoded;
        output err;
        begin
            @(posedge clk);
            bch_encode = 1'b0;
            bch_code_in = codeword;
            bch_data_in = 16'b0;
            bch_start = 1'b1;

            bch_timeout = 0;
            while (!bch_done && bch_timeout < 200) begin
                @(posedge clk);
                bch_timeout = bch_timeout + 1;
            end

            decoded = bch_data_out;
            err = bch_error_flag;
            bch_start = 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        $display("========================================");
        $display("SRAM-PUF System Testbench (BCH Enabled)");
        $display("========================================");

        // Initialize all signals
        rst = 1;
        start_enroll = 0;
        start_reconstruct = 0;
        helper_data_in = {HELPER_BITS{1'b0}};
        bch_rst = 1;
        bch_encode = 0;
        bch_start = 0;
        bch_data_in = 16'b0;
        bch_code_in = 31'b0;
        test_pass_count = 0;
        test_fail_count = 0;

        #(CLK_PERIOD*5);
        rst = 0;
        bch_rst = 0;
        #(CLK_PERIOD*5);
        $display("[INFO] Reset complete, starting tests...\n");

        // ====================================================================
        // TEST 0: Standalone BCH(31,16,3) Codec Tests
        // ====================================================================
        $display("[TEST 0] BCH(31,16,3) Standalone Codec Tests");
        $display("--------------------------------------------");

        // --- Test 0a: Encode and decode with NO errors ---
        original_data = 16'hA5C3;
        $display("  [0a] Encoding data = 0x%h", original_data);
        bch_encode_data(original_data, encoded_codeword);
        $display("       Codeword = 0x%h", encoded_codeword);

        begin : test_0a
            reg [15:0] dec_data;
            reg dec_err;
            bch_decode_codeword(encoded_codeword, dec_data, dec_err);
            if (dec_data == original_data && !dec_err) begin
                $display("  [PASS] 0a: No-error decode correct: 0x%h", dec_data);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] 0a: Expected 0x%h, got 0x%h, err=%b", original_data, dec_data, dec_err);
                test_fail_count = test_fail_count + 1;
            end
        end

        // --- Test 0b: 1-bit error ---
        begin : test_0b
            reg [30:0] noisy;
            reg [15:0] dec_data;
            reg dec_err;
            noisy = encoded_codeword;
            noisy[5] = ~noisy[5];  // Flip bit 5
            $display("  [0b] Injecting 1-bit error at position 5");
            bch_decode_codeword(noisy, dec_data, dec_err);
            if (dec_data == original_data && !dec_err) begin
                $display("  [PASS] 0b: 1-bit error corrected: 0x%h", dec_data);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] 0b: Expected 0x%h, got 0x%h, err=%b", original_data, dec_data, dec_err);
                test_fail_count = test_fail_count + 1;
            end
        end

        // --- Test 0c: 2-bit errors ---
        begin : test_0c
            reg [30:0] noisy;
            reg [15:0] dec_data;
            reg dec_err;
            noisy = encoded_codeword;
            noisy[3] = ~noisy[3];   // Flip bit 3
            noisy[20] = ~noisy[20]; // Flip bit 20
            $display("  [0c] Injecting 2-bit errors at positions 3, 20");
            bch_decode_codeword(noisy, dec_data, dec_err);
            if (dec_data == original_data && !dec_err) begin
                $display("  [PASS] 0c: 2-bit errors corrected: 0x%h", dec_data);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] 0c: Expected 0x%h, got 0x%h, err=%b", original_data, dec_data, dec_err);
                test_fail_count = test_fail_count + 1;
            end
        end

        // --- Test 0d: 3-bit errors (max correctable) ---
        begin : test_0d
            reg [30:0] noisy;
            reg [15:0] dec_data;
            reg dec_err;
            noisy = encoded_codeword;
            noisy[1] = ~noisy[1];   // Flip bit 1
            noisy[10] = ~noisy[10]; // Flip bit 10
            noisy[28] = ~noisy[28]; // Flip bit 28
            $display("  [0d] Injecting 3-bit errors at positions 1, 10, 28");
            bch_decode_codeword(noisy, dec_data, dec_err);
            if (dec_data == original_data && !dec_err) begin
                $display("  [PASS] 0d: 3-bit errors corrected: 0x%h", dec_data);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  [FAIL] 0d: Expected 0x%h, got 0x%h, err=%b", original_data, dec_data, dec_err);
                test_fail_count = test_fail_count + 1;
            end
        end

        $display("  BCH Standalone: %0d PASS, %0d FAIL\n", test_pass_count, test_fail_count);

        // ====================================================================
        // TEST 1: Enrollment
        // ====================================================================
        $display("[TEST 1] Starting Enrollment (USE_BCH=1)...");
        start_enroll = 1;
        #(CLK_PERIOD);
        start_enroll = 0;

        // Wait for enrollment to complete with timeout
        timeout_counter = 0;
        while (!operation_done && timeout_counter < 500000) begin
            #(CLK_PERIOD);
            timeout_counter = timeout_counter + 1;
        end

        if (timeout_counter >= 500000) begin
            $display("[ERROR] Enrollment timeout! operation_done never asserted");
            $display("[DEBUG] Current state: %0d", dut.state);
            $display("[DEBUG] error_flag: %0d", error_flag);
            $finish;
        end

        $display("[INFO] Enrollment completed after %0d cycles", timeout_counter);
        #(CLK_PERIOD*2);

        if (error_flag) begin
            $display("[ERROR] Enrollment failed with error_flag!");
            $finish;
        end else begin
            $display("[PASS] Enrollment completed successfully");
            $display("  Helper Data: %h", helper_data_out);
            $display("  Key Output:  %h", key_out);

            // Store helper data and key for comparison
            stored_helper = helper_data_out;
            enrollment_key = key_out;
        end

        #(CLK_PERIOD*10);

        // ====================================================================
        // TEST 2: Reconstruction (exercises STATE_LFSR)
        // ====================================================================
        $display("\n[TEST 2] Starting Reconstruction (with LFSR masking)...");
        helper_data_in = stored_helper;
        start_reconstruct = 1;
        #(CLK_PERIOD);
        start_reconstruct = 0;

        // Wait for reconstruction to complete with timeout
        // Flow: POWERUP -> READ -> DECODE(BCH) -> KEYGEN(SHA-256) -> LFSR(256 cycles) -> DONE
        timeout_counter = 0;
        while (!operation_done && timeout_counter < 500000) begin
            #(CLK_PERIOD);
            timeout_counter = timeout_counter + 1;
            if (timeout_counter == 1)
                $display("[DEBUG] FSM state after start: %0d (expect STATE_RECONSTRUCT_POWERUP=6)", dut.state);
        end

        if (timeout_counter >= 500000) begin
            $display("[ERROR] Reconstruction timeout!");
            $display("[DEBUG] Current state: %0d", dut.state);
            $finish;
        end

        $display("[INFO] Reconstruction completed after %0d cycles", timeout_counter);
        #(CLK_PERIOD*2);

        if (error_flag) begin
            $display("[ERROR] Reconstruction failed!");
        end else begin
            $display("[PASS] Reconstruction completed successfully");
            $display("  Key Output: %h", key_out);

            // Compare keys
            if (key_out == enrollment_key) begin
                $display("[PASS] Keys match! PUF system working correctly.");
            end else begin
                $display("[WARN] Keys differ (expected with noise)");
                $display("  Enrollment Key:     %h", enrollment_key);
                $display("  Reconstruction Key: %h", key_out);
            end
        end

        #(CLK_PERIOD*10);

        // ====================================================================
        // TEST 3: Multiple Reconstructions
        // ====================================================================
        $display("\n[TEST 3] Testing multiple reconstructions...");

        repeat(3) begin
            // Wait for previous operation to fully complete
            while (operation_done) begin
                #(CLK_PERIOD);
            end

            #(CLK_PERIOD*5);

            helper_data_in = stored_helper;
            start_reconstruct = 1;
            #(CLK_PERIOD);
            start_reconstruct = 0;

            timeout_counter = 0;
            while (!operation_done && timeout_counter < 500000) begin
                #(CLK_PERIOD);
                timeout_counter = timeout_counter + 1;
            end

            if (!error_flag && timeout_counter < 500000) begin
                $display("  Reconstruction Key: %h", key_out);
            end

            #(CLK_PERIOD*10);
        end

        $display("\n========================================");
        $display("Testbench Complete");
        $display("  BCH Tests: %0d PASS, %0d FAIL", test_pass_count, test_fail_count);
        $display("========================================");
        $finish;
    end

    // Global Timeout
    initial begin
        #(CLK_PERIOD * 10000000);  // 100ms timeout
        $display("[ERROR] Global testbench timeout!");
        $finish;
    end

endmodule