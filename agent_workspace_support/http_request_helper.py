import requests

def send_http_request(url, method='GET', **kwargs):
    response = requests.request(method=method, url=url, **kwargs)
    return response.status_code