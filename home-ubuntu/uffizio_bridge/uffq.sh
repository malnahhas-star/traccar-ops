#!/bin/bash
set -e
source /home/ubuntu/uffizio_bridge/uffizio.env
SQL=$(printf "%s" "$1" | base64 -d)
ssh -i /home/ubuntu/.keys/bango.key -o StrictHostKeyChecking=no -o BatchMode=yes -o "ProxyCommand=ssh -i /home/ubuntu/.keys/f01.key -o StrictHostKeyChecking=no -o BatchMode=yes -W %h:%p ubuntu@20.0.4.234" ubuntu@158.101.239.53 "mysql --default-character-set=utf8mb4 -h 80.225.74.41 -u com_live -p'$UFFIZIO_MYSQL_PW' -D gps -N -e \"$SQL\""