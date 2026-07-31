#!/usr/bin/env python3
"""
Hivemind VPN Session Manager — thin entry point.

The full implementation lives in the ``hivemind/`` package.
This file exists for backward compatibility with the systemd service unit
and for direct ``python server_hivemind_5_0.py`` runs.

gunicorn (production)::

    gunicorn -w 1 --threads 8 -b 127.0.0.1:5000 hivemind.main:app

See ``hivemind/config.py`` for all tunables.
"""

from hivemind.main import app, start_management

# The management daemon starts automatically when gunicorn imports
# hivemind.main:app.  For direct runs (python server_hivemind_5_0.py),
# we call start_management() explicitly.  It's idempotent — safe to
# call even if the import-time start already fired.
start_management()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
