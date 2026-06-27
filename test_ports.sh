#!/bin/bash
curl -v http://localhost:8085 &>/tmp/out_8085.log
netcat localhost 8086 &>/tmp/out_8086.log