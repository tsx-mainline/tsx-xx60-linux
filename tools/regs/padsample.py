# ON THE PANEL, read only: sample the AO pad input register (AO_8 MCLK, AO_9 BCLK,
# AO_10 LRCLK, AO_11 DOUT) and GPIOY_5 (CBUS PREG_PAD_GPIO1_I bit 5) N times.
import mmap, os, struct, sys
n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
ao = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xc8100000)
cb = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xc1108000)
hi = {k: 0 for k in ("AO_8", "AO_9", "AO_10", "AO_11", "Y_5")}
for _ in range(n):
    a = struct.unpack_from("<I", ao, 0x28)[0]      # AO_GPIO_I (AOBUS 0x0a)
    y = struct.unpack_from("<I", cb, 0x44)[0]      # PREG_PAD_GPIO1_I (CBUS 0x2011)
    for b in (8, 9, 10, 11):
        hi["AO_%d" % b] += (a >> b) & 1
    hi["Y_5"] += (y >> 5) & 1
print("samples", n, " ".join("%s=%.3f" % (k, v / n) for k, v in hi.items()))
