
from flask import Flask
app = Flask(__name__)
@app.route('/')
def hello_world():
    return 'PROMETHEUS JSON-Werte anzeigen'
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001) # Ändere den Port