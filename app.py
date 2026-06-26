#!/usr/bin/env python3
from flask import Flask, jsonify
import json
import os

def get_values_from_json(json_path):
    with open(json_path, 'r') as file:
        return json.load(file)

app = Flask(__name__)

@app.route('/values', methods=['GET'])
def values():
    json_path = '/root/local_agent/agent_workspace/values.json'
    values_dict = get_values_from_json(json_path)
    return jsonify(values_dict)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001) 
