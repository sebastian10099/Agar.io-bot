from flask_app import app
test = app.test_client()
print(test.get('/')())