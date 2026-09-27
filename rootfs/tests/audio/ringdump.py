# ON THE PANEL: dump N bytes of the AUDIN FIFO0 ring (START from CBUS 0x2820)
import mmap, os, struct, sys
n = int(sys.argv[1]) if len(sys.argv) > 1 else 512
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
def rd(phys, size):
    base = phys & ~0xfff
    m = mmap.mmap(fd, size + (phys - base), mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    b = m[phys - base: phys - base + size]; m.close(); return b
cbus = lambda r: struct.unpack("<I", rd(0xc1100000 + r * 4, 4))[0]
start, ptr = cbus(0x2820), cbus(0x2822)
print("START %#x END %#x PTR %#x" % (start, cbus(0x2821), ptr))
data = rd(start, 0x10000)
w = struct.unpack("<%dI" % (len(data) // 4), data)
from collections import Counter
print("distinct words in ring:", len(set(w)), Counter(w).most_common(8))
for i in range(0, n // 4, 16):
    print(" ".join("%08x" % x for x in w[i:i + 16]))
