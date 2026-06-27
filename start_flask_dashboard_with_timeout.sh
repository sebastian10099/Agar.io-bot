#!/bin/bash
FLASK_APP=app.py
timeout 180 flask run --host=0.0.0.0 --port=5005