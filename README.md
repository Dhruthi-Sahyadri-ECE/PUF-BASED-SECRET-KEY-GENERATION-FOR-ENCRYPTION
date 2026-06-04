# PUF-Based Secret Key Generation for Encryption

A hardware security project implementing a **SRAM Physical Unclonable Function (PUF)** for secret key generation, designed and simulated in Vivado using Verilog.

## Overview

SRAM PUFs exploit manufacturing variations in SRAM cells to generate unique, device-specific bit signatures. These signatures are processed through error correction and hashing to produce a stable cryptographic key.

## Architecture

```
SRAM PUF Core (256 cells)
    → Stability Filtering (10 power-up cycles, majority vote)
    → Fuzzy Extractor (BCH or Hamming ECC)
    → SHA-256 Key Generator (128-bit secret → 256-bit hash)
    → 256-bit LFSR Key Expansion (256 cycles)
    → Final 256-bit Cryptographic Key
```

## Modules

| File | Description |
|------|-------------|
| `sram_puf_core.v` | SRAM PUF cell array — generates raw PUF response |
| `sram_puf_controller.v` | FSM controller for enrollment and key generation |
| `fuzzy_extractor.v` | Extracts stable bits from noisy PUF response |
| `bch_codec.v` | BCH error correction codec |
| `hamming_codec.v` | Hamming code error correction |
| `sha256_core.v` | SHA-256 hash engine for key derivation |
| `lfsr_256.v` | 256-bit LFSR for helper data generation |
| `key_gen.v` | Top-level key generation pipeline |
| `sram_puf_params.vh` | Global parameters and constants |

## Simulation

Testbench: `PHASE_FINAL.srcs/sim_1/new/tb_sram_puf_top.v`

Simulated using Xilinx Vivado XSim.

## Tools

- Xilinx Vivado (Simulation & Synthesis)
- Verilog HDL
