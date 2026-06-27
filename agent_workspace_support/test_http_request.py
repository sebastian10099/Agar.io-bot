import http_request_helper

def test_functionality():
    response = http_request_helper.send_http_request('http://httpbin.org/get')
    print(f'Response Status Code: {response}')