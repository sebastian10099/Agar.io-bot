from flask import Flask
app = Flask(__name__)

def run_with_retries(fn, retries=3):
    for _ in range(retries):
        try:
            result = fn()
            return result
        except Exception as e:
            print(f'Retry {retries - _} failed: {e}')
    raise Exception('All retries failed')

@app.route('/health', methods=['GET'])
def health_check():
    return run_with_retries(lambda: app.config['TIMEOUT'] == 10)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5006, debug=True)