from flask import Flask
app = Flask(__name__)

def show_json_values(json_data):
    return json.dumps(json_data, indent=2)

@app.route('/json-values')
def get_json_values():
    return show_json_values({'key': 'value'})