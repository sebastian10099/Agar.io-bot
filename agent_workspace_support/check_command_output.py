import sys
import subprocess

def check_command(command):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    output, error = process.communicate()
    return {'output': output.decode(), 'error': error.decode()}

# Funktion um die Kommandoausgabe zu testen
def run_and_check(command):
    result = check_command(command)
    if result['error']:
        print(f'Error: {result[