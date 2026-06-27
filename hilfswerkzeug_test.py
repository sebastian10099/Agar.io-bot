#!/usr/bin/env python3
import hilfswerkzeug

def test_update_documentation():
    assert 'Hilfswerkzeug verfügbar.' in hilfswerkzeug.update_documentation()
if __name__ == '__main__':
    test_update_documentation()