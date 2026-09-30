#!/usr/bin/env python3
# Log a USB UART (115200 8N1) with host timestamps. Survives replugs.
# Lines written to the FIFO <logdir>/cmd are sent to the target (CR appended).
# With --stop, sends CRs from the U-Boot banner until abortboot, to reach the prompt.
# Usage: serlog.py LOGFILE [--stop]
import serial, sys, time, glob, os
logf = sys.argv[1]; autostop = '--stop' in sys.argv
fifo = os.path.join(os.path.dirname(logf), 'cmd')
if not os.path.exists(fifo): os.mkfifo(fifo)
fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK); keep = os.open(fifo, os.O_WRONLY)
out = open(logf, 'a', buffering=1)
def log(msg): out.write(f'[{time.strftime("%T")}] {msg}\n')
log(f'=== log start {time.strftime("%F")} autostop={autostop} ===')
while True:
    # TSX_SERIAL overrides the port (e.g. a socat pty when the adapter sits on the build host)
    ports = [os.environ['TSX_SERIAL']] if os.environ.get('TSX_SERIAL') else sorted(glob.glob('/dev/ttyUSB*'))
    if not ports: time.sleep(0.2); continue
    try:
        s = serial.serial_for_url(ports[0], baudrate=115200, timeout=0.05) if '://' in ports[0] else serial.Serial(ports[0], 115200, timeout=0.05)
    except (serial.SerialException, OSError): time.sleep(0.5); continue
    log(f'=== opened {ports[0]} ===')
    buf = b''; last = time.time(); spam = False; tick = 0
    try:
        while True:
            d = s.read(4096)
            if d:
                buf += d; last = time.time()
                # env us_delay_step=1 shrinks the countdown to ~100 us, so the key
                # must already be in the UART FIFO: spam CR from the banner on.
                if autostop and b'U-boot-0' in buf and not spam:
                    spam = True; log('=== U-Boot banner: sending CRs ===')
                if spam and b'exit abortboot' in buf:
                    spam = False; autostop = False; log('=== abortboot passed ===')
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                log(line.decode('utf-8', 'replace').rstrip('\r'))
            if buf and time.time() - last > 0.3:
                log(buf.decode('utf-8', 'replace')); buf = b''
            if spam and time.time() - tick > 0.03:
                s.write(b'\r'); tick = time.time()
            try: c = os.read(fd, 4096)
            except BlockingIOError: c = b''
            for l in c.decode().splitlines():
                log(f'>>> {l}'); s.write(l.encode() + b'\r'); time.sleep(0.05)
    except (serial.SerialException, OSError) as e:
        log(f'=== port lost: {e} ==='); time.sleep(0.5)
