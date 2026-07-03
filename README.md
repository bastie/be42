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

## compare

### enwik8

| compressor | version | parameter | size in bytes |     % | time     | bytes per second | comment            |
| ---------- | ------- | --------- | ------------- | ----- | -------- | ---------------- | ------------------ |
| ben        |    0.42 |           |    32.280.526 | 32.28 |  2:58.30 |          181.046 | non optimized code |
| ben        |    0.43 |           |    22.805.378 | 22.81 |  2:44.67 |          607.275 | nbmec, 2nd place   |
| ben+xz     |         | xz -9ekf  |    31.300.064 | 31.30 |  3:06.06 |          168.225 |                    |
| bzip2      |   1.0.8 | -9zkf     |    29.008.758 | 29.01 |  0:04.75 |        6.107.106 |                    |
| gzip       |     479 | -9kf      |    36.475.811 | 36.48 |  0:03.52 |       10.362.446 | fast               |
| xz         |   5.8.2 | -9ekf     |    24.831.656 | 24.83 |  0:56.00 |          443.422 |                    |
| zopfli     |   1.0.3 | --i100    |    34.955.165 | 34.96 | 10:10.79 |           57.229 |                    |
| zpaq       |    7.15 | -m5       |    19.625.015 | 19.63 |  4:32.29 |           71.907 | best               |
| zstd       |   1.5.7 | -k19f     |    26.944.227 | 26.94 |  0:41.83 |          664.136 |                    |

# Dependencies

**No dependency** for be42 library.

CLI tool *ben* needed *swift-argument-parser* and *be42*.

# License

Apache License Version 2.0

# Version

**0.43.0**

New default algorithm *nbmec* (nibble.bwt.markov.exclusion.cabac): adaptive binary exclusion coding of the permutation structure. On a mixed source/text corpus it already beats zlib and lzma and is close to bzip2 — enwik8 numbers in the compare table above are still from 0.42 (*nbbmr*) and pending re-measurement. Files compressed with 0.42 stay decompressable (algorithm byte in the container header).

**0.42.0**

First public version, perhaps the 42nd attempt at a functioning implementation. Better than gzip.

