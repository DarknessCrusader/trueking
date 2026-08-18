#!/usr/bin/env bash
set -euo pipefail
curl -s -X POST http://127.0.0.1:8080/v1/admin/seed; echo
