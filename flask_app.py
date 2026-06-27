from flask import Flask, jsonify
import json
app = Flask(__name__)

@app.route('/values')
def get_values():
    with open('/root/local_agent/agent_workspace/values.json', 'r') as f:
        values = json.load(f)
    return jsonify(values)

if __name__ == '__main__':
    app.run(debug=True)