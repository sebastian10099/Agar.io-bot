import flask
from flask import Flask
app = Flask(__name__)
@app.route('/status', methods=['GET'])
def status():
    return 'Status OK'
if __name__ == '__main__':
    app.run(debug=True)