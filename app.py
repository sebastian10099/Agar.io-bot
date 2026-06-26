from flask import Flask, jsonify
app = Flask(__name__)

@app.route('/read_value', methods=['GET'])
def read_value():
    return jsonify({'value': 'initial value'})

if __name__ == '__main__':
    app.run(host='0.0.0.0')