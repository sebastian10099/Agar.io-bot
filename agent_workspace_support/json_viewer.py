
from flask import Flask, jsonify
import json
app = Flask(__name__)
with open('/var/log/some_log.json', 'r') as file:
    log_data = json.load(file)
@app.route('/')
def home():
    return jsonify(log_data)