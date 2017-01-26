#!/bin/sh
PATH=/usr/bin:/bin:/sbin

. /scripts/functions
. /etc/encryptrootfs.conf

if [ ! -x "/var/lib/dhcp" ]; then
   mkdir -p  /var/lib/dhcp
fi

out=$(ip link set eth0 up 2>&1)
if [ $? -gt 0 ]; then
   _log_msg "Error during ip link up. Log: \n ${out}"
   exit 1
fi

_log_msg "Calling dhclient"
out=$(dhclient -v -sf /bin/dhclient-script.sh 2>&1)
if [ $? -gt 0 ]; then
   _log_msg "Error during DHCP configuration. Log: \n ${out}"
   exit 1
fi
_log_msg "dhcient output: \n ${out}"

#some debug output
_log_msg "resolv.conf: \n $(cat /etc/resolv.conf 2>&1)"
_log_msg "Connecting to KMS: $(nc -v -w 1 kms.us-east-1.amazonaws.com 443 2>&1)\n"
_log_msg "Connecting to metadata service: $(nc -v -w 1 169.254.169.254 80 2>&1)\n"
exit 0
