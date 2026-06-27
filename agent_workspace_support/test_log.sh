
#!/bin/bash
curl -X POST http://example.com/success --data-binary "timeout=0.5 test=true" && curl -X POST http://example.com/failure --data-binary "timeout=0.5 test=false"