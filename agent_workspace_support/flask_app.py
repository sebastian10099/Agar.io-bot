from flask import Flask, render_template
import config

timeout = config.timeout

app = Flask(__name__)
@app.route('/')
def home():
    return render_template('index.html', timeout=timeout)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5005, debug=True, timeout=timeout)