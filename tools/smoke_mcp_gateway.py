#!/usr/bin/env python3
"""Smoke test the Project Atlas HTTP MCP gateway."""

from __future__ import annotations

import argparse
import http.server
import importlib.util
import json
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from types import ModuleType
from typing import Any


ALLOWED_TOOLS = {
    "list_projects",
    "get_project_status",
    "atlas.workload_snapshot",
}

DENIED_TOOL_PROBES = {
    "enqueue_llm_task",
    "claim_llm_task",
    "complete_llm_task",
    "fail_llm_task",
    "propose_status_change",
    "propose_task_update",
    "propose_manifest_update",
    "record_validation_run",
    "record_handoff",
    "propose_closeout",
    "get_project_brief",
    "atlas.work_item_context_bundle",
    "list_agent_proposals",
    "list_llm_tasks",
    "get_llm_task",
    "run_project_enrichment",
    "refresh_github_remote_status",
}

SENSITIVE_TEXT_PATTERNS = {
    "windows_path": re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:[\\/](?!\")"),
    "file_uri": re.compile(r"file:///[A-Za-z]:/", re.IGNORECASE),
    "email": re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    "owner_name": re.compile(r"\bPaul\s+Peck\b", re.IGNORECASE),
}

HTTP_TIMEOUT_SECONDS = 75
OAUTH_SCOPE = "atlas.read"
OAUTH_SMOKE_TOKEN = "atlas-oauth-smoke-token"

SENSITIVE_FIXTURE = {
    "result": {
        "content": [
            {
                "type": "text",
                "text": (
                    "Manual fixture from B:\\Projects\\LLM_Modules\\Project_Ops_Capsule "
                    "owned by Paul Peck at atlas.owner@example.com."
                ),
            }
        ],
        "draftText": "DRAFT_FIXTURE_SHOULD_NOT_LEAK",
        "proposalBody": "PROPOSAL_BODY_FIXTURE_SHOULD_NOT_LEAK",
        "queueContext": {
            "repoPath": "B:\\dev\\Project_Atlas\\project-atlas-main",
            "detail": "QUEUE_CONTEXT_FIXTURE_SHOULD_NOT_LEAK",
        },
    }
}

SENSITIVE_FIXTURE_FORBIDDEN = {
    "B:",
    "Project_Ops_Capsule",
    "project-atlas-main",
    "atlas.owner@example.com",
    "Paul Peck",
    "DRAFT_FIXTURE_SHOULD_NOT_LEAK",
    "PROPOSAL_BODY_FIXTURE_SHOULD_NOT_LEAK",
    "QUEUE_CONTEXT_FIXTURE_SHOULD_NOT_LEAK",
}

SENSITIVE_FIXTURE_REQUIRED_REDACTIONS = {
    "[redacted:path]",
    "[redacted:email]",
    "[redacted:person]",
    "[redacted:private-context]",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_exe_path() -> Path:
    return (
        repo_root()
        / "build"
        / "windows"
        / "x64"
        / "runner"
        / "Release"
        / "project_atlas.exe"
    )


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request_json(
    url: str,
    payload: dict[str, Any] | None = None,
    token: str | None = None,
) -> tuple[int, Any]:
    status, body, _headers = request_json_with_headers(url, payload, token)
    return status, body


def request_json_with_headers(
    url: str,
    payload: dict[str, Any] | None = None,
    token: str | None = None,
) -> tuple[int, Any, dict[str, str]]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload is not None else "GET")
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8")
            headers_out = {key.lower(): value for key, value in response.headers.items()}
            return int(response.status), json.loads(body) if body else None, headers_out
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        headers_out = {key.lower(): value for key, value in error.headers.items()}
        return int(error.code), json.loads(body) if body else None, headers_out


def request_raw(
    url: str,
    token: str | None = None,
) -> tuple[int, str, dict[str, str]]:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            headers_out = {key.lower(): value for key, value in response.headers.items()}
            if "text/event-stream" in headers_out.get("content-type", ""):
                body = response.readline().decode("utf-8")
                body += response.readline().decode("utf-8")
            else:
                body = response.read().decode("utf-8")
            return int(response.status), body, headers_out
    except urllib.error.HTTPError as error:
        headers_out = {key.lower(): value for key, value in error.headers.items()}
        return int(error.code), error.read().decode("utf-8"), headers_out


def rpc(method: str, request_id: int, params: dict[str, Any] | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    return message


def wait_for_health(base_url: str) -> None:
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            status, body = request_json(f"{base_url}/healthz")
            if status == 200 and body.get("status") == "ok":
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError("gateway did not become healthy")


def stdio_tool_names(exe: Path) -> set[str]:
    payload = [
        {"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        {"jsonrpc": "2.0", "id": "tools", "method": "tools/list", "params": {}},
    ]
    proc = subprocess.run(
        [str(exe), "--mcp-stdio"],
        input="\n".join(json.dumps(item) for item in payload) + "\n",
        text=True,
        capture_output=True,
        timeout=45,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"stdio tools/list failed: {proc.stderr.strip()[:2000]}")
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        decoded = json.loads(line)
        if decoded.get("id") == "tools":
            return {
                str(tool.get("name"))
                for tool in decoded.get("result", {}).get("tools", [])
                if isinstance(tool, dict) and tool.get("name")
            }
    raise RuntimeError("stdio tools/list did not return a tools response")


def load_gateway_module(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("atlas_mcp_gateway_under_test", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load gateway module: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_no_sensitive_payload(label: str, payload: Any) -> None:
    encoded = json.dumps(payload, sort_keys=True)
    for name, pattern in SENSITIVE_TEXT_PATTERNS.items():
        if pattern.search(encoded):
            raise AssertionError(f"{label} leaked {name}: {encoded[:1200]}")
    for private_key in ("draftText", "proposalBody", "queueContext", "unresolvedBody"):
        if private_key in encoded and "[redacted:" not in encoded:
            raise AssertionError(f"{label} leaked unredacted {private_key}: {encoded[:1200]}")


def assert_gateway_redaction_self_test(gateway_module: ModuleType) -> None:
    redacted = gateway_module.redact_gateway_payload(SENSITIVE_FIXTURE)
    assert_no_sensitive_payload("gateway redaction self-test", redacted)
    encoded = json.dumps(redacted, sort_keys=True)
    leaked = sorted(value for value in SENSITIVE_FIXTURE_FORBIDDEN if value in encoded)
    if leaked:
        raise AssertionError(f"redaction fixture leaked sensitive values: {leaked}")
    missing = sorted(
        value for value in SENSITIVE_FIXTURE_REQUIRED_REDACTIONS if value not in encoded
    )
    if missing:
        raise AssertionError(f"redaction fixture missing masks: {missing}")
    if "[redacted:" not in encoded:
        raise AssertionError(f"redaction self-test did not redact payload: {redacted}")


def assert_denied_tool(
    base_url: str,
    token: str,
    request_id: int,
    name: str,
) -> None:
    try:
        status, denied = request_json(
            f"{base_url}/mcp",
            rpc("tools/call", request_id, {"name": name, "arguments": {}}),
            token=token,
        )
    except TimeoutError as error:
        raise AssertionError(f"denied tool {name} timed out") from error
    if status != 200 or "error" not in denied:
        raise AssertionError(f"denied tool {name} was not rejected: {status} {denied}")


class OAuthIntrospectionHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(length).decode("utf-8")
        params = urllib.parse.parse_qs(body)
        token = params.get("token", [""])[0]
        if token == self.server.expected_token:  # type: ignore[attr-defined]
            payload = {
                "active": True,
                "scope": self.server.scope,  # type: ignore[attr-defined]
                "aud": self.server.resource_url,  # type: ignore[attr-defined]
            }
        else:
            payload = {"active": False}
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


class OAuthIntrospectionServer(http.server.ThreadingHTTPServer):
    expected_token: str
    resource_url: str
    scope: str


def run_oauth_gateway_smoke(args: argparse.Namespace, all_stdio_tools: set[str]) -> dict[str, Any]:
    auth_server = OAuthIntrospectionServer(("127.0.0.1", 0), OAuthIntrospectionHandler)
    auth_server.expected_token = OAUTH_SMOKE_TOKEN
    auth_server.scope = OAUTH_SCOPE
    auth_port = int(auth_server.server_address[1])
    auth_base = f"http://127.0.0.1:{auth_port}"
    auth_thread = threading.Thread(target=auth_server.serve_forever, daemon=True)
    auth_thread.start()

    port = free_port()
    base_url = f"http://{args.host}:{port}"
    auth_server.resource_url = base_url
    proc = subprocess.Popen(
        [
            sys.executable,
            str(args.gateway),
            "--host",
            args.host,
            "--port",
            str(port),
            "--exe",
            str(args.exe),
            "--auth-mode",
            "oauth",
            "--resource-url",
            base_url,
            "--authorization-server",
            auth_base,
            "--introspection-url",
            f"{auth_base}/introspect",
            "--scope",
            OAUTH_SCOPE,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_health(base_url)

        status, metadata = request_json(f"{base_url}/.well-known/oauth-protected-resource")
        if status != 200:
            raise AssertionError(f"bad protected resource metadata status: {status} {metadata}")
        if metadata.get("resource") != base_url:
            raise AssertionError(f"bad protected resource: {metadata}")
        if metadata.get("authorization_servers") != [auth_base]:
            raise AssertionError(f"bad auth servers: {metadata}")
        if metadata.get("scopes_supported") != [OAUTH_SCOPE]:
            raise AssertionError(f"bad scopes: {metadata}")

        status, body, headers = request_json_with_headers(
            f"{base_url}/mcp",
            rpc("initialize", 201),
        )
        challenge = headers.get("www-authenticate", "")
        if status != 401 or "resource_metadata=" not in challenge or OAUTH_SCOPE not in challenge:
            raise AssertionError(f"bad oauth auth challenge: {status} {headers} {body}")

        status, body, headers = request_json_with_headers(
            f"{base_url}/mcp",
            rpc("initialize", 202),
            token="wrong-oauth-token",
        )
        if status != 401 or "www-authenticate" not in headers:
            raise AssertionError(f"bad invalid-token challenge: {status} {headers} {body}")

        status, initialize = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 203),
            token=OAUTH_SMOKE_TOKEN,
        )
        if status != 200 or initialize.get("result", {}).get("instructions") is None:
            raise AssertionError(f"bad oauth initialize: {status} {initialize}")
        assert_no_sensitive_payload("oauth initialize", initialize)

        status, tools_list = request_json(
            f"{base_url}/mcp",
            rpc("tools/list", 204, {}),
            token=OAUTH_SMOKE_TOKEN,
        )
        tool_names = {
            tool["name"] for tool in tools_list.get("result", {}).get("tools", [])
        }
        if tool_names != ALLOWED_TOOLS:
            raise AssertionError(f"unexpected oauth remote tools: {sorted(tool_names)}")
        for tool in tools_list.get("result", {}).get("tools", []):
            schemes = tool.get("securitySchemes")
            if schemes != [{"type": "oauth2", "scopes": [OAUTH_SCOPE]}]:
                raise AssertionError(f"missing oauth securitySchemes: {tool}")
        assert_no_sensitive_payload("oauth tools/list", tools_list)

        status, projects = request_json(
            f"{base_url}/mcp",
            rpc(
                "tools/call",
                205,
                {"name": "list_projects", "arguments": {"includeArchived": False}},
            ),
            token=OAUTH_SMOKE_TOKEN,
        )
        if status != 200 or projects.get("result", {}).get("isError"):
            raise AssertionError(f"oauth list_projects failed: {status} {projects}")
        assert_no_sensitive_payload("oauth list_projects", projects)

        hidden_tools = sorted(all_stdio_tools.difference(tool_names))
        assert_denied_tool(
            base_url,
            OAUTH_SMOKE_TOKEN,
            206,
            hidden_tools[0],
        )
        return {
            "tools": len(tool_names),
            "challenge": True,
            "protectedResource": True,
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        auth_server.shutdown()
        auth_server.server_close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=default_exe_path())
    parser.add_argument("--gateway", type=Path, default=repo_root() / "tools" / "atlas_mcp_gateway.py")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--token", default="atlas-smoke-token")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.exe.exists():
        raise SystemExit(f"Project Atlas executable not found: {args.exe}")
    all_stdio_tools = stdio_tool_names(args.exe)
    missing_allowed = sorted(ALLOWED_TOOLS.difference(all_stdio_tools))
    if missing_allowed:
        raise AssertionError(f"allowed tools missing from stdio server: {missing_allowed}")
    gateway_module = load_gateway_module(args.gateway)
    assert_gateway_redaction_self_test(gateway_module)

    port = args.port or free_port()
    base_url = f"http://{args.host}:{port}"
    proc = subprocess.Popen(
        [
            sys.executable,
            str(args.gateway),
            "--host",
            args.host,
            "--port",
            str(port),
            "--exe",
            str(args.exe),
            "--token",
            args.token,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_health(base_url)

        status, metadata = request_json(f"{base_url}/.well-known/project-atlas-mcp")
        if status != 200 or metadata.get("profile") != "remote_readonly":
            raise AssertionError(f"bad metadata: {status} {metadata}")
        if set(metadata.get("allowedTools", [])) != ALLOWED_TOOLS:
            raise AssertionError(f"metadata allowlist drifted: {metadata}")
        assert_no_sensitive_payload("metadata", metadata)

        status, body = request_json(f"{base_url}/mcp", rpc("initialize", 1))
        if status != 401:
            raise AssertionError(f"expected auth failure, got {status} {body}")
        status, body = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 101),
            token="wrong-token",
        )
        if status != 401:
            raise AssertionError(f"expected invalid auth failure, got {status} {body}")
        status, body, headers = request_raw(f"{base_url}/mcp", token=args.token)
        if status != 200 or "text/event-stream" not in headers.get("content-type", ""):
            raise AssertionError(f"bad GET /mcp response: {status} {headers} {body}")
        if "project-atlas gateway ready" not in body:
            raise AssertionError(f"GET /mcp did not return readiness event: {body}")

        status, initialize = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 2),
            token=args.token,
        )
        if status != 200 or initialize.get("result", {}).get("instructions") is None:
            raise AssertionError(f"bad initialize: {status} {initialize}")
        assert_no_sensitive_payload("initialize", initialize)

        status, tools_list = request_json(
            f"{base_url}/mcp",
            rpc("tools/list", 3, {}),
            token=args.token,
        )
        tool_names = {
            tool["name"] for tool in tools_list.get("result", {}).get("tools", [])
        }
        if tool_names != ALLOWED_TOOLS:
            raise AssertionError(f"unexpected remote tools: {sorted(tool_names)}")
        exposed_denied = sorted(tool_names.intersection(DENIED_TOOL_PROBES))
        if exposed_denied:
            raise AssertionError(f"denied tools exposed: {exposed_denied}")
        assert_no_sensitive_payload("tools/list", tools_list)

        status, projects = request_json(
            f"{base_url}/mcp",
            rpc(
                "tools/call",
                4,
                {"name": "list_projects", "arguments": {"includeArchived": False}},
            ),
            token=args.token,
        )
        if status != 200 or projects.get("result", {}).get("isError"):
            raise AssertionError(f"list_projects failed: {status} {projects}")
        assert_no_sensitive_payload("list_projects", projects)

        hidden_tools = sorted(all_stdio_tools.difference(tool_names))
        missing_denied_probes = sorted(DENIED_TOOL_PROBES.difference(hidden_tools))
        if missing_denied_probes:
            raise AssertionError(
                f"denied probe tools were unexpectedly exposed: {missing_denied_probes}"
            )
        for offset, hidden_tool in enumerate(hidden_tools, start=50):
            assert_denied_tool(base_url, args.token, offset, hidden_tool)

        oauth_summary = run_oauth_gateway_smoke(args, all_stdio_tools)

        print(
            json.dumps(
                {
                    "status": "ok",
                    "gateway": base_url,
                    "tools": len(tool_names),
                    "hiddenToolsRejected": len(hidden_tools),
                    "deniedToolsExposed": exposed_denied,
                    "oauth": oauth_summary,
                },
                indent=2,
            )
        )
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    raise SystemExit(main())
