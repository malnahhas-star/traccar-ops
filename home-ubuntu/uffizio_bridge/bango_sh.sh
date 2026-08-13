#!/bin/bash
# run a shell command ON bango (via F01 jump). arg1 = command string.
ssh -i /home/ubuntu/.keys/bango.key -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
  -o "ProxyCommand=ssh -i /home/ubuntu/.keys/f01.key -o StrictHostKeyChecking=no -o BatchMode=yes -W %h:%p ubuntu@20.0.4.234" \
  ubuntu@158.101.239.53 "$1"
