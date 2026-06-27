import time
from flask import Flask
timeout = 10
app = Flask(__name__)
@app.route('/')
def hello_world():
    return 'Hello, World!'