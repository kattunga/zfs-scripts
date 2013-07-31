#!/bin/bash
#

sh zfs-replicate.sh -h 10.0.0.13 -s "sig/datastore" -d "sig/test" -t "10 minutes ago" -v -o NETCAT -z
