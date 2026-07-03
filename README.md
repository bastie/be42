# beNibble

<!--
 SPDX-License-Identifier: Apache-2.0
 SPDX-FileCopyrightText: © 2026 Sebastian Ritter
 -->

## idea

Nearly(? or) all compression algoritm see a file as byte-stream with explicite information byte-offset and byte-value. Most of them replacing repeating sequences with references, and yes this works great.

In different this compression algorithm look different and use another view on file, the **file structure as compression base**. All files can be descripe as repeated part time permutation of values. This permutation ends with first repeated value. Also you can see this value as part who concat two permutations, because one end with this value and another start with this value. At the end it can be a rest.

For example (based on Nibbles instead of Bytes):

```
01 0A 07 04 0A 03 03 05 0A 07 04 0A 0F
 |           |     |              |
Start        |     |              |
       Repeated    |              |
      also Start   |              |
             Repeated       Repeated
            also Start      also Rest
```

Properties of Nibble-permutation are btw. max size is 16 (0123456789ABCDEF) but in random data the birthday hint tells us most of that are maybe 5 to 6 elements long. Also the probality of repeated value increases with next value, beginning with 1/15, 1/14, 1/13 ... 1/1. Its like a **markov chain**.


Note: The algorithm is based on human intelligence, but part of the code was first written by artificial intelligence (vibe coding) and than modified by human because the result is the priority.

### exclusion coding (nbmec, default since 0.43.0)

The first implementation (*nbbmr*) still coded the identity of the next value inside a permutation with uniform cost. The better question is the opposite one: instead of coding what the next value IS, we code for the most probable candidates that a value is NOT the next one — a chain of binary exclusion decisions. The last remaining candidate is implicit and costs zero bits.

- candidates are ordered by recency (move-to-front); the hit ends the chain
- the markov property from above (repeat probability grows with permutation length) is learned adaptively per length instead of assumed
- runs (frequent after the nibble BWT) get their own contexts per run length
- everything is coded with an adaptive binary range coder (LZMA style, 11 bit probabilities)

No frequency tables, no tail: the decoder replays the identical model forward, therefore decompression is bijective with only an 8 byte payload header (nibble count + BWT index).

### context mixing (ncmm, default since 0.44.0)

The next step evaluates more of the implicit information a file carries — directly on the nibble stream, without BWT:

1. **context**: the preceding nibbles of several orders (up to 6 bytes deep) at once — the markov chain idea generalized to multiple depths
2. **position inside the byte**: high and low nibble have completely different distributions (the parity of the position is implicit information)
3. **position of the last occurrence**: a match model remembers where the same byte context appeared before and predicts the continuation — the value position as implicit information; the match state also conditions the mixer and the SSE stage

Every nibble is coded as 4 binary tree decisions. Seven predictions are combined by logistic mixing (pure integer fixed point, embedded sigmoid tables — no float, deterministic on every platform), refined by two APM/SSE stages. The decoder replays the identical model forward: bijective with a 4 byte payload header (byte count). No suffix array construction anymore. Table sizes are laid out for files in the 100 MB range (~300 MB model memory).

## compare

### enwik8

| compressor | version | parameter | size in bytes |     % | time     | bytes per second | comment            |
| ---------- | ------- | --------- | ------------- | ----- | -------- | ---------------- | ------------------ |
| ben        |    0.42 |           |    32.280.526 | 32.28 |  2:58.30 |          181.046 | non optimized code |
| ben        |    0.43 |           |    22.805.378 | 22.81 |  2:44.67 |          607.275 | nbmec              |
| ben        |    0.47 |           |    22.592.372 | 22.59 |  2:51.58 |          582.819 | nbcm, 2nd place    |
| ben        |    0.48 | 16MiB blk |    24.661.973 | 24.66 |  2:16.67 |          731.690 | nbcmb, block cost  |
| ben+xz     |         | xz -9ekf  |    31.300.064 | 31.30 |  3:06.06 |          168.225 | ben 0.42           |
| ben+xz     |         | xz -9ekf  |    22.769.404 | 22.77 |  3:11.54 |                  | ben 0.43           |
| bzip2      |   1.0.8 | -9zkf     |    29.008.758 | 29.01 |  0:04.75 |        6.107.106 |                    |
| gzip       |     479 | -9kf      |    36.475.811 | 36.48 |  0:03.52 |       10.362.446 | fast               |
| xz         |   5.8.2 | -9ekf     |    24.831.656 | 24.83 |  0:56.00 |          443.422 |                    |
| zopfli     |   1.0.3 | --i100    |    34.955.165 | 34.96 | 10:10.79 |           57.229 |                    |
| zpaq       |    7.15 | -m5       |    19.625.015 | 19.63 |  4:32.29 |           71.907 | best               |
| zstd       |   1.5.7 | -k19f     |    26.944.227 | 26.94 |  0:41.83 |          664.136 |                    |

### silesia

Algorithm: nbcm (nibble.bwt.chain.mixing) 

```bash
Maxmilian:silesia$ time xz -ekfT 1 silesia.tar
xz -ekfT 1 silesia.tar  75,24s user 1,07s system 96% cpu 1:19,04 total
Maxmilian:silesia$ time ../../.build/release/ben silesia.tar
../../.build/release/ben silesia.tar  471,09s user 297,99s system 76% cpu 16:50,79 total
Maxmilian:silesia$ ls -lisa
total 631992
432009696      0 drwxr-xr-x  5 bastie  staff        160  3 Juli 17:04 .
432009691      0 drwxr-xr-x  8 bastie  staff        256  3 Juli 16:37 ..
432010254 430528 -rwxr-xr-x  1 bastie  staff  211948544  3 Juli 16:37 silesia.tar
432014353 105192 -rw-r--r--  1 bastie  staff   53855592  3 Juli 17:04 silesia.tar.ben
432010379  96272 -rwxr-xr-x  1 bastie  staff   48928248  3 Juli 16:37 silesia.tar.xz
```

### enwik


# Dependencies

**No dependency** for be42 library.

CLI tool *ben* needed *swift-argument-parser* and *be42*.

# License

Apache License Version 2.0

# Version

**0.48.0**

New default algorithm *nbcmb* (0x05): *nbcm* in block mode. The file is split into independent, length-prefixed blocks, each with its own BWT, model and range coder stream. This makes enwik9 (1 GB) possible at all (a whole-file suffix array would need ~50 GB RAM), keeps suffix array working sets cache friendly (enwik8: 2:16 instead of 2:51) and prepares parallel compression AND decompression — every block is independently decodable. Measured block cost on enwik8: 16 MiB blocks lose ~2 percentage points ratio against a single block — the global BWT context bundling matters. Therefore the block size is selectable via `--blocksize` (MiB, default 64). *nbcm* (0x04) streams stay decompressable.

**0.47.0**

New default algorithm *nbcm* (nibble.bwt.chain.mixing, 0x04): the markov chain / birthday paradox core stays untouched — same permutation blocks, exclusion chains and contexts as *nbmec*. Every context probability is now a PAIR of fast and slow adapting statistics combined by a small learned mixer per slot (catalog no. 44), refined by an APM/SSE stage per event class (no. 35). Nothing freezes, both timescales adapt forever. 22.59 % on enwik8, the output is no longer compressible by xz. Two further steps (per-slot bit history, previous-nibble conditioning) were measured and rejected — the permutation structure already carries that information.

Also new: *ncmm* (nibble.context.mixing.match, 0x03) — context mixing without BWT (orders 0–6, word model, sparse contexts, match model, hash checksums; see docs/implizite-informationen.md). Reaches 24.75 % on enwik8; parked for now, kept decodable. All algorithms since 0.42 stay decompressable via the container algorithm byte.

**0.43.0**

New default algorithm *nbmec* (nibble.bwt.markov.exclusion.cabac): adaptive binary exclusion coding of the permutation structure. On a mixed source/text corpus it already beats zlib and lzma and is close to bzip2 — enwik8 numbers in the compare table above are still from 0.42 (*nbbmr*) and pending re-measurement. Files compressed with 0.42 stay decompressable (algorithm byte in the container header).

**0.42.0**

First public version, perhaps the 42nd attempt at a functioning implementation. Better than gzip.

