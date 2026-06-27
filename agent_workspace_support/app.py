from flask import Flask, render_template
import json
app = Flask(__name__)

@app.route('/')
def index():
    with open('/root/local_agent/agent_workspace_support/json_data.json', 'r') as f:
        json_data = json.load(f)
    return render_template('index.html', json_data=json_data)
if __name__ == '__main__':
    app.run(debug=True)