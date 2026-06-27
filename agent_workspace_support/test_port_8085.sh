#!/bin/bash
# Test if port 8085 is open on localhost (127.0.0.1)
nc -zv 127.0.0.1 8085 && echo 'Port 8085 is open' || echo 'Port 8085 is closed'