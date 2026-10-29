# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# A stub git server for tests/tacplus.test.sh: an HTTPS proxy that answers
# every CONNECT itself (TLS with the test CA's certificate for any host), so
# https://github.com/... and any other host reach it without network. Each
# host requires HTTP Basic auth and serves the bare repositories under
# <root>/<host>/ through `git http-backend`. Every request is logged to <log>
# as "<host> <user:password>", or "<host> -" when it carried no credential.
# With a <writers> file (one password per line), only those passwords may push,
# as GitHub refuses a push with a read-only token: any other gets 403 and the
# log line "<host> <user:password> push refused".
# Prints its port on stdout once listening.
# Run: python3 -I git-server.py <root> <cert.pem> <key.pem> <log> [<writers>]
import base64
import http.server
import os
import socket
import socketserver
import ssl
import subprocess
import sys
import threading

root, cert, key, logpath = sys.argv[1:5]
writers = sys.argv[5] if len(sys.argv) > 5 else None
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(cert, key)
lock = threading.Lock()


def log(line):
    with lock, open(logpath, "a") as f:
        f.write(line + "\n")


class Git(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def handle_git(self):
        host = self.server_host
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            log(f"{host} -")
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="stub"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        cred = base64.b64decode(auth[6:]).decode()
        path, _, query = self.path.partition("?")
        if writers and ("service=git-receive-pack" in query or path.endswith("/git-receive-pack")):
            with open(writers) as f:
                allowed = f.read().split()
            if cred.partition(":")[2] not in allowed:
                log(f"{host} {cred} push refused")
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        log(f"{host} {cred}")
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        env = {
            "PATH": os.environ["PATH"],
            "GIT_PROJECT_ROOT": os.path.join(root, host),
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""),
            "REMOTE_USER": cred.split(":")[0],
        }
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        headers = [h.split(":", 1) for h in head.decode().split("\r\n") if ":" in h]
        status = next((v.strip() for k, v in headers if k.lower() == "status"), "200 OK")
        self.send_response(int(status.split()[0]))
        for k, v in headers:
            if k.lower() != "status":
                self.send_header(k, v.strip())
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)

    do_GET = do_POST = handle_git


class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode()
        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
            pass
        method, target, _ = line.split()
        if method != "CONNECT":
            self.wfile.write(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            return
        self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        self.wfile.flush()
        conn = tls.wrap_socket(self.connection, server_side=True)
        handler = Git.__new__(Git)
        handler.server_host = target.rsplit(":", 1)[0]
        Git.__init__(handler, conn, self.client_address, self.server)


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", 0), Proxy)
print(srv.server_address[1], flush=True)
srv.serve_forever()
