#!/usr/bin/env python3
"""Smoke test the Project Atlas HTTP MCP gateway."""

from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import json
import re
import socket
import subprocess
import sys
import tempfile
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
    "atlas.project_planning_context",
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
    "owner_name": re.compile(r"\bExample\s+Owner\b", re.IGNORECASE),
}

HTTP_TIMEOUT_SECONDS = 75
OAUTH_SCOPE = "atlas.read"
OAUTH_SMOKE_TOKEN = "atlas-oauth-smoke-token"
OAUTH_MISSING_SCOPE_TOKEN = "atlas-oauth-missing-scope-token"
OAUTH_WRONG_AUDIENCE_TOKEN = "atlas-oauth-wrong-audience-token"
OAUTH_JWKS_KEY_ID = "atlas-smoke-jwks-key"

SENSITIVE_FIXTURE = {
    "result": {
        "content": [
            {
                "type": "text",
                "text": (
                    "Manual fixture from C:\\Private\\Project_Ops_Capsule "
                    "owned by Example Owner at atlas.owner@example.com."
                ),
            }
        ],
        "draftText": "DRAFT_FIXTURE_SHOULD_NOT_LEAK",
        "proposalBody": "PROPOSAL_BODY_FIXTURE_SHOULD_NOT_LEAK",
        "queueContext": {
            "repoPath": "C:\\Private\\Project_Atlas\\project-atlas-main",
            "detail": "QUEUE_CONTEXT_FIXTURE_SHOULD_NOT_LEAK",
        },
    }
}

SENSITIVE_FIXTURE_FORBIDDEN = {
    "C:\\Private",
    "Project_Ops_Capsule",
    "project-atlas-main",
    "atlas.owner@example.com",
    "Example Owner",
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
    origin: str | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, Any]:
    status, body, _headers = request_json_with_headers(
        url, payload, token, origin, extra_headers
    )
    return status, body


def request_json_with_headers(
    url: str,
    payload: dict[str, Any] | None = None,
    token: str | None = None,
    origin: str | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, Any, dict[str, str]]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if origin:
        headers["Origin"] = origin
    headers.update(extra_headers or {})
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
    origin: str | None = None,
) -> tuple[int, str, dict[str, str]]:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if origin:
        headers["Origin"] = origin
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


def stdio_tool_call(exe: Path, name: str, arguments: dict[str, Any]) -> Any:
    payload = [
        {"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": "call",
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
    ]
    proc = subprocess.run(
        [str(exe), "--mcp-stdio"],
        input="\n".join(json.dumps(item) for item in payload) + "\n",
        text=True,
        capture_output=True,
        timeout=45,
    )
    if proc.returncode != 0:
        raise RuntimeError("stdio tool call failed")
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        decoded = json.loads(line)
        if decoded.get("id") != "call":
            continue
        result = decoded.get("result")
        if not isinstance(result, dict) or result.get("isError"):
            raise RuntimeError("stdio tool returned an error")
        content = result.get("content")
        if not isinstance(content, list) or len(content) != 1:
            raise RuntimeError("stdio tool returned an invalid content envelope")
        return json.loads(content[0]["text"])
    raise RuntimeError("stdio tool call did not return a response")


def create_smoke_disclosure_policy(
    exe: Path, directory: Path
) -> tuple[Path, str, str]:
    projects = stdio_tool_call(exe, "list_projects", {"includeArchived": False})
    if not isinstance(projects, list) or not projects:
        raise RuntimeError("stdio list_projects returned no project for remote smoke")
    selected = next(
        (
            project
            for project in projects
            if isinstance(project, dict) and project.get("title") == "Project Atlas"
        ),
        projects[0],
    )
    if not isinstance(selected, dict) or not isinstance(selected.get("id"), str):
        raise RuntimeError("stdio list_projects returned no usable project ID")
    alias = "atlas-smoke"
    policy_path = directory / "atlas_mcp_remote_disclosure.json"
    policy_path.write_text(
        json.dumps(
            {
                "schema": "project_atlas.remote_disclosure_policy.v2",
                "projects": [
                    {
                        "projectId": selected["id"],
                        "alias": alias,
                        "label": "Atlas Smoke Project",
                        "access": ["inventory", "detail"],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    return policy_path, alias, selected["id"]


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
        expected_mask = f'"{private_key}": "[redacted:'
        if private_key in encoded and expected_mask not in encoded:
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


def assert_gateway_transport_hardening_self_test(gateway_module: ModuleType) -> None:
    try:
        gateway_module.validate_bind_host("0.0.0.0", unsafe_bind_all=False)
    except ValueError as error:
        if "--unsafe-bind-all" not in str(error):
            raise AssertionError(f"unexpected unsafe bind error: {error}") from error
    else:
        raise AssertionError("0.0.0.0 bind was allowed without --unsafe-bind-all")
    gateway_module.validate_bind_host("0.0.0.0", unsafe_bind_all=True)
    gateway_module.validate_bind_host("127.0.0.1", unsafe_bind_all=False)

    gateway_module.validate_oauth_resource_url("https://atlas.example.test")
    gateway_module.validate_oauth_resource_url("http://127.0.0.1:4874")
    gateway_module.validate_oauth_resource_url("http://localhost:4874")
    try:
        gateway_module.validate_oauth_resource_url("http://atlas.example.test")
    except ValueError as error:
        if "not HTTPS" not in str(error):
            raise AssertionError(f"unexpected resource-url error: {error}") from error
    else:
        raise AssertionError("non-HTTPS non-localhost resource URL was allowed")

    origins = gateway_module.build_allowed_origins(
        "127.0.0.1",
        4874,
        ["https://atlas.example.test"],
        None,
    )
    if origins != {"http://127.0.0.1:4874", "https://atlas.example.test"}:
        raise AssertionError(f"unexpected allowed origins: {origins}")


def assert_gateway_startup_failure(
    args: argparse.Namespace,
    extra_args: list[str],
    expected_fragment: str,
) -> None:
    proc = subprocess.Popen(
        [sys.executable, str(args.gateway), *extra_args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired as error:
        proc.kill()
        raise AssertionError(f"gateway did not fail fast for {extra_args}") from error
    output = f"{stdout}\n{stderr}"
    if proc.returncode != 2:
        raise AssertionError(
            f"expected startup failure code 2 for {extra_args}, "
            f"got {proc.returncode}: {output[:1200]}"
        )
    if expected_fragment not in output:
        raise AssertionError(
            f"expected startup failure containing {expected_fragment!r}, "
            f"got: {output[:1200]}"
        )


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


FORBIDDEN_REMOTE_KEYS = {
    "absolutePath",
    "branch",
    "command",
    "commands",
    "contextExcerpts",
    "currentAcceptedTruth",
    "draftText",
    "fullPath",
    "githubRemote",
    "headSha",
    "id",
    "localPath",
    "notes",
    "onlineHeadSha",
    "owner",
    "path",
    "proposalBody",
    "raw",
    "rawJson",
    "remoteUrl",
    "repositoryPath",
    "workItemId",
    "llmTaskId",
}


def decode_remote_tool_payload(response: Any) -> Any:
    if not isinstance(response, dict) or "error" in response:
        raise AssertionError(f"remote tool returned a JSON-RPC error: {response}")
    result = response.get("result")
    if not isinstance(result, dict) or result.get("isError") is not False:
        raise AssertionError(f"remote tool returned an invalid result: {response}")
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1:
        raise AssertionError(f"remote tool returned invalid content: {response}")
    block = content[0]
    if not isinstance(block, dict) or set(block) != {"type", "text"}:
        raise AssertionError(f"remote tool returned an invalid content block: {block}")
    if block.get("type") != "text" or not isinstance(block.get("text"), str):
        raise AssertionError(f"remote tool returned non-text content: {block}")
    return json.loads(block["text"])


def assert_no_forbidden_remote_keys(value: Any, *, path: str = "$") -> None:
    if isinstance(value, dict):
        forbidden = sorted(set(value).intersection(FORBIDDEN_REMOTE_KEYS))
        if forbidden:
            raise AssertionError(f"forbidden remote keys at {path}: {forbidden}")
        for key, child in value.items():
            assert_no_forbidden_remote_keys(child, path=f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_no_forbidden_remote_keys(child, path=f"{path}[{index}]")


def assert_hardened_initialize(response: Any) -> None:
    if not isinstance(response, dict) or set(response) != {"jsonrpc", "id", "result"}:
        raise AssertionError(f"initialize root shape drifted: {response}")
    result = response.get("result")
    if not isinstance(result, dict) or set(result) != {
        "protocolVersion",
        "serverInfo",
        "capabilities",
        "instructions",
        "_meta",
    }:
        raise AssertionError(f"initialize result shape drifted: {response}")
    if result.get("protocolVersion") != "2025-06-18":
        raise AssertionError(f"initialize protocol drifted: {response}")
    if result.get("serverInfo") != {
        "name": "project-atlas-gateway",
        "version": "0.2.0",
        "profile": "remote_readonly",
    }:
        raise AssertionError(f"initialize serverInfo drifted: {response}")
    if result.get("capabilities") != {"tools": {"listChanged": False}}:
        raise AssertionError(f"initialize capabilities drifted: {response}")
    meta = result.get("_meta")
    if not isinstance(meta, dict) or set(meta) != {
        "gatewayProfile",
        "projectionSchema",
        "denyByDefault",
        "disclosurePolicyLoaded",
        "remoteWritesEnabled",
        "disclosureScope",
        "absenceDoesNotProveUnregistered",
        "detailsRequireSeparateApproval",
    }:
        raise AssertionError(f"initialize metadata drifted: {response}")
    if (
        meta.get("disclosureScope") != "operator_approved_portfolio_inventory"
        or meta.get("absenceDoesNotProveUnregistered") is not True
        or meta.get("detailsRequireSeparateApproval") is not True
    ):
        raise AssertionError(f"initialize disclosure scope drifted: {response}")


def assert_four_remote_tool_calls(
    base_url: str,
    token: str,
    project_alias: str,
    local_project_id: str,
    *,
    request_id_start: int,
) -> dict[str, str]:
    calls = [
        ("list_projects", {}, "project_atlas.remote_project_inventory.v3"),
        (
            "get_project_status",
            {"projectId": project_alias},
            "project_atlas.remote_project_status.v2",
        ),
        (
            "atlas.workload_snapshot",
            {"projectId": project_alias, "limit": 3},
            "project_atlas.remote_workload_snapshot.v2",
        ),
        (
            "atlas.project_planning_context",
            {"projectId": project_alias},
            "project_atlas.remote_planning_context.v2",
        ),
    ]
    schemas: dict[str, str] = {}
    for offset, (name, arguments, expected_schema) in enumerate(calls):
        status, response = request_json(
            f"{base_url}/mcp",
            rpc(
                "tools/call",
                request_id_start + offset,
                {"name": name, "arguments": arguments},
            ),
            token=token,
        )
        if status != 200:
            raise AssertionError(f"{name} failed with HTTP {status}: {response}")
        payload = decode_remote_tool_payload(response)
        if not isinstance(payload, dict) or payload.get("schema") != expected_schema:
            raise AssertionError(f"{name} returned an unexpected schema: {payload}")
        assert_no_sensitive_payload(name, payload)
        assert_no_forbidden_remote_keys(payload)
        if local_project_id in json.dumps(payload, sort_keys=True):
            raise AssertionError(f"{name} exposed the local project ID")
        schemas[name] = expected_schema
    return schemas


def assert_disclosure_audit(
    path: Path,
    local_project_id: str,
    forbidden_values: set[str],
) -> int:
    if not path.exists():
        raise AssertionError("disclosure audit log was not created")
    events = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if not events:
        raise AssertionError("disclosure audit log is empty")
    expected_keys = {
        "ts",
        "correlationId",
        "tool",
        "projectAlias",
        "decision",
        "projectionSchema",
        "policyDigest",
        "items",
        "responseBytes",
        "durationMs",
        "outcome",
    }
    for event in events:
        if not isinstance(event, dict) or set(event) != expected_keys:
            raise AssertionError(f"disclosure audit event shape drifted: {event}")
    encoded = json.dumps(events, sort_keys=True)
    for forbidden in {local_project_id, *forbidden_values}:
        if forbidden and forbidden in encoded:
            raise AssertionError("disclosure audit leaked private request data")
    successful_tools = {
        event.get("tool") for event in events if event.get("outcome") == "ok"
    }
    if not ALLOWED_TOOLS.issubset(successful_tools):
        raise AssertionError(
            f"disclosure audit missed projected tool calls: {successful_tools}"
        )
    return len(events)


def assert_oauth_unauthorized(
    base_url: str,
    request_id: int,
    label: str,
    token: str | None = None,
) -> None:
    status, body, headers = request_json_with_headers(
        f"{base_url}/mcp",
        rpc("initialize", request_id),
        token=token,
    )
    challenge = headers.get("www-authenticate", "")
    expected_metadata = (
        f'resource_metadata="{base_url}/.well-known/oauth-protected-resource"'
    )
    if status != 401 or body != {"error": "unauthorized"}:
        raise AssertionError(f"{label}: expected 401 unauthorized, got {status} {body}")
    if not challenge.startswith("Bearer "):
        raise AssertionError(f"{label}: missing Bearer challenge: {headers}")
    if expected_metadata not in challenge:
        raise AssertionError(f"{label}: missing resource metadata: {challenge}")
    if f'scope="{OAUTH_SCOPE}"' not in challenge:
        raise AssertionError(f"{label}: missing {OAUTH_SCOPE} scope: {challenge}")


class OAuthIntrospectionHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(length).decode("utf-8")
        params = urllib.parse.parse_qs(body)
        token = params.get("token", [""])[0]
        payload = self.server.token_payloads.get(token, {"active": False})  # type: ignore[attr-defined]
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


class OAuthIntrospectionServer(http.server.ThreadingHTTPServer):
    token_payloads: dict[str, dict[str, Any]]


class OAuthJwksHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/.well-known/jwks.json":
            self.send_response(404)
            self.end_headers()
            return
        encoded = json.dumps({"keys": [self.server.public_jwk]}).encode("utf-8")  # type: ignore[attr-defined]
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


class OAuthJwksServer(http.server.ThreadingHTTPServer):
    public_jwk: dict[str, Any]


def run_oauth_gateway_smoke(args: argparse.Namespace, all_stdio_tools: set[str]) -> dict[str, Any]:
    auth_server = OAuthIntrospectionServer(("127.0.0.1", 0), OAuthIntrospectionHandler)
    auth_port = int(auth_server.server_address[1])
    auth_base = f"http://127.0.0.1:{auth_port}"
    auth_thread = threading.Thread(target=auth_server.serve_forever, daemon=True)
    auth_thread.start()

    port = free_port()
    base_url = f"http://{args.host}:{port}"
    auth_server.token_payloads = {
        OAUTH_SMOKE_TOKEN: {
            "active": True,
            "scope": OAUTH_SCOPE,
            "aud": base_url,
        },
        OAUTH_MISSING_SCOPE_TOKEN: {
            "active": True,
            "scope": "profile",
            "aud": base_url,
        },
        OAUTH_WRONG_AUDIENCE_TOKEN: {
            "active": True,
            "scope": OAUTH_SCOPE,
            "aud": f"{base_url}/wrong-resource",
        },
    }
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
            "--disclosure-policy",
            str(args.disclosure_policy),
            "--disclosure-audit-log",
            str(args.disclosure_audit_log),
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
        alias_status, alias_metadata = request_json(
            f"{base_url}/.well-known/oauth-protected-resource/mcp"
        )
        if alias_status != 200 or alias_metadata != metadata:
            raise AssertionError(
                f"bad path-specific protected resource metadata: "
                f"{alias_status} {alias_metadata}"
            )

        assert_oauth_unauthorized(base_url, 201, "oauth missing token")
        assert_oauth_unauthorized(
            base_url,
            202,
            "oauth invalid token",
            token="wrong-oauth-token",
        )
        assert_oauth_unauthorized(
            base_url,
            203,
            "oauth missing atlas.read scope",
            token=OAUTH_MISSING_SCOPE_TOKEN,
        )
        assert_oauth_unauthorized(
            base_url,
            204,
            "oauth wrong audience",
            token=OAUTH_WRONG_AUDIENCE_TOKEN,
        )
        status, body = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 209),
            token=OAUTH_SMOKE_TOKEN,
            origin="https://evil.example",
        )
        if status != 403 or body != {"error": "forbidden_origin"}:
            raise AssertionError(f"oauth bad Origin was not rejected: {status} {body}")

        status, initialize = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 205),
            token=OAUTH_SMOKE_TOKEN,
            origin=base_url,
        )
        if status != 200 or initialize.get("result", {}).get("instructions") is None:
            raise AssertionError(f"bad oauth initialize: {status} {initialize}")
        assert_hardened_initialize(initialize)
        assert_no_sensitive_payload("oauth initialize", initialize)

        status, tools_list = request_json(
            f"{base_url}/mcp",
            rpc("tools/list", 206, {}),
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

        projected_schemas = assert_four_remote_tool_calls(
            base_url,
            OAUTH_SMOKE_TOKEN,
            args.project_alias,
            args.local_project_id,
            request_id_start=207,
        )

        hidden_tools = sorted(all_stdio_tools.difference(tool_names))
        assert_denied_tool(
            base_url,
            OAUTH_SMOKE_TOKEN,
            218,
            hidden_tools[0],
        )
        return {
            "tools": len(tool_names),
            "challenge": True,
            "protectedResource": True,
            "negativePaths": 4,
            "originValidated": True,
            "projectedTools": len(projected_schemas),
        }
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        auth_server.shutdown()
        auth_server.server_close()


def run_oauth_jwks_gateway_smoke(args: argparse.Namespace, all_stdio_tools: set[str]) -> dict[str, Any]:
    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private_key.public_key()))
    public_jwk["kid"] = OAUTH_JWKS_KEY_ID
    public_jwk["use"] = "sig"
    public_jwk["alg"] = "RS256"

    auth_server = OAuthJwksServer(("127.0.0.1", 0), OAuthJwksHandler)
    auth_server.public_jwk = public_jwk
    auth_port = int(auth_server.server_address[1])
    auth_base = f"http://127.0.0.1:{auth_port}"
    auth_thread = threading.Thread(target=auth_server.serve_forever, daemon=True)
    auth_thread.start()

    port = free_port()
    base_url = f"http://{args.host}:{port}"
    now = int(time.time())

    def make_token(**overrides: Any) -> str:
        payload = {
            "iss": auth_base,
            "aud": base_url,
            "iat": now,
            "exp": now + 300,
            "scope": OAUTH_SCOPE,
        }
        payload.update(overrides)
        return jwt.encode(
            payload,
            private_key,
            algorithm="RS256",
            headers={"kid": OAUTH_JWKS_KEY_ID},
        )

    valid_token = make_token(iss=f"{auth_base}/")
    missing_scope_token = make_token(scope="profile")
    wrong_audience_token = make_token(aud=f"{base_url}/wrong-resource")
    expired_token = make_token(exp=now - 30)

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
            "--disclosure-policy",
            str(args.disclosure_policy),
            "--disclosure-audit-log",
            str(args.disclosure_audit_log),
            "--auth-mode",
            "oauth",
            "--resource-url",
            base_url,
            "--authorization-server",
            auth_base,
            "--jwks-url",
            f"{auth_base}/.well-known/jwks.json",
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
            raise AssertionError(f"bad jwks metadata status: {status} {metadata}")
        if metadata.get("resource") != base_url:
            raise AssertionError(f"bad jwks protected resource: {metadata}")
        if metadata.get("authorization_servers") != [auth_base]:
            raise AssertionError(f"bad jwks auth servers: {metadata}")
        if metadata.get("jwks_uri") != f"{auth_base}/.well-known/jwks.json":
            raise AssertionError(f"bad jwks uri metadata: {metadata}")
        alias_status, alias_metadata = request_json(
            f"{base_url}/.well-known/oauth-protected-resource/mcp"
        )
        if alias_status != 200 or alias_metadata != metadata:
            raise AssertionError(
                f"bad jwks path-specific protected resource metadata: "
                f"{alias_status} {alias_metadata}"
            )

        assert_oauth_unauthorized(base_url, 301, "jwks missing token")
        assert_oauth_unauthorized(
            base_url,
            302,
            "jwks invalid token",
            token="wrong-oauth-token",
        )
        assert_oauth_unauthorized(
            base_url,
            303,
            "jwks missing atlas.read scope",
            token=missing_scope_token,
        )
        assert_oauth_unauthorized(
            base_url,
            304,
            "jwks wrong audience",
            token=wrong_audience_token,
        )
        assert_oauth_unauthorized(
            base_url,
            305,
            "jwks expired token",
            token=expired_token,
        )

        status, tools_list = request_json(
            f"{base_url}/mcp",
            rpc("tools/list", 306, {}),
            token=valid_token,
        )
        tool_names = {
            tool["name"] for tool in tools_list.get("result", {}).get("tools", [])
        }
        if tool_names != ALLOWED_TOOLS:
            raise AssertionError(f"unexpected jwks remote tools: {sorted(tool_names)}")
        assert_no_sensitive_payload("jwks tools/list", tools_list)

        projected_schemas = assert_four_remote_tool_calls(
            base_url,
            valid_token,
            args.project_alias,
            args.local_project_id,
            request_id_start=307,
        )

        hidden_tools = sorted(all_stdio_tools.difference(tool_names))
        assert_denied_tool(
            base_url,
            valid_token,
            318,
            hidden_tools[0],
        )
        return {
            "tools": len(tool_names),
            "challenge": True,
            "protectedResource": True,
            "negativePaths": 5,
            "hiddenToolRejected": True,
            "projectedTools": len(projected_schemas),
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
    args.temp_policy_dir = tempfile.TemporaryDirectory(
        prefix="atlas_mcp_gateway_smoke_"
    )
    temp_policy_root = Path(args.temp_policy_dir.name)
    (
        args.disclosure_policy,
        args.project_alias,
        args.local_project_id,
    ) = create_smoke_disclosure_policy(args.exe, temp_policy_root)
    args.disclosure_audit_log = temp_policy_root / "disclosure-audit.jsonl"
    all_stdio_tools = stdio_tool_names(args.exe)
    missing_allowed = sorted(ALLOWED_TOOLS.difference(all_stdio_tools))
    if missing_allowed:
        raise AssertionError(f"allowed tools missing from stdio server: {missing_allowed}")
    gateway_module = load_gateway_module(args.gateway)
    assert_gateway_redaction_self_test(gateway_module)
    assert_gateway_transport_hardening_self_test(gateway_module)
    assert_gateway_startup_failure(
        args,
        [
            "--host",
            "127.0.0.1",
            "--port",
            str(free_port()),
            "--token",
            args.token,
        ],
        "--disclosure-policy",
    )
    assert_gateway_startup_failure(
        args,
        [
            "--host",
            "0.0.0.0",
            "--port",
            str(free_port()),
            "--token",
            args.token,
        ],
        "--unsafe-bind-all",
    )
    assert_gateway_startup_failure(
        args,
        [
            "--auth-mode",
            "oauth",
            "--resource-url",
            "http://atlas.example.test",
            "--authorization-server",
            "https://auth.example.test",
            "--jwks-url",
            "https://auth.example.test/jwks.json",
            "--disclosure-policy",
            str(args.disclosure_policy),
            "--disclosure-audit-log",
            str(args.disclosure_audit_log),
        ],
        "not HTTPS",
    )
    assert_gateway_startup_failure(
        args,
        [
            "--auth-mode",
            "oauth",
            "--resource-url",
            f"http://127.0.0.1:{free_port()}",
            "--authorization-server",
            "https://auth.example.test",
            "--jwks-url",
            "https://auth.example.test/jwks.json",
            "--introspection-url",
            "https://auth.example.test/introspect",
            "--disclosure-policy",
            str(args.disclosure_policy),
            "--disclosure-audit-log",
            str(args.disclosure_audit_log),
        ],
        "exactly one",
    )

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
            "--disclosure-policy",
            str(args.disclosure_policy),
            "--disclosure-audit-log",
            str(args.disclosure_audit_log),
            "--token",
            args.token,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        wait_for_health(base_url)

        expected_policy_digest = hashlib.sha256(
            args.disclosure_policy.read_bytes()
        ).hexdigest()
        status, metadata = request_json(
            f"{base_url}/.well-known/project-atlas-mcp",
            extra_headers={
                "X-Project-Atlas-Policy-Digest": expected_policy_digest
            },
        )
        if status != 200 or metadata.get("profile") != "remote_readonly":
            raise AssertionError(f"bad metadata: {status} {metadata}")
        if set(metadata.get("allowedTools", [])) != ALLOWED_TOOLS:
            raise AssertionError(f"metadata allowlist drifted: {metadata}")
        if (
            metadata.get("projectionSchema")
            != "project_atlas.remote_projection.v1"
            or metadata.get("denyByDefault") is not True
            or metadata.get("disclosurePolicyLoaded") is not True
            or metadata.get("disclosurePolicyMatches") is not True
        ):
            raise AssertionError(f"metadata projection boundary drifted: {metadata}")
        if "policyDigest" in metadata:
            raise AssertionError("metadata exposed the disclosure policy digest")
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
        status, body = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 102),
            token=args.token,
            origin="https://evil.example",
        )
        if status != 403 or body != {"error": "forbidden_origin"}:
            raise AssertionError(f"bad Origin was not rejected: {status} {body}")
        status, body, headers = request_raw(f"{base_url}/mcp", token=args.token)
        if status != 200 or "text/event-stream" not in headers.get("content-type", ""):
            raise AssertionError(f"bad GET /mcp response: {status} {headers} {body}")
        if "project-atlas gateway ready" not in body:
            raise AssertionError(f"GET /mcp did not return readiness event: {body}")
        status, body, headers = request_raw(
            f"{base_url}/mcp",
            token=args.token,
            origin="https://evil.example",
        )
        if status != 403:
            raise AssertionError(f"bad GET /mcp Origin response: {status} {headers} {body}")

        status, initialize = request_json(
            f"{base_url}/mcp",
            rpc("initialize", 2),
            token=args.token,
            origin=base_url,
        )
        if status != 200 or initialize.get("result", {}).get("instructions") is None:
            raise AssertionError(f"bad initialize: {status} {initialize}")
        assert_hardened_initialize(initialize)
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
        list_tool = next(
            tool
            for tool in tools_list.get("result", {}).get("tools", [])
            if tool.get("name") == "list_projects"
        )
        if "includeArchived" in list_tool.get("inputSchema", {}).get(
            "properties", {}
        ):
            raise AssertionError("remote list_projects still exposes includeArchived")

        projected_schemas = assert_four_remote_tool_calls(
            base_url,
            args.token,
            args.project_alias,
            args.local_project_id,
            request_id_start=4,
        )

        hidden_tools = sorted(all_stdio_tools.difference(tool_names))
        missing_denied_probes = sorted(DENIED_TOOL_PROBES.difference(hidden_tools))
        if missing_denied_probes:
            raise AssertionError(
                f"denied probe tools were unexpectedly exposed: {missing_denied_probes}"
            )
        for offset, hidden_tool in enumerate(hidden_tools, start=50):
            assert_denied_tool(base_url, args.token, offset, hidden_tool)

        oauth_summary = run_oauth_gateway_smoke(args, all_stdio_tools)
        oauth_jwks_summary = run_oauth_jwks_gateway_smoke(args, all_stdio_tools)
        audit_events = assert_disclosure_audit(
            args.disclosure_audit_log,
            args.local_project_id,
            {
                args.token,
                OAUTH_SMOKE_TOKEN,
                OAUTH_MISSING_SCOPE_TOKEN,
                OAUTH_WRONG_AUDIENCE_TOKEN,
            },
        )

        print(
            json.dumps(
                {
                    "status": "ok",
                    "gateway": base_url,
                    "tools": len(tool_names),
                    "hiddenToolsRejected": len(hidden_tools),
                    "deniedToolsExposed": exposed_denied,
                    "projectedTools": len(projected_schemas),
                    "disclosureAuditEvents": audit_events,
                    "oauth": oauth_summary,
                    "oauthJwks": oauth_jwks_summary,
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
        args.temp_policy_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
