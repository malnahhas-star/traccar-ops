#!/bin/bash
export HOME=/home/ubuntu
exec ssh -v -i /home/ubuntu/.keys/bango.key \
  -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o BatchMode=yes -o UserKnownHostsFile=/home/ubuntu/.ssh/known_hosts_uffizio \
  -o "ProxyCommand=ssh -i /home/ubuntu/.keys/f01.key -o StrictHostKeyChecking=no -o BatchMode=yes -o UserKnownHostsFile=/home/ubuntu/.ssh/known_hosts_uffizio -W %h:%p ubuntu@20.0.4.234" \
  -N -L 9092:localhost:9092 ubuntu@158.101.239.53
