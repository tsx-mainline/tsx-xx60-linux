# ON THE PANEL: read or write AO_SECURE_REG0/1 (secbus2 0xda004000/4) via /dev/mem
#   python3 secreg.py            -> print REG0 REG1
#   python3 secreg.py 1 0xVALUE  -> write REG1
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0xda004000)
if len(sys.argv) == 3:
    r = int(sys.argv[1]); v = int(sys.argv[2], 0)
    old = struct.unpack_from("<I", m, 4 * r)[0]
    struct.pack_into("<I", m, 4 * r, v)
    print("AO_SECURE_REG%d 0x%08x -> 0x%08x (read back 0x%08x)" % (r, old, v, struct.unpack_from("<I", m, 4 * r)[0]))
else:
    print("AO_SECURE_REG0 0x%08x REG1 0x%08x" % struct.unpack_from("<II", m, 0))
