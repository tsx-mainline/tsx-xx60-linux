# Instrument the U-Boot USB factory hook: each step appends a marker to env "tsxdbg"
# and saves it, so Android can show how far U-Boot got (fw_printenv tsxdbg).
fw_setenv switch_bootmode 'setenv tsxdbg S; usb start 0; if usb storage; then setenv tsxdbg ${tsxdbg}_stor; else setenv tsxdbg ${tsxdbg}_nostor; fi; if fatls usb 0; then setenv tsxdbg ${tsxdbg}_fat; else setenv tsxdbg ${tsxdbg}_nofat; fi; if fatexist usb 0 jabil.txt; then setenv tsxdbg ${tsxdbg}_jabil; saveenv; run jabil_factory; else setenv tsxdbg ${tsxdbg}_nojabil; saveenv; fi;'
fw_setenv jabil_factory 'echo check factory image file;run bcb_cmd; usb factory 0; setenv tsxdbg ${tsxdbg}_f-${factoryimage}; saveenv; if fatexist usb 0 ${factoryimage}; then setenv tsxdbg ${tsxdbg}_img; saveenv; run sdupgrade; if fatload usb 0 ${loadaddr} ${factoryimage}; then setenv tsxdbg ${tsxdbg}_loaded; saveenv; bootm; fi; setenv tsxdbg ${tsxdbg}_nobootm; saveenv; fi;'
fw_setenv tsxdbg armed
