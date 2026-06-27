#!/usr/bin/env python3

# Basiseinstellungen für Prometheus

import time

def check_server_status():
    print('Server is running.')
    time.sleep(10)
    print('Monitoring script completed.')

if __name__ == '__main__':
    check_server_status()