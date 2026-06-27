

def test_flask_app():
    import requests
    response = requests.get('http://127.0.0.1:5000/api/data')
    assert response.status_code == 200
    assert 'example_data' in response.json()
