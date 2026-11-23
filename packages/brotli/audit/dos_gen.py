#!/usr/bin/env python3
"""Decompression-bomb and CPU/memory DoS probes for `packages/brotli` (written to $1, list in dos_cases.txt).

  bomb_1GiB_hand.br        64 hand-built meta-blocks (MLEN = 2^24, one dist-1 copy each): ~0.6 KB -> 1 GiB
  bomb_4GiB_hand.br        256 such meta-blocks -> 4 GiB (beyond Pion's 31-bit Int length range)
  bomb_1GiB_q5.br          Google libbrotlienc q5 lgwin24 over 1 GiB of zeros
  metadata_100k.br         100,000 empty metadata meta-blocks + 100,000 one-byte uncompressed blocks
  tiny_mb_100k.br          100,000 compressed meta-blocks with MLEN = 1
  maxtrees_flood.br        ~1 MiB of meta-blocks with NBLTYPES=256 x3, NTREESL/NTREESD=256, IMTF worst case
  input_512MiB_meta.br     a valid 528 MiB stream (33 x 16 MiB metadata blocks) - Int overflow in init capacity
"""
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brenc as E  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else '.'
BIN = os.path.join(OUT, 'bin')


def simple1(bw, alpha, sym):
    """Simple prefix code with a single symbol (decoded with 0 bits)."""
    bw.bits(1, 2)
    bw.bits(0, 2)
    bw.bits(sym, E.bitlen(alpha - 1))


def copy_metablock(bw, insert, copy, last=False):
    """One meta-block: [insert x literal 0] + copy `copy` bytes at distance 1, all codes single-symbol."""
    mlen = insert + copy
    bw.bits(1 if last else 0, 1)
    if last:
        bw.bits(0, 1)
    E.write_mlen(bw, mlen)
    if not last:
        bw.bits(0, 1)
    for _ in range(3):
        E.write_var8(bw, 0)  # NBLTYPES = 1
    bw.bits(0, 2)  # NPOSTFIX
    bw.bits(0, 4)  # NDIRECT
    bw.bits(0, 2)  # literal context mode
    E.write_var8(bw, 0)  # NTREESL
    E.write_var8(bw, 0)  # NTREESD
    simple1(bw, 256, 0)
    ic, ie = E.code_for(E.INSERT_BASE, E.INSERT_BITS, insert)
    cc, ce = E.code_for(E.COPY_BASE, E.COPY_BITS, copy)
    sym = (E.CELLS[(ic & ~7, cc & ~7)] << 6) | ((ic & 7) << 3) | (cc & 7)
    simple1(bw, 704, sym)
    dcode, dex, dnb = E.dist_code(1, 0, 0)
    simple1(bw, 64, dcode)
    bw.bits(ie, E.INSERT_BITS[ic])
    bw.bits(ce, E.COPY_BITS[cc])
    bw.bits(dex, dnb)


def hand_bomb(n_blocks):
    bw = E.BW()
    E.write_wbits(bw, 24)
    copy_metablock(bw, 1, (1 << 24) - 1)
    for _ in range(n_blocks - 1):
        copy_metablock(bw, 0, 1 << 24)
    bw.bits(1, 1)
    bw.bits(1, 1)
    return bw.done()


def metadata_flood(n):
    bw = E.BW()
    E.write_wbits(bw, 16)
    for _ in range(n):
        bw.bits(0, 1)
        bw.bits(3, 2)
        bw.bits(0, 1)
        bw.bits(0, 2)
        bw.align()
    for _ in range(n):
        bw.bits(0, 1)
        E.write_mlen(bw, 1)
        bw.bits(1, 1)
        bw.align()
        bw.raw(b'x')
    bw.bits(1, 1)
    bw.bits(1, 1)
    return bw.done()


def tiny_mb_flood(n):
    bw = E.BW()
    E.write_wbits(bw, 16)
    for _ in range(n):
        bw.bits(0, 1)
        E.write_mlen(bw, 1)
        bw.bits(0, 1)
        for _ in range(3):
            E.write_var8(bw, 0)
        bw.bits(0, 6)
        bw.bits(0, 2)
        E.write_var8(bw, 0)
        E.write_var8(bw, 0)
        simple1(bw, 256, 65)
        simple1(bw, 704, (1 << 3) | 0)  # insert 1, copy 2, implicit distance (ignored)
        simple1(bw, 64, 0)
    bw.bits(1, 1)
    bw.bits(1, 1)
    return bw.done()


def maxtrees_metablock(bw):
    bw.bits(0, 1)
    E.write_mlen(bw, 1)
    bw.bits(0, 1)
    for _ in range(3):  # NBLTYPESL/I/D = 256
        E.write_var8(bw, 255)
        simple1(bw, 258, 0)  # block-type code
        simple1(bw, 26, 25)  # block-count code: longest blocks
        bw.bits(0, 24)
    bw.bits(0, 2)
    bw.bits(0, 4)
    for _ in range(256):
        bw.bits(0, 2)
    for _ in range(2):  # literal context map (16,384 entries) then distance map (1,024 entries)
        E.write_var8(bw, 255)  # NTREES = 256
        bw.bits(0, 1)  # no RLE
        simple1(bw, 256, 255)  # every entry = MTF index 255 at 0 bits each
        bw.bits(1, 1)  # IMTF: each entry shifts 255 slots
    for _ in range(256):
        simple1(bw, 256, 65)
    for _ in range(256):
        simple1(bw, 704, (1 << 3) | 0)
    for _ in range(256):
        simple1(bw, 64, 0)


def maxtrees_flood(target):
    bw = E.BW()
    E.write_wbits(bw, 16)
    n = 0
    while len(bw.out) < target:
        maxtrees_metablock(bw)
        n += 1
    bw.bits(1, 1)
    bw.bits(1, 1)
    return bw.done(), n


def big_input(n_meta):
    bw = E.BW()
    E.write_wbits(bw, 16)
    chunk = b'\0' * (1 << 24)
    parts = []
    for _ in range(n_meta):
        bw.bits(0, 1)
        bw.bits(3, 2)
        bw.bits(0, 1)
        bw.bits(3, 2)
        bw.bits((1 << 24) - 1, 24)
        bw.align()
        parts.append(bytes(bw.out))
        bw.out = bytearray()
        parts.append(chunk)
    bw.bits(1, 1)
    bw.bits(1, 1)
    parts.append(bw.done())
    return b''.join(parts)


def main():
    cases = []

    def put(name, data, limits):
        open(os.path.join(OUT, name), 'wb').write(data)
        print(f'  {name:28s} {len(data):>11,d} B')
        for l in limits:
            cases.append(f'{name} {l}')

    put('bomb_1GiB_hand.br', hand_bomb(64), [268435456, 1048576, 0])
    put('bomb_4GiB_hand.br', hand_bomb(256), [2147483647])
    zin = os.path.join(OUT, 'zeros_1GiB.rec')
    if not os.path.exists(os.path.join(OUT, 'bomb_1GiB_q5.br')):
        with open(zin, 'wb') as f:
            f.write((1 << 30).to_bytes(4, 'little'))
            z = b'\0' * (1 << 24)
            for _ in range(64):
                f.write(z)
        subprocess.run([os.path.join(BIN, 'c_audit'), 'enc', '5', '24', zin, zin + '.out'], check=True)
        rec = open(zin + '.out', 'rb').read()
        open(os.path.join(OUT, 'bomb_1GiB_q5.br'), 'wb').write(rec[4:])
        os.unlink(zin)
        os.unlink(zin + '.out')
    print(f'  bomb_1GiB_q5.br              {os.path.getsize(os.path.join(OUT, "bomb_1GiB_q5.br")):>11,d} B')
    cases += ['bomb_1GiB_q5.br 268435456', 'bomb_1GiB_q5.br 1048576']
    put('metadata_100k.br', metadata_flood(100000), [268435456])
    put('tiny_mb_100k.br', tiny_mb_flood(100000), [268435456])
    data, n = maxtrees_flood(1 << 20)
    print(f'    (maxtrees_flood: {n} meta-blocks)')
    put('maxtrees_flood.br', data, [268435456])
    put('input_512MiB_meta.br', big_input(33), [268435456])
    open(os.path.join(OUT, 'dos_cases.txt'), 'w').write('\n'.join(cases) + '\n')


if __name__ == '__main__':
    main()
