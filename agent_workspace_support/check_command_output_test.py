import sys
from subprocess import check_output

def test_check_command(command):
    expected_output = 'Expected output'
    result = check_output(['bash', '-c', command])
    return expected_output == str(result.decode('utf-8'))