#!/usr/bin/env python3
from flask import Flask, jsonify
app = Flask(__name__)

@app.route('/json_values', methods=['GET'])
def get_json_values():
    return jsonify({'workspace': '/root/local_agent/agent_workspace'})
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)