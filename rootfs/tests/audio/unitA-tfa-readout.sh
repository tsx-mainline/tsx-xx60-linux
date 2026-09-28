cd /mnt/shm
date
for a in 0x34 0x36; do echo "IDLE TFA $a: $(./i2crd 1 $a 22 0x00)"; done
am start -n com.android.music/.MediaPlaybackActivity -d /system/crestron/data/1K10S.wav </dev/null; sleep 1; input keyevent 126 </dev/null; sleep 1; cat /proc/asound/card0/pcm0p/sub0/status | head -2
sleep 3
date
for a in 0x34 0x36; do echo "PLAY TFA $a: $(./i2crd 1 $a 22 0x00) 47: $(./i2crd 1 $a 2 0x47)"; done
climax_hostsw -d /dev/i2c-1 --slave=0x34 --record --count=3 </dev/null 2>&1 | tail -12
echo "ZL 0x0244: $(./i2crd 1 0x45 4 0xfe 0x01 0x22 0x01) 0x0300: $(./i2crd 1 0x45 4 0xfe 0x02 0x00 0x01)"
climax_hostsw -d /dev/i2c-1 --slave=0x34 --calshow </dev/null 2>&1 | tail -3
climax_hostsw -d /dev/i2c-1 --slave=0x36 --calshow </dev/null 2>&1 | tail -3
climax_hostsw -d /dev/i2c-1 --slave=0x34 -D </dev/null 2>&1 | tail -24
date
echo DONE
