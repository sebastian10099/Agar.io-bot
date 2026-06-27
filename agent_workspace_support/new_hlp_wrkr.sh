#!/bin/bash
# Start Flask app on a free port
FLASK_APP=app.py flask run --port $(($RANDOM % 1024 + 1025))