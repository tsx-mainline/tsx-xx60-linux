#!/usr/bin/env python3
# ctlremove.py CARDNUM NAME...: remove ALSA user controls (e.g. the softvol "Master"/"Media")
# so the next softvol open recreates them with the current min_dB/max_dB (dB TLV).
import fcntl, os, struct, sys
def IOWR(t, nr, size): return (3 << 30) | (size << 16) | (ord(t) << 8) | nr
ELEM_ID = '<IiII44sI'                                    # numid iface device subdevice name[44] index
REMOVE = IOWR('U', 0x19, struct.calcsize(ELEM_ID))
fd = os.open('/dev/snd/controlC%s' % sys.argv[1], os.O_RDWR)
for name in sys.argv[2:]:
    buf = bytearray(struct.pack(ELEM_ID, 0, 2, 0, 0, name.encode(), 0))  # iface 2 = MIXER
    try: fcntl.ioctl(fd, REMOVE, buf); print('removed', name)
    except OSError as e: print('remove', name, 'failed:', e)
