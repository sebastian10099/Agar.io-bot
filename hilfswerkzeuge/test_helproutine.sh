#!/bin/bash
echo 'Hello, World!'
./test_helproutine.sh
if [ $? -eq 127 ]; then echo 'File not found'; fi