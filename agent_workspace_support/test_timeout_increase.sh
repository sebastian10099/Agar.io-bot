#!/bin/bash
cp /path/to/original/code /tmp
sed -i 's/^TIMEOUT_VALUE=90$/TIMEOUT_VALUE=180/' /tmp/code
mv /tmp/code /path/to/code
/path/to/code --help | grep TIMEOUT_VALUE