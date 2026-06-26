from flask import Flask
app = Flask(__name__)

@app.route('/data')
def get_data():
    return {'message': 'Data fetched successfully'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001, debug=True)