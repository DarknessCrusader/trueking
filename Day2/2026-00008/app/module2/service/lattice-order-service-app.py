#!/usr/bin/env python3
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_NAME = "order-service"
PORT = int(os.environ.get("SERVICE_PORT", "8080"))

ORDERS = {
    "1001": {"item": "skills-ticket", "quantity": 1},
    "1002": {"item": "cloud-lab-pass", "quantity": 2},
    "1003": {"item": "network-workshop", "quantity": 1},
}


def response_body(payload):
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "SkillsLatticeOrderService/1.0"

    def log_message(self, fmt, *args):
        print(json.dumps({
            "time": datetime.now(timezone.utc).isoformat(),
            "client": self.client_address[0],
            "request": self.requestline,
            "message": fmt % args,
        }, ensure_ascii=False), flush=True)

    def send_json(self, status, payload):
        body = response_body(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(200, {
                "app": APP_NAME,
                "status": "ok",
                "hostname": socket.gethostname(),
                "via": "vpc-lattice-target",
            })
            return

        if parsed.path == "/v1/orders":
            query = parse_qs(parsed.query)
            order_id = query.get("id", ["1001"])[0]
            order = ORDERS.get(order_id, {"item": "unknown", "quantity": 0})
            self.send_json(200, {
                "app": APP_NAME,
                "status": "ok",
                "order_id": order_id,
                "item": order["item"],
                "quantity": order["quantity"],
                "via": "vpc-lattice",
                "hostname": socket.gethostname(),
            })
            return

        if parsed.path == "/":
            self.send_json(200, {
                "app": APP_NAME,
                "status": "ok",
                "message": "use /v1/orders?id=1001",
            })
            return

        self.send_json(404, {"app": APP_NAME, "status": "not_found", "path": parsed.path})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(json.dumps({"app": APP_NAME, "status": "listening", "port": PORT}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
