#!/usr/bin/env python
from flask import Flask
app = Flask(__name__)
@app.route('/port_check', methods=['GET'])
def port_check():
    return 'Port 8085 is open and accessible.'