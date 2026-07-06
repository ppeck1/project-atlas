#!/usr/bin/env python3
"""Small authenticated HTTP gateway for Project Atlas MCP stdio.

This sidecar keeps the Flutter app and SQLite database private. It exposes a
minimal Streamable HTTP-style /mcp endpoint and proxies allowed JSON-RPC calls
to the existing Project Atlas stdio MCP executable.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import threading
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


DEFAULT_ALLOWED_TOOLS = {
    "list_projects",
    "get_project_status",
    "atlas.workload_snapshot",
}

SENSITIVE_READ_TOOLS = {
    "get_project_brief",
    "get_stale_projects",
    "atlas.project_workload",
    "atlas.suggest_next_work",
    "atlas.work_item_context_bundle",
    "list_agent_proposals",
    "list_llm_tasks",
    "get_llm_task",
}

DENIED_REMOTE_TOOLS = {
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
    "preview_local_refresh",
    "inspect_git_visibility",
    "get_github_remote_status",
    "refresh_github_remote_status",
    "list_project_enrichment_runs",
    "get_project_enrichment_run",
    "run_project_enrichment",
    "get_project_identity",
    "get_project_capsule_status",
    "get_project_bootstrap_context",
    "get_llm_task_bootstrap",
    *SENSITIVE_READ_TOOLS,
}

GATEWAY_INSTRUCTIONS = (
    "Project Atlas is a local-first planning system. This remote gateway is "
    "limited to a tiny redacted read-only profile. Read Atlas state before "
    "advising. Do not claim, complete, edit, approve, or close out work through "
    "this connector. If a mutation or private context is needed, summarize the "
    "requested operator action."
)

WINDOWS_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/](?:[^\\/\s\"'<>|]+[\\/]?)+)"
)
UNC_PATH_RE = re.compile(r"\\\\[A-Za-z0-9_.-]+\\[^\s\"'<>|]+")
FILE_URI_RE = re.compile(r"file:///[A-Za-z]:/[^\s\"'<>]+", re.IGNORECASE)
EMAIL_RE = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)
PERSON_NAME_RE = re.compile(r"\bPaul\s+Peck\b", re.IGNORECASE)
PRIVATE_CONTEXT_KEYS = {
    "absolutePath",
    "context",
    "draft",
    "draftText",
    "email",
    "errorDetails",
    "fullPath",
    "githubRemoteUrl",
    "localPath",
    "notes",
    "owner",
    "path",
    "privateContext",
    "proposalBody",
    "queueContext",
    "raw",
    "rawQueueContext",
    "repoPath",
    "repositoryPath",
    "unresolvedProposalBody",
    "unresolvedBody",
}

ALWAYS_REDACT_KEYS = {
    "draft",
    "draftText",
    "privateContext",
    "proposalBody",
    "queueContext",
    "rawQueueContext",
    "unresolvedBody",
    "unresolvedProposalBody",
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


class StdioMcpClient:
    def __init__(self, exe: Path, timeout: int) -> None:
        self.exe = exe
        self.timeout = timeout
        self._lock = threading.Lock()

    def request(self, request: dict[str, Any]) -> dict[str, Any] | None:
        method = request.get("method")
        if method == "initialize":
            return self._initialize(request)
        if method == "notifications/initialized":
            return None
        if method not in {"tools/list", "tools/call"}:
            return json_rpc_error(
                request.get("id"), -32601, "Method not found", str(method)
            )
        return self._roundtrip_with_initialized_session(request)

    def _initialize(self, request: dict[str, Any]) -> dict[str, Any]:
        response = self._run_stdio([request], response_id=request.get("id"))
        result = (response or {}).get("result")
        if not isinstance(result, dict):
            return response or json_rpc_error(
                request.get("id"), -32603, "Gateway error", "No initialize result."
            )
        result = dict(result)
        server_info = dict(result.get("serverInfo") or {})
        server_info["name"] = "project-atlas-gateway"
        server_info["profile"] = "remote_readonly"
        result["serverInfo"] = server_info
        result["instructions"] = GATEWAY_INSTRUCTIONS
        result["_meta"] = {
            "gatewayProfile": "remote_readonly",
            "remoteWritesEnabled": False,
        }
        return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}

    def _roundtrip_with_initialized_session(
        self, request: dict[str, Any]
    ) -> dict[str, Any] | None:
        gateway_id = f"gateway-init-{uuid.uuid4()}"
        payload = [
            {"jsonrpc": "2.0", "id": gateway_id, "method": "initialize", "params": {}},
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            },
            request,
        ]
        return self._run_stdio(payload, response_id=request.get("id"))

    def _run_stdio(
        self,
        payload: list[dict[str, Any]],
        response_id: Any | None = None,
    ) -> dict[str, Any] | None:
        if not self.exe.exists():
            return json_rpc_error(
                response_id,
                -32603,
                "Gateway error",
                f"Project Atlas executable not found: {self.exe}",
            )

        stdin_payload = "\n".join(json.dumps(item) for item in payload) + "\n"
        try:
            with self._lock:
                proc = subprocess.run(
                    [str(self.exe), "--mcp-stdio"],
                    input=stdin_payload,
                    text=True,
                    capture_output=True,
                    timeout=self.timeout,
                )
        except subprocess.TimeoutExpired:
            return json_rpc_error(response_id, -32603, "Gateway timeout", "")

        if proc.returncode != 0:
            return json_rpc_error(
                response_id,
                -32603,
                "Project Atlas MCP failed",
                proc.stderr.strip()[:2000],
            )

        responses: list[dict[str, Any]] = []
        for line in proc.stdout.splitlines():
            if not line.strip():
                continue
            try:
                decoded = json.loads(line)
            except json.JSONDecodeError as error:
                return json_rpc_error(
                    response_id,
                    -32603,
                    "Invalid stdio MCP response",
                    str(error),
                )
            if isinstance(decoded, dict):
                responses.append(decoded)

        if response_id is not None:
            for response in responses:
                if response.get("id") == response_id:
                    return response
            return json_rpc_error(
                response_id,
                -32603,
                "Gateway error",
                "No matching MCP response.",
            )
        return responses[0] if responses else None


class GatewayState:
    def __init__(self, exe: Path, token: str, timeout: int) -> None:
        self.client = StdioMcpClient(exe, timeout)
        self.token = token
        self.allowed_tools = set(DEFAULT_ALLOWED_TOOLS)


def json_rpc_error(
    request_id: Any,
    code: int,
    message: str,
    data: str | dict[str, Any] = "",
) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message, "data": data},
    }


def is_write_or_worker_tool(name: str) -> bool:
    return name in DENIED_REMOTE_TOOLS or name not in DEFAULT_ALLOWED_TOOLS


def redact_gateway_payload(value: Any) -> Any:
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        for key, item in value.items():
            if key in ALWAYS_REDACT_KEYS:
                redacted[key] = "[redacted:private-context]"
            elif key in PRIVATE_CONTEXT_KEYS and _contains_sensitive_text(item):
                redacted[key] = "[redacted:private-context]"
            else:
                redacted[key] = redact_gateway_payload(item)
        return redacted
    if isinstance(value, list):
        return [redact_gateway_payload(item) for item in value]
    if isinstance(value, str):
        return redact_gateway_text(value)
    return value


def redact_gateway_text(value: str) -> str:
    redacted = FILE_URI_RE.sub("[redacted:path]", value)
    redacted = UNC_PATH_RE.sub("[redacted:path]", redacted)
    redacted = WINDOWS_PATH_RE.sub("[redacted:path]", redacted)
    redacted = EMAIL_RE.sub("[redacted:email]", redacted)
    redacted = PERSON_NAME_RE.sub("[redacted:person]", redacted)
    return redacted


def _contains_sensitive_text(value: Any) -> bool:
    if isinstance(value, str):
        return bool(
            WINDOWS_PATH_RE.search(value)
            or UNC_PATH_RE.search(value)
            or FILE_URI_RE.search(value)
            or EMAIL_RE.search(value)
            or PERSON_NAME_RE.search(value)
            or len(value) > 240
        )
    if isinstance(value, list):
        return any(_contains_sensitive_text(item) for item in value)
    if isinstance(value, dict):
        return any(_contains_sensitive_text(item) for item in value.values())
    return False


def filter_tools(response: dict[str, Any], allowed_tools: set[str]) -> dict[str, Any]:
    result = response.get("result")
    if not isinstance(result, dict):
        return response
    tools = result.get("tools")
    if not isinstance(tools, list):
        return response
    filtered = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if name in allowed_tools:
            filtered.append(_remote_tool_metadata(tool))
    next_result = dict(result)
    next_result["tools"] = filtered
    response = dict(response)
    response["result"] = next_result
    return response


def _remote_tool_metadata(tool: dict[str, Any]) -> dict[str, Any]:
    annotated = dict(tool)
    annotated.setdefault("annotations", {})
    annotations = dict(annotated["annotations"])
    annotations.update(
        {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        }
    )
    annotated["annotations"] = annotations
    meta = dict(annotated.get("_meta") or {})
    meta.update(
        {
            "projectAtlasProfile": "remote_readonly",
            "requiresHumanApproval": False,
            "remoteWritesEnabled": False,
        }
    )
    annotated["_meta"] = meta
    return annotated


class McpGatewayHandler(BaseHTTPRequestHandler):
    server_version = "ProjectAtlasMcpGateway/0.1"

    @property
    def state(self) -> GatewayState:
        return self.server.gateway_state  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        if self.path in {"/healthz", "/health"}:
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if self.path == "/.well-known/project-atlas-mcp":
            self._send_json(
                HTTPStatus.OK,
                {
                    "name": "Project Atlas MCP Gateway",
                    "transport": "streamable-http",
                    "mcpEndpoint": "/mcp",
                    "auth": {"type": "bearer"},
                    "profile": "remote_readonly",
                    "allowedTools": sorted(self.state.allowed_tools),
                },
            )
            return
        if self.path == "/mcp":
            if not self._authorized():
                self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                return
            body = b": project-atlas gateway ready\n\n"
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/mcp":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        if not self._authorized():
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length)
        try:
            decoded = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as error:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                json_rpc_error(None, -32700, "Parse error", str(error)),
            )
            return

        responses = self._handle_json_rpc(decoded)
        if responses is None:
            self.send_response(HTTPStatus.ACCEPTED)
            self.end_headers()
            return
        self._send_json(HTTPStatus.OK, responses)

    def _handle_json_rpc(self, decoded: Any) -> Any:
        if isinstance(decoded, list):
            responses = []
            for request in decoded:
                response = self._handle_one(request)
                if response is not None:
                    responses.append(response)
            return responses if responses else None
        return self._handle_one(decoded)

    def _handle_one(self, request: Any) -> dict[str, Any] | None:
        if not isinstance(request, dict):
            return json_rpc_error(None, -32600, "Invalid Request", "Expected object.")
        request_id = request.get("id")
        method = request.get("method")
        if method == "notifications/initialized":
            return None
        if method == "tools/call":
            params = request.get("params")
            if not isinstance(params, dict):
                return json_rpc_error(request_id, -32602, "Invalid params", "")
            name = params.get("name")
            if not isinstance(name, str) or is_write_or_worker_tool(name):
                return json_rpc_error(
                    request_id,
                    -32602,
                    "Tool not allowed by gateway profile",
                    {"profile": "remote_readonly", "tool": name},
                )
            logging.info("proxy tools/call %s", name)
        elif method == "tools/list":
            logging.info("proxy tools/list")
        elif method == "initialize":
            logging.info("proxy initialize")
        else:
            return json_rpc_error(request_id, -32601, "Method not found", str(method))

        response = self.state.client.request(dict(request))
        if response is None:
            return None
        if method == "tools/list":
            response = filter_tools(response, self.state.allowed_tools)
        return redact_gateway_payload(response)

    def _authorized(self) -> bool:
        expected = f"Bearer {self.state.token}"
        return self.headers.get("Authorization") == expected

    def _send_json(self, status: int, body: Any) -> None:
        encoded = json.dumps(body, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("%s - %s", self.address_string(), fmt % args)


class GatewayServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[McpGatewayHandler],
        gateway_state: GatewayState,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.gateway_state = gateway_state


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4874)
    parser.add_argument("--exe", type=Path, default=Path(os.environ.get("PROJECT_ATLAS_EXE", default_exe_path())))
    parser.add_argument("--token", default=os.environ.get("ATLAS_MCP_GATEWAY_TOKEN"))
    parser.add_argument("--timeout", type=int, default=45)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not args.token:
        print(
            "Refusing to start: set ATLAS_MCP_GATEWAY_TOKEN or pass --token.",
            file=sys.stderr,
        )
        return 2
    state = GatewayState(args.exe, args.token, args.timeout)
    server = GatewayServer((args.host, args.port), McpGatewayHandler, state)
    logging.info("Project Atlas MCP gateway listening on http://%s:%s/mcp", args.host, args.port)
    logging.info("Proxying read-only MCP calls to %s", args.exe)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
