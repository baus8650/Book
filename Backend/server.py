"""Read-only catalog gateway. Run behind an HTTPS reverse proxy."""
import datetime
import json
import os
import re
import time
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SOURCE = (Path(__file__).resolve().parent.parent / 'NextChapter/HardcoverService.swift').read_text()
QUERIES = {re.sub(r'\s+', ' ', q).strip() for q in re.findall(r'"""(.*?)"""', SOURCE, re.S)}
TOKEN = os.environ.get('HARDCOVER_API_TOKEN', '').removeprefix('Bearer ').strip()
if not TOKEN:
    raise SystemExit('Configure HARDCOVER_API_TOKEN on the server before starting.')
CACHE = {}
LOCK = threading.Lock()
LAST_REQUEST = 0.0


def validate(body):
    query, variables = body.get('query'), body.get('variables', {})
    if not isinstance(query, str) or re.sub(r'\s+', ' ', query).strip() not in QUERIES:
        raise ValueError('Unsupported catalog query')
    if not isinstance(variables, dict):
        raise ValueError('Invalid variables')
    expected = set(re.findall(r'\$(\w+)\s*:', query))
    if set(variables) != expected:
        raise ValueError('Invalid variables')
    for key, value in variables.items():
        if key == 'term' and (not isinstance(value, str) or not 1 <= len(value.strip()) <= 200):
            raise ValueError('Invalid search term')
        if key == 'ids' and (not isinstance(value, list) or not 1 <= len(value) <= 20 or any(type(v) is not int or v <= 0 for v in value)):
            raise ValueError('Invalid IDs')
        if key == 'author' and (type(value) is not int or value <= 0):
            raise ValueError('Invalid author')
        if key == 'offset' and (type(value) is not int or not 0 <= value <= 10000):
            raise ValueError('Invalid offset')
        if key == 'today' and value != datetime.date.today().isoformat():
            # Devices may be one calendar day ahead or behind the server.
            if not isinstance(value, str) or value not in {(datetime.date.today() + datetime.timedelta(days=d)).isoformat() for d in [-1, 1]}:
                raise ValueError('Invalid date')
    return {'query': query, 'variables': variables}


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, data):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global LAST_REQUEST
        if self.path != '/catalog':
            self.respond(404, b'{}'); return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 16384:
                raise ValueError('Invalid body length')
            body = validate(json.loads(self.rfile.read(length)))
            key = json.dumps(body, sort_keys=True).encode()
        except (ValueError, TypeError, AttributeError):
            self.respond(400, b'{}'); return
        with LOCK:
            now = time.monotonic()
            cached = CACHE.get(key)
            if cached and now - cached[0] < 900:
                self.respond(200, cached[1]); return
            if now - LAST_REQUEST < 1.1:
                self.respond(429, b'{}'); return
            LAST_REQUEST = now
            request = urllib.request.Request('https://api.hardcover.app/v1/graphql', data=key,
                headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'}, method='POST')
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
                if len(CACHE) >= 1000:
                    CACHE.clear()
                CACHE[key] = (now, data)
                self.respond(200, data)
            except urllib.error.HTTPError as error:
                self.respond(error.code, b'{}')
            except (urllib.error.URLError, TimeoutError):
                self.respond(502, b'{}')

    def log_message(self, format, *args):
        pass  # Never log credentials, request bodies, or reader searches.


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('PORT', '8080'))), Handler).serve_forever()
