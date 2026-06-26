#!/usr/bin/env python3
from flask import Flask, jsonify
from scripts.create_flask_app import app as flask_app
if __name__ == '__main__':
    flask_app.run(host='0.0.0.0', port=5000)