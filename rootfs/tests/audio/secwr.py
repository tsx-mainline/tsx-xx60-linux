# ON THE PANEL: write one AO_SECURE_REGn (no read in the same process)
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ, offset=0xda004000)
r, v = int(sys.argv[1]), int(sys.argv[2], 0)
m[4 * r:4 * r + 4] = struct.pack("<I", v)
print("wrote 0x%08x to AO_SECURE_REG%d" % (v, r))
