import json
from flask import Flask, render_template

app = Flask(__name__)

def load_json_values():
    with open('/root/local_agent/agent_workspace_support/data.json', 'r') as file:
        return json.load(file)

@app.route('/')
def index():
    json_values = load_json_values()
    return render_template('flask_dashboard.html', values=json_values)

if __name__ == '__main__':
    app.run(debug=True)