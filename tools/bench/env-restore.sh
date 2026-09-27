# Restore the stock 1.00.12 values changed by env-breadcrumbs.sh (run as root on the panel)
fw_setenv switch_bootmode 'usb start 0;if fatexist usb 0 jabil.txt; then run jabil_factory; else   fi;'
fw_setenv jabil_factory 'echo check factory image file;run bcb_cmd; usb factory 0; if fatexist usb 0 ${factoryimage}; then run sdupgrade; if fatload usb 0 ${loadaddr} ${factoryimage}; then bootm; fi;fi;'
fw_setenv factoryimage 0
fw_setenv tsxdbg
