import logging
import os

# Erstelle Testdateien mit identischem Inhalt
with open('file1.txt', 'w') as f:
    f.write('Testinhalt fuer Datei 1')

with open('file1_duplicate.txt', 'w') as f:
    f.write('Testinhalt fuer Datei 1')

with open('file1_duplicate2.txt', 'w') as f:
    f.write('Testinhalt fuer Datei 1')

# Erstelle eine Datei mit anderem Inhalt
with open('file2.txt', 'w') as f:
    f.write('Anderer Inhalt')

# Erstelle Dateien mit gleichem Inhalt
with open('same_content1.txt', 'w') as f:
    f.write('Gleicher Inhalt')

with open('same_content2.txt', 'w') as f:
    f.write('Gleicher Inhalt')

# Erstelle eine Datei mit gleichem Inhalt wie file1.txt
with open('same_content_as_file1.txt', 'w') as f:
    f.write('Testinhalt fuer Datei 1')

print('Testdateien erstellt.')