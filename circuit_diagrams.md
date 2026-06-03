# Circuit Diagrams — SRAM PUF System
## Exact values from source code

---

## DIAGRAM 1 — SRAM 6T Cell (PUF Core)

```
                    VDD
                     |
          +----------+----------+
          |                     |
        [PMOS P1]           [PMOS P2]
          |                     |
    Q ----+----[NMOS N3]  [NMOS N4]----+---- QB
    |          (WL)        (WL)        |
  [NMOS N1]                          [NMOS N2]
    |                                   |
   GND                                 GND

  BL (Bit Line)                    BLB (Bit Line Bar)
    |                                   |
  [N3]                               [N4]
    |_____ WL (Word Line) ______________|

Power-up behavior (from sram_puf_core.v):
  cell_bias[i] = (i * 214013 + 2531011) XOR-mixed  [8-bit deterministic]
  if cell_bias[i] > 0x80 (+/- random 8):  Q = 1
  else:                                    Q = 0

Metastability zone (META_THRESHOLD = 10):
  if 0x70 < cell_bias[i] < 0x90:  settling_time > 10  -> meta_flag = 1
  else:                             settling_time < 10  -> meta_flag = 0

Noise probability: NOISE_PROB = 0x0A (~4% = 10/256)
Array size: N = 256 cells
```

---

## DIAGRAM 2 — SRAM PUF Core Module (sram_puf_core.v)

```
Inputs:                          Outputs:
                                 
clk  ─────────────────────────► read_done
rst  ──► [Power-up Init]        puf_response[255:0]
         256 cells settle        puf_bit
         bias-based              meta_flags[255:0]
         
read_enable ──► [Read FSM]
                read_index: 0→255
                
enable_noise ─┐
temp_factor   ├──► [Noise Engine]
voltage_factor┘    effective_noise = NOISE_PROB
                                   * temp_factor(128)
                                   * voltage_factor(128)
                                   >> 14
                   noise_source = sram_cells XOR $urandom
                   noise_counter rotates through 256 bits

                   if noise_bit AND counter < threshold:
                       puf_response[i] = ~sram_cells[i]  (flipped)
                   else:
                       puf_response[i] =  sram_cells[i]  (clean)
```

---

## DIAGRAM 3 — Enrollment Flow (10 Power-up Cycles)

```
         ENROLL_CYCLES = 10,  STABILITY_THRESHOLD = 8

Cycle 1:  [RST→PUF] → read 256 bits → powerup_history[0]
Cycle 2:  [RST→PUF] → read 256 bits → powerup_history[1]
  ...
Cycle 10: [RST→PUF] → read 256 bits → powerup_history[9]

STATE_ENROLL_ANALYZE:
  For each bit i (0..255):
    ones_count = sum of powerup_history[0..9][i]
    majority_value[i] = (ones_count > 5) ? 1 : 0
    stability_count[i] = how many of 10 readings match majority

STATE_ENROLL_SELECT:
  stable_mask[i] = 1  if stability_count[i] >= 8
                      AND meta_flags[i] == 0
  Need at least 128 stable bits, else → STATE_ERROR
```

---

## DIAGRAM 4 — Fuzzy Extractor (BCH mode, USE_BCH=1)

```
╔══════════════════════════════════════════════════════════════╗
║                    ENROLLMENT MODE (mode=0)                  ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  puf_in[255:0] ──► [FILTER_PUF]                             ║
║  meta_mask[255:0]   skip meta_flags=1 bits                   ║
║                     collect first 128 stable bits            ║
║                     → stable_puf_bits[127:0]                 ║
║                              │                               ║
║                    secret_bits = stable_puf_bits             ║
║                              │                               ║
║              ┌───────────────┘                               ║
║              │  8 blocks × 16 bits (BCH K=16)                ║
║              ▼                                               ║
║  Block 0: secret[15:0]  ──► [BCH ENCODER] ──► code[30:0]    ║
║  Block 1: secret[31:16] ──► [BCH ENCODER] ──► code[61:31]   ║
║  ...                                                         ║
║  Block 7: secret[127:112]──► [BCH ENCODER] ──► code[247:217]║
║                              encoded_cw[247:0]               ║
║                                    │                         ║
║  helper_out = encoded_cw[247:0]                              ║
║             XOR {120'b0, secret_bits[127:0]}                 ║
║                                                              ║
║  secret_out = secret_bits[127:0]                             ║
╠══════════════════════════════════════════════════════════════╣
║                  RECONSTRUCTION MODE (mode=1)                ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  puf_in[255:0] ──► [FILTER_PUF] ──► stable_puf_bits[127:0]  ║
║                         (noisy version of original secret)   ║
║                                                              ║
║  noisy_cw[247:0] = helper_in[247:0]                          ║
║                  XOR {120'b0, stable_puf_bits[127:0]}        ║
║                              │                               ║
║              ┌───────────────┘                               ║
║              │  8 blocks × 31 bits (BCH N=31)                ║
║              ▼                                               ║
║  Block 0: noisy_cw[30:0]   ──► [BCH DECODER] ──► data[15:0] ║
║  Block 1: noisy_cw[61:31]  ──► [BCH DECODER] ──► data[31:16]║
║  ...                                                         ║
║  Block 7: noisy_cw[247:217]──► [BCH DECODER] ──► data[127:112]║
║                                                              ║
║  secret_out = decoded_secret[127:0]                          ║
╚══════════════════════════════════════════════════════════════╝

Parameters: PUF_BITS=256, SECRET_BITS=128, HELPER_BITS=248
            DATA_BITS=16, CODE_BITS=31, N_BLOCKS=8
```

---

## DIAGRAM 5 — BCH(31,16,3) Codec

```
PARAMETERS:
  M=5 (GF(2^5)), T=3, N=31, K=16
  Generator: g(x) = x^15+x^11+x^10+x^9+x^8+x^7+x^5+x^3+x^2+x+1
           = 16'h8FAF
  Primitive poly: p(x) = x^5+x^2+1 = 6'h25
  GF field: alpha^0=1 through alpha^30 (31 elements)

╔══════════════════════════════════════════════════════╗
║                    ENCODER                           ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  data_in[15:0]                                       ║
║       │                                              ║
║       ▼                                              ║
║  msg_poly = {data_in, 15'b0}  [31 bits]              ║
║       │                                              ║
║       ▼                                              ║
║  [Polynomial Long Division by g(x)=16'h8FAF]         ║
║   remainder[14:0] = msg_poly mod g(x)                ║
║       │                                              ║
║       ▼                                              ║
║  code_out = {data_in[15:0], remainder[14:0]}         ║
║             [16 data bits | 15 parity bits = 31 bits]║
╠══════════════════════════════════════════════════════╣
║                    DECODER                           ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  code_in[30:0] (possibly noisy)                      ║
║       │                                              ║
║  STEP 1: [SYNDROME CALCULATOR]                       ║
║    S[j] = r(alpha^j)  for j=1..6  (2T=6 syndromes)  ║
║    S[j] = XOR of alpha^(j*i) for each set bit i      ║
║    if all S[j]=0 → no error, output data directly    ║
║       │                                              ║
║  STEP 2: [BERLEKAMP-MASSEY ALGORITHM]                ║
║    Initialize: sigma(x)=1, B(x)=1, L=0              ║
║    For step=1..6:                                    ║
║      d = S[step] + Σ sigma[i]*S[step-i]             ║
║      if d=0: shift B, m++                            ║
║      if d≠0: update sigma(x), update B if 2L≤step-1 ║
║    Output: sigma(x) = error locator polynomial       ║
║    if degree(sigma) > 3 → error_flag=1               ║
║       │                                              ║
║  STEP 3: [CHIEN SEARCH]                              ║
║    For i=0..30:                                      ║
║      eval sigma(alpha^(-i))                          ║
║      if eval=0 → error at position i                 ║
║    Collect up to 3 error locations                   ║
║       │                                              ║
║  STEP 4: [ERROR CORRECTION]                          ║
║    For each error location:                          ║
║      corrected[err_loc[i]] = ~code_in[err_loc[i]]   ║
║    data_out = corrected[30:15]  (top K=16 bits)      ║
╚══════════════════════════════════════════════════════╝
```

---

## DIAGRAM 6 — SHA-256 Core (sha256_core.v)

```
INPUT: secret_in[127:0] (from fuzzy extractor)

STEP 0 — PADDING (in key_gen.v):
  padded[511:0] = {secret[127:0], 1'b1, 319'b0, 64'd128}
                   128 bits       1    zeros    length
                  ─────────────────────────────────────
                              512 bits total

STEP 1 — INITIAL HASH VALUES (H0..H7):
  H0=6a09e667  H1=bb67ae85  H2=3c6ef372  H3=a54ff53a
  H4=510e527f  H5=9b05688c  H6=1f83d9ab  H7=5be0cd19
  (first 32 bits of fractional parts of sqrt of primes 2,3,5,7,11,13,17,19)

STEP 2 — MESSAGE SCHEDULE (64 words):
  W[0..15]  = padded_message split into 16 × 32-bit words
  W[16..63] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16]

  where:
    sigma0(x) = ROTR(x,7)  XOR ROTR(x,18) XOR SHR(x,3)
    sigma1(x) = ROTR(x,17) XOR ROTR(x,19) XOR SHR(x,10)

STEP 3 — COMPRESSION (64 rounds):

  a=H0, b=H1, c=H2, d=H3, e=H4, f=H5, g=H6, h=H7

  Each round t (0..63):
  ┌─────────────────────────────────────────────────────┐
  │  T1 = h + Σ1(e) + Ch(e,f,g) + K[t] + W[t]         │
  │  T2 = Σ0(a) + Maj(a,b,c)                           │
  │                                                     │
  │  h←g, g←f, f←e, e←d+T1                            │
  │  d←c, c←b, b←a, a←T1+T2                           │
  └─────────────────────────────────────────────────────┘

  where:
    Σ0(x)    = ROTR(x,2)  XOR ROTR(x,13) XOR ROTR(x,22)
    Σ1(x)    = ROTR(x,6)  XOR ROTR(x,11) XOR ROTR(x,25)
    Ch(x,y,z)= (x AND y) XOR (NOT x AND z)
    Maj(x,y,z)=(x AND y) XOR (x AND z) XOR (y AND z)
    K[0..63] = cube root constants (K[0]=428a2f98 .. K[63]=c67178f2)

STEP 4 — FINALIZE:
  hash_out = { H0+a, H1+b, H2+c, H3+d, H4+e, H5+f, H6+g, H7+h }
           = 256-bit key output

FSM States: IDLE → PREPARE(64 cycles) → COMPRESS(64 cycles) → FINALIZE
```

---

## DIAGRAM 7 — 256-bit Galois LFSR (lfsr_256.v)

```
Primitive polynomial: x^256 + x^253 + x^250 + x^245 + 1
Feedback taps: bits 255, 253, 250, 245

feedback = lfsr[255] XOR lfsr[253] XOR lfsr[250] XOR lfsr[245]

Shift register (256 bits):

bit255  bit254  bit253 ... bit250 ... bit245 ... bit1  bit0
  │       │       │           │           │        │     │
  └──XOR──┘       └────XOR────┘           │        │     │
      │                 │                 │        │     │
      └─────────────────┴────XOR──────────┘        │     │
                               │                   │     │
                               └───────────────────┴─────┘
                                        feedback
                                           │
On each clock (enable=1):
  lfsr_reg <= {lfsr_reg[254:0], feedback}

Load operation (load=1):
  if seed == 0: lfsr_reg <= all 1s  (prevent lock-up)
  else:         lfsr_reg <= seed    (SHA-256 output)

Controller usage:
  Seed  = keygen_key (256-bit SHA-256 output)
  Runs  = exactly 256 clock cycles
  Output= lfsr_out[255:0] captured after cycle 256
  → Final 256-bit cryptographic key
```

---

## DIAGRAM 8 — Top Level System (sram_puf_controller.v)

```
                    ┌─────────────────────────────────────────────┐
                    │         sram_puf_controller                  │
                    │                                             │
  clk ─────────────►│                                             │
  rst ─────────────►│  ┌──────────────┐                          │
  start_enroll ────►│  │ sram_puf_core│◄── enable_noise=1        │
  start_reconstruct►│  │  N=256 cells │    temp_factor=128        │
                    │  │  BIAS_WIDTH=8│    voltage_factor=128     │
                    │  │  NOISE=0x0A  │                          │
                    │  └──────┬───────┘                          │
                    │         │ puf_response[255:0]               │
                    │         │ meta_flags[255:0]                 │
                    │         ▼                                   │
                    │  ┌──────────────┐                          │
  helper_data_in ──►│  │fuzzy_extractor│                         │
  [247:0]           │  │ PUF_BITS=256 │                          │
                    │  │ SECRET=128   │                          │
                    │  │ USE_BCH=1    │                          │
                    │  │ HELPER=248   │                          │
                    │  └──────┬───────┘                          │
                    │         │ fuzzy_secret[127:0]               │
                    │         │ fuzzy_helper[247:0]               │
                    │         ▼                                   │
                    │  ┌──────────────┐                          │
                    │  │   key_gen    │                          │
                    │  │ (SHA-256     │                          │
                    │  │  wrapper)    │                          │
                    │  │ SECRET=128   │                          │
                    │  └──────┬───────┘                          │
                    │         │ keygen_key[255:0]                 │
                    │         ▼                                   │
                    │  ┌──────────────┐                          │
                    │  │  lfsr_256    │◄── seed = keygen_key     │
                    │  │  WIDTH=256   │    256 cycles             │
                    │  │  taps:       │                          │
                    │  │  255,253,    │                          │
                    │  │  250,245     │                          │
                    │  └──────┬───────┘                          │
                    │         │ lfsr_out[255:0]                   │
                    │         ▼                                   │
  key_out[255:0] ◄──│      key_out                               │
  helper_data_out◄──│      helper_data_out[247:0]                │
  operation_done ◄──│      operation_done                        │
  error_flag ◄──────│      error_flag                            │
                    └─────────────────────────────────────────────┘

FSM States (13 states):
  0:IDLE → 1:ENROLL_POWERUP → 2:ENROLL_WAIT_READ → 3:ENROLL_ANALYZE
  → 4:ENROLL_SELECT → 5:ENROLL_EXTRACT → 9:KEYGEN → 12:LFSR → 10:DONE
  
  0:IDLE → 6:RECONSTRUCT_POWERUP → 7:RECONSTRUCT_READ
  → 8:RECONSTRUCT_DECODE → 9:KEYGEN → 12:LFSR → 10:DONE
  
  Any error → 11:ERROR
```

---

## DIAGRAM 9 — Hamming(7,4) Codec (alternative ECC, USE_BCH=0)

```
PARAMETERS: N=7, K=4 (corrects 1 bit error)

ENCODER:
  data_in[3:0] = [d3 d2 d1 d0]
  
  p0 = d0 XOR d1 XOR d3
  p1 = d0 XOR d2 XOR d3
  p2 = d1 XOR d2 XOR d3
  
  code_out[6:0] = [d3 d2 d1 d0 p2 p1 p0]

DECODER:
  syndrome[0] = c0 XOR c3 XOR c4 XOR c6
  syndrome[1] = c1 XOR c3 XOR c5 XOR c6
  syndrome[2] = c2 XOR c4 XOR c5 XOR c6

  syndrome → error position:
    000 → no error
    001 → flip bit 0 (p0)
    010 → flip bit 1 (p1)
    011 → flip bit 3 (d0)
    100 → flip bit 2 (p2)
    101 → flip bit 4 (d1)
    110 → flip bit 5 (d2)
    111 → flip bit 6 (d3)

  data_out = corrected_code[6:3]

Note: Used when USE_BCH=0
  32 blocks × 7 bits = 224-bit helper data (vs 248 for BCH)
```

---

## DIAGRAM 10 — Complete Key Derivation Pipeline

```
256 SRAM Cells (physical chip)
         │
         │ 10 power-up cycles
         ▼
┌─────────────────────┐
│  Stability Filter   │  majority vote per bit
│  threshold = 8/10   │  exclude meta_flags=1
└──────────┬──────────┘
           │ 256 bits (stable mask)
           ▼
┌─────────────────────┐
│   Fuzzy Extractor   │  select 128 stable bits
│   BCH(31,16,3)      │  encode 8 blocks × 16 bits
│   8 × 31 = 248 bits │  XOR with secret → helper
└──────────┬──────────┘
           │ 128-bit secret  +  248-bit helper (→ card)
           ▼
┌─────────────────────┐
│  SHA-256 (key_gen)  │  pad 128→512 bits
│  64 rounds          │  64-word schedule
│  8 × 32-bit output  │  compress + finalize
└──────────┬──────────┘
           │ 256-bit intermediate key
           ▼
┌─────────────────────┐
│   LFSR-256          │  seed with SHA-256 output
│   taps:255,253,     │  run exactly 256 cycles
│   250,245           │  Galois feedback
└──────────┬──────────┘
           │
           ▼
    256-bit Final Cryptographic Key (key_out)
```
