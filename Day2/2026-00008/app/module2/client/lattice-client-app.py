#!/usr/bin/env python3
import json
import os
import socket
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import Request, urlopen

APP_NAME = "client"
PORT = int(os.environ.get("CLIENT_PORT", "80"))
SERVICE_URL = os.environ.get("SERVICE_URL", "").rstrip("/")
TIMEOUT = float(os.environ.get("SERVICE_TIMEOUT", "3"))


def response_body(payload):
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def valid_service_url():
    return SERVICE_URL.startswith("http://") or SERVICE_URL.startswith("https://")


class Handler(BaseHTTPRequestHandler):
    server_version = "SkillsLatticeClient/1.0"

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
                "service_url_configured": valid_service_url(),
            })
            return

        if parsed.path == "/" or parsed.path == "/v1/client/orders":
            query = parse_qs(parsed.query)
            order_id = query.get("id", ["1001"])[0]
            self.call_order_service(order_id)
            return

        self.send_json(404, {"app": APP_NAME, "status": "not_found", "path": parsed.path})

    def call_order_service(self, order_id):
        if not valid_service_url():
            self.send_json(502, {
                "app": APP_NAME,
                "status": "service_url_not_configured",
                "service_url_configured": False,
            })
            return

        url = f"{SERVICE_URL}/v1/orders?id={quote(order_id)}"
        req = Request(url, headers={"User-Agent": "skills-lattice-client/1.0"})
        try:
            with urlopen(req, timeout=TIMEOUT) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.getcode()
            try:
                service_payload = json.loads(raw)
            except json.JSONDecodeError:
                service_payload = {"raw": raw}
            self.send_json(200, {
                "app": APP_NAME,
                "status": "ok",
                "hostname": socket.gethostname(),
                "service_url": SERVICE_URL,
                "service_http_status": status,
                "service": service_payload,
            })
        except HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            self.send_json(502, {
                "app": APP_NAME,
                "status": "service_http_error",
                "service_url": SERVICE_URL,
                "service_http_status": e.code,
                "error": body,
            })
        except URLError as e:
            self.send_json(502, {
                "app": APP_NAME,
                "status": "service_url_error",
                "service_url": SERVICE_URL,
                "error": str(e.reason),
            })
        except TimeoutError:
            self.send_json(504, {
                "app": APP_NAME,
                "status": "service_timeout",
                "service_url": SERVICE_URL,
            })


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(json.dumps({
        "app": APP_NAME,
        "status": "listening",
        "port": PORT,
        "service_url_configured": valid_service_url(),
    }), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
