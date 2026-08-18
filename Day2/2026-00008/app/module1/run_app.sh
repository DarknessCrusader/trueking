#!/usr/bin/env bash
set -euo pipefail
cd /opt/skills-nosql
exec /opt/skills-nosql/.venv/bin/python /opt/skills-nosql/docdb_client.py serve
