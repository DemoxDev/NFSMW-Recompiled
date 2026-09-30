# -*- coding: utf-8 -*-
# PAL Spanish -> PAL English address translation for the nfsmw-nx sources, without a PAL Spanish XEX.
#
# nfsmw-nx (https://github.com/StevensND/nfsmw-nx) writes every hook, override and function boundary
# against the PAL Spanish executable; this project builds the PAL English one (454107D9, entry 0x8262E9A8).
# Its own tool for that (tools/editions/emparejar.py) needs both executables. This one needs neither:
#
#   Functions. The port ships a PGO profile per edition (pgo/<edition>), and the PAL English one was made
#   with the Spanish function partition, so both have the same functions in the same order in every
#   nfsmw_recomp.N.cpp.gcda. GCC names each function record by the crc32 of its symbol
#   (__imp__sub_XXXXXXXX), which is inverted here over every 4-byte-aligned address.
#   Result: 56,339 pairs, no conflicts, 98.9 % of them function starts in our own PAL English codegen.
#
#   Addresses inside a function: same offset, only if the function has the same size in both editions.
#
#   .data (>= 0x828D0000): does not move. Every global the native code uses that the PAL English code
#   also loads directly (lis + d-form) is loaded at the same address.
#
#   .rdata: only the addresses in RDATA below, each checked against the PAL English instruction that loads
#   it or its value. The top of .rdata moved +0x10.
#
# Anything else stops the translation, so a new address in a future sync gets checked by hand.
#
# Usage:
#   pal_en.py archivos <file>...        translate files in place
#   pal_en.py reparto <partition.json>  codegen partition of the PAL English profile
import glob
import json
import os
import re
import struct
import sys

import numpy as np

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(RAIZ, 'tools', 'editions'))
from crear_arbol import traducir_texto  # noqa: E402  (PAT and the pasted sub_824F, D7C0 names)

PGO = os.path.join(RAIZ, 'pgo')
RDATA = {
    # same address: loaded at it in PAL English, or same value/shader header there
    0x82000000: 0x82000000, 0x8200FCF8: 0x8200FCF8, 0x8200FE00: 0x8200FE00, 0x8200FFC0: 0x8200FFC0,
    0x82040000: 0x82040000, 0x82040200: 0x82040200, 0x82050000: 0x82050000, 0x82057114: 0x82057114,
    0x8205E240: 0x8205E240, 0x82060000: 0x82060000, 0x82060BBC: 0x82060BBC, 0x82060E70: 0x82060E70,
    0x82060E74: 0x82060E74, 0x82061CE8: 0x82061CE8, 0x820624D0: 0x820624D0, 0x82062864: 0x82062864,
    0x82062AC8: 0x82062AC8, 0x82063038: 0x82063038, 0x82063970: 0x82063970, 0x82072490: 0x82072490,
    0x82072498: 0x82072498, 0x820724E0: 0x820724E0, 0x82077C2C: 0x82077C2C, 0x820B0000: 0x820B0000,
    # +0x10: sub_82449C00 (addi), the resamplers and the filter (lfs), 1/8192 and MPH2MPS(400) by value
    0x8208F7C0: 0x8208F7D0, 0x820AFD18: 0x820AFD28, 0x820AFD68: 0x820AFD78, 0x820AFF50: 0x820AFF60,
    0x820B069C: 0x820B06AC,
}
DATA_INICIO = 0x828D0000
FIN_IMAGEN = 0x82D00000


def _crc_gcc(prefijo, direcciones):
    # gcc/coverage.cc profile_id of a public symbol: crc32_string (MSB first, 0x04C11DB7, seed 0, the
    # terminating NUL included), & 0x7FFFFFFF, 0 -> 1.
    tabla = np.zeros(256, np.uint32)
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else (c << 1)
        tabla[i] = c & 0xFFFFFFFF
    c = np.zeros(len(direcciones), np.uint32)
    hexa = np.frombuffer(b'0123456789ABCDEF', np.uint8)
    bytes_ = [np.full(len(direcciones), b, np.uint8) for b in prefijo.encode()]
    bytes_ += [hexa[(direcciones >> np.uint32(s)) & np.uint32(0xF)] for s in range(28, -4, -4)]
    bytes_.append(np.zeros(len(direcciones), np.uint8))
    for b in bytes_:
        c = (c << np.uint32(8)) ^ tabla[((c >> np.uint32(24)) ^ b.astype(np.uint32)) & np.uint32(0xFF)]
    c &= np.uint32(0x7FFFFFFF)
    return c + (c == 0).astype(np.uint32)


def _funciones_gcda(ruta):
    b = open(ruta, 'rb').read()
    w = struct.unpack('<%dI' % (len(b) // 4), b[:len(b) // 4 * 4])
    out, i = [], 4
    while i + 1 < len(w):
        etiqueta, largo = w[i], w[i + 1]
        if etiqueta == 0x01000000:
            out.append(w[i + 2])
        i += 2 + (0 if largo & 0x80000000 else largo // 4)  # negative length: all-zero counters, no data
    return out


def _ficheros(edicion):
    patron = os.path.join(PGO, edicion, 'CMakeFiles#nfsmw_recomp.dir#generated#default#nfsmw_recomp.*.cpp.gcda')
    return {int(re.search(r'recomp\.(\d+)\.cpp', r).group(1)): r for r in glob.glob(patron)}


def funciones():
    """{PAL Spanish function: PAL English function} and {PAL English function: partition file}."""
    direcciones = np.arange(0x82000000, 0x82E00000, 4, dtype=np.uint32)
    ident = dict(zip(_crc_gcc('__imp__sub_', direcciones).tolist(), direcciones.tolist()))
    es, en = _ficheros('pal_es'), _ficheros('pal_en')
    mapa, reparto = {}, {}
    for n in sorted(es):
        for a, b in zip(_funciones_gcda(es[n]), _funciones_gcda(en[n])):
            if a in ident and b in ident:
                mapa[ident[a]] = ident[b]
                reparto[ident[b]] = n
    return mapa, reparto


class Traductor(dict):
    """A dict that answers any address it can translate safely; the rest go to `faltan`."""

    def __init__(self):
        super().__init__()
        self.funcs, _ = funciones()
        self.es = sorted(self.funcs)
        self.en = sorted(set(self.funcs.values()))

    def __contains__(self, d):
        return self._traducir(d) is not None

    def __getitem__(self, d):
        return self._traducir(d)

    def _traducir(self, d):
        if d in self.funcs:
            return self.funcs[d]
        if d in RDATA:
            return RDATA[d]
        if DATA_INICIO <= d < FIN_IMAGEN:
            return d
        i = np.searchsorted(self.es, d, 'right') - 1
        if 0 <= i < len(self.es) - 1:
            f, fin = self.es[i], self.es[i + 1]
            g = self.funcs[f]
            j = np.searchsorted(self.en, g, 'right')
            if j < len(self.en) and self.en[j] - g == fin - f:
                return g + (d - f)
        return None


def main():
    orden = sys.argv[1]
    if orden == 'reparto':
        _, reparto = funciones()
        datos = {'assignments': {'%08X' % d: n for d, n in sorted(reparto.items())},
                 'file_count': max(reparto.values()) + 1, 'max_file_bytes': 1048576, 'version': 2}
        open(sys.argv[2], 'w', encoding='utf-8').write(json.dumps(datos, indent=2) + '\n')
        return
    t, faltan = Traductor(), set()
    for ruta in sys.argv[2:]:
        texto = open(ruta, encoding='utf-8', newline='').read()
        nuevo = traducir_texto(texto, t, faltan)
        if nuevo != texto:
            open(ruta, 'w', encoding='utf-8', newline='').write(nuevo)
    if faltan:
        sys.exit('no safe translation: ' + ', '.join(sorted(faltan)))


if __name__ == '__main__':
    main()
