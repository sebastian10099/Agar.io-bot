import requests

def check_http_request(url):
    try:
        response = requests.get(url)
        response.raise_for_status()
        return True, None  # Kein Fehler gefunden
    except requests.RequestException as e:
        return False, str(e)  # Fehlernachricht