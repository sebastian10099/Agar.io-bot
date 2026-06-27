from flask import Flask, jsonify
app = Flask(__name__)

def get_json_data():
    return {
        'key1': 'value1',
        'key2': 'value2'
    }

@app.route('/data')
def data_route():
    json_data = get_json_data()
    return jsonify(json_data)
if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5001)