#!/usr/bin/env python3
"""Minimal mock of the GitHub REST API pieces used by this repository.

The tests start this server once, reset its state between cases and let the
shell scripts talk to it through GITHUB_API_URL. It only implements the
endpoints the scripts actually call, which keeps the tests hermetic (no
network, no credentials, no rate limits).

Control endpoints (not part of GitHub's API):
  POST /__reset  Replace the state. Body: JSON object merged into defaults.
  GET  /__state  Return the current state, including recorded dispatches.

Fault injection: set "faults" to a list of
  {"pattern": "<substring>", "status": 500, "times": 1}
Each entry answers the next matching request with that HTTP status and is then
decremented, which lets tests exercise the retry logic.

Usage:
  python mock_github.py --port-file port.txt
"""
import argparse
import copy
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_STATE = {
    "workflow": {"id": 4242},
    "jobs": [{"name": "runner", "status": "completed", "conclusion": "success"}],
    "runs": [],
    "runners": [],
    "registration_token": "mock-registration-token",
    "dispatches": [],
    "deletes": [],
    "faults": [],
}

STATE = copy.deepcopy(DEFAULT_STATE)
LOCK = threading.Lock()

RE_WORKFLOW = re.compile(r"^/repos/([^/]+/[^/]+)/actions/workflows/([^/]+)$")
RE_JOBS = re.compile(r"^/repos/([^/]+/[^/]+)/actions/runs/(\d+)/jobs$")
RE_RUNS = re.compile(r"^/repos/([^/]+/[^/]+)/actions/workflows/([^/]+)/runs$")
RE_DISPATCH = re.compile(r"^/repos/([^/]+/[^/]+)/actions/workflows/(\d+)/dispatches$")
RE_REG = re.compile(r"^/orgs/([^/]+)/actions/runners/registration-token$")
RE_RUNNERS = re.compile(r"^/orgs/([^/]+)/actions/runners$")
RE_RUNNER = re.compile(r"^/orgs/([^/]+)/actions/runners/(\d+)$")


def take_fault(method, path):
    with LOCK:
        for fault in STATE["faults"]:
            if fault.get("times", 0) <= 0:
                continue
            if fault.get("method") and fault["method"] != method:
                continue
            if fault["pattern"] in path:
                fault["times"] -= 1
                return fault.get("status", 500)
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "MockGitHub/1.0"

    def log_message(self, fmt, *args):  # keep the test output readable
        pass

    def _send(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_DELETE(self):
        self._handle("DELETE")

    def _handle(self, method):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
        fault = take_fault(method, path)
        if fault is not None:
            return self._send(fault, {"message": "injected failure"})

        if method == "GET" and path == "/__state":
            with LOCK:
                return self._send(200, copy.deepcopy(STATE))
        if method == "POST" and path == "/__reset":
            body = self._read_json()
            with LOCK:
                STATE.clear()
                STATE.update(copy.deepcopy(DEFAULT_STATE))
                STATE.update(body)
            return self._send(204)

        if method == "GET":
            match = RE_WORKFLOW.match(path)
            if match:
                with LOCK:
                    workflow = copy.deepcopy(STATE["workflow"])
                if not workflow:
                    return self._send(404, {"message": "Not Found"})
                return self._send(200, workflow)

            match = RE_JOBS.match(path)
            if match:
                with LOCK:
                    jobs = copy.deepcopy(STATE["jobs"])
                return self._send(200, {"total_count": len(jobs), "jobs": jobs})

            match = RE_RUNS.match(path)
            if match:
                with LOCK:
                    runs = copy.deepcopy(STATE["runs"])
                return self._send(200, {"total_count": len(runs), "workflow_runs": runs})

            match = RE_RUNNERS.match(path)
            if match:
                per_page = int(query.get("per_page", ["30"])[0])
                page = int(query.get("page", ["1"])[0])
                with LOCK:
                    runners = copy.deepcopy(STATE["runners"])
                start = (page - 1) * per_page
                return self._send(200, {
                    "total_count": len(runners),
                    "runners": runners[start:start + per_page],
                })

        if method == "POST":
            match = RE_DISPATCH.match(path)
            if match:
                body = self._read_json()
                with LOCK:
                    STATE["dispatches"].append({"workflow_id": int(match.group(2)), "body": body})
                return self._send(204)

            if RE_REG.match(path):
                with LOCK:
                    token = STATE["registration_token"]
                if not token:
                    return self._send(403, {"message": "Resource not accessible by integration"})
                return self._send(201, {"token": token})

        if method == "DELETE":
            match = RE_RUNNER.match(path)
            if match:
                runner_id = int(match.group(2))
                with LOCK:
                    before = len(STATE["runners"])
                    STATE["runners"] = [r for r in STATE["runners"] if r.get("id") != runner_id]
                    removed = len(STATE["runners"]) != before
                    STATE["deletes"].append(runner_id)
                if not removed:
                    return self._send(404, {"message": "Not Found"})
                return self._send(204)

        return self._send(404, {"message": "Not Found", "path": path})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
