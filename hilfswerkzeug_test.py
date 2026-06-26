import os

def read_and_print(filename):
    with open(filename, 'r') as file:
        print(file.read())

if __name__ == '__main__':
    read_and_print('/root/local_agent/agent_workspace/hilfswerkzeug_test.py')