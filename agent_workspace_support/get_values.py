from flask import Flask, jsonify
import os
import get_values

app = Flask(__name__)

@app.route('/values')
def values():
    agent_values = get_values.values()
    return jsonify(agent_values)