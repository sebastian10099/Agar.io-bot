#!/bin/bash
netstat -tuln | awk '{print $4}' | sort | uniq > open_ports.txt