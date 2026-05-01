#!/usr/bin/env python3
"""Tiny CGI host for git-http-backend, used by zigit's parity tests.

Listens on 127.0.0.1:<port> and exposes the bare git repo whose path
is in env GIT_PROJECT_ROOT to git's smart-HTTP backend. Supports
push (write access) by setting GIT_HTTP_EXPORT_ALL + http.receivepack.

Usage:
    GIT_PROJECT_ROOT=/path/to/bare-repo \\
    GIT_HTTP_BACKEND=/path/to/git-http-backend \\
        python3 git_http_server.py 7771

Prints "ready" once the server is up so callers can wait on it.
"""
import os
import sys
import select
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BACKEND = os.environ["GIT_HTTP_BACKEND"]
PROJECT_ROOT = os.environ["GIT_PROJECT_ROOT"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._run_cgi()

    def do_POST(self):
        self._run_cgi()

    def log_message(self, fmt, *args):  # silence access log
        pass

    def _run_cgi(self):
        # Strip the repo path from the URL — git-http-backend wants
        # PATH_INFO to be the part *after* the repo name, e.g.
        # /repo.git/info/refs?service=... → PATH_INFO=/info/refs
        # and GIT_PROJECT_ROOT=/path. We host a single repo at /, so
        # PATH_INFO is just the path.
        path = self.path
        query = ""
        if "?" in path:
            path, query = path.split("?", 1)

        env = {
            **os.environ,
            "GIT_HTTP_EXPORT_ALL": "1",
            "GIT_PROJECT_ROOT": PROJECT_ROOT,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": self.headers.get("Content-Length", "0"),
            "REMOTE_ADDR": self.client_address[0],
            "SERVER_PROTOCOL": "HTTP/1.0",
            "GATEWAY_INTERFACE": "CGI/1.1",
            "HTTP_GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
            "HTTP_AUTHORIZATION": self.headers.get("Authorization", ""),
        }

        body = b""
        cl = int(self.headers.get("Content-Length", "0") or "0")
        if cl > 0:
            body = self.rfile.read(cl)

        proc = subprocess.Popen(
            [BACKEND],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        out, err = proc.communicate(body, timeout=60)

        # git-http-backend prints CGI-style headers + blank line + body.
        sep = out.find(b"\r\n\r\n")
        if sep < 0:
            sep = out.find(b"\n\n")
            sep_len = 2
        else:
            sep_len = 4
        if sep < 0:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"backend gave no headers\n")
            self.wfile.write(err)
            return

        header_text = out[:sep].decode("latin-1")
        body_bytes = out[sep + sep_len :]
        status = "200 OK"
        cgi_headers = []
        for line in header_text.split("\n"):
            line = line.rstrip("\r")
            if not line:
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                if k.strip().lower() == "status":
                    status = v.strip()
                else:
                    cgi_headers.append((k.strip(), v.strip()))

        # Send the response line manually so we control the status code.
        code, _, reason = status.partition(" ")
        self.send_response_only(int(code), reason)
        for k, v in cgi_headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    bound = server.server_address[1]
    print(f"ready {bound}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
