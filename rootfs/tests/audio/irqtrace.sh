#!/bin/sh
# irqtrace.sh FILE PERIOD BUFFER: play FILE on raw hw with the given sizes, print the AIU
# IRQ (54) intervals in ms and the aplay underrun count. sendspin/voice stopped + restarted.
T=/sys/kernel/tracing
rc-service tsx-sendspin stop >/dev/null 2>&1; rc-service tsx-voice stop >/dev/null 2>&1
echo 0 > $T/tracing_on; echo > $T/trace; echo "irq==54" > $T/events/irq/irq_handler_entry/filter
echo 1 > $T/events/irq/irq_handler_entry/enable; echo 1 > $T/tracing_on
echo "$(date +%T) aplay period $2 buffer $3: underruns $(aplay -D hw:TSW1060,0 --period-size=$2 --buffer-size=$3 $1 2>&1 | grep -c underrun)"
echo 0 > $T/tracing_on; echo 0 > $T/events/irq/irq_handler_entry/enable; echo 0 > $T/events/irq/irq_handler_entry/filter
grep irq= $T/trace | awk '{t=$4; sub(":","",t); if (p) printf "%.1f ", (t-p)*1000; p=t} END{print ""}'
rc-service tsx-sendspin start >/dev/null 2>&1; rc-service tsx-voice start >/dev/null 2>&1
