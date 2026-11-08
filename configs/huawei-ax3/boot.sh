#!/bin/sh
# Called by Huawei's native rc-call after the patch overlay is mounted.
# This supervisor runs entirely on the router, without a PC or network service.
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH
# Prefer killing a memory-hungry userspace process over rebooting the router.
echo 0 > /proc/sys/vm/panic_on_oom
# Give vendor Wi-Fi/network initialization time to finish.
sleep 20
while :; do
    /bin/sh /data/mvp/mvp-service.sh watch >/tmp/mvp-watchdog.log 2>&1
    sleep 10
done
