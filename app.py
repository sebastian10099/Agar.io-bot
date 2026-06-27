from flask import Flask, jsonify
app = Flask(__name__)
@app.route("/")
def hello_world():
    with open("data.json", "r") as f:
        data = json.load(f)
    return jsonify(data)
