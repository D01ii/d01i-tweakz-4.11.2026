#!/usr/bin/env python3
"""Uruchamia lokalna instancje PostgreSQL (pgserver) tylko do testow w sandboxie.
Wypisuje DATABASE_URL i utrzymuje proces przy zyciu."""
import sys
import pgserver

data_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/d01i-pgdata"
srv = pgserver.get_server(data_dir)
print("DATABASE_URL=postgresql://postgres@/postgres?host=" + data_dir, flush=True)
print("READY", flush=True)
# utrzymuj przy zyciu
try:
    import time
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    pass
