#!/usr/bin/env bash
set -euo pipefail
curl -s http://127.0.0.1:8080/health; echo
curl -s http://127.0.0.1:8080/v1/admin/summary; echo
curl -s http://127.0.0.1:8080/v1/admin/indexes; echo
curl -s http://127.0.0.1:8080/v1/orders/O-1001; echo
curl -s 'http://127.0.0.1:8080/v1/customers/C001/orders'; echo
curl -s 'http://127.0.0.1:8080/v1/orders/pending?from=2026-06-01T00:00:00Z&to=2026-06-08T00:00:00Z'; echo
curl -s 'http://127.0.0.1:8080/v1/products/low-stock?warehouseId=W-A'; echo
