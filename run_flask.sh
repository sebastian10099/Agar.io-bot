#!/bin/bash
PORTS=(2048 31456 4097 51200)
python3 -m flask run --host=0.0.0.0
echo \$PORTS[\$((RANDOM%4+1))] | xargs python3 -m flask run --port=$PORTS[\$((RANDOM%4+1))]
echo "Flask-Dashboard wird auf Port $PORTS[$((RANDOM%4+1))] gestartet"