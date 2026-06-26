#!/bin/bash

# Find a free port between 1024 and 65535
free_port=$(($RANDOM % (65535-1024)+1024))

# Initialize database using initdb command
python3 -m flask --app app initdb

# Run Flask app on the free port
python3 -m flask --app app run --host 0.0.0.0 --port $free_port