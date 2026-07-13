#!/usr/bin/env python3
"""Small authenticated HTTP gateway for Project Atlas MCP stdio.

This sidecar keeps the Flutter app and SQLite database private. It exposes a
minimal Streamable HTTP-style /mcp endpoint and proxies allowed JSON-RPC calls
to the existing Project Atlas stdio MCP executable.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hmac
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

try:
    from atlas_mcp_remote_policy import (
        REMOTE_PROJECTION_SCHEMA,
        REMOTE_SCOPE_NOTICE,
        DisclosurePolicy,
        DisclosurePolicyError,
        RemoteProjectionError,
        attach_remote_project_visibility,
        load_disclosure_policy,
        prepare_remote_tool_request,
        project_remote_tool_response,
        remote_tool_contract,
    )
except ModuleNotFoundError:  # Supports import as tools.atlas_mcp_gateway in tests.
    from tools.atlas_mcp_remote_policy import (
        REMOTE_PROJECTION_SCHEMA,
        REMOTE_SCOPE_NOTICE,
        DisclosurePolicy,
        DisclosurePolicyError,
        RemoteProjectionError,
        attach_remote_project_visibility,
        load_disclosure_policy,
        prepare_remote_tool_request,
        project_remote_tool_response,
        remote_tool_contract,
    )


DEFAULT_ALLOWED_TOOLS = {
    "list_projects",
    "get_project_status",
    "atlas.workload_snapshot",
    "atlas.project_planning_context",
}

AUTH_MODE_STATIC = "static"
AUTH_MODE_OAUTH = "oauth"
DEFAULT_OAUTH_SCOPE = "atlas.read"
DEFAULT_UNSAFE_BIND_HOSTS = {"0.0.0.0"}
LOCALHOST_NAMES = {"localhost"}
MAX_MCP_REQUEST_BYTES = 64 * 1024
MAX_MCP_RESPONSE_BYTES = 64 * 1024
MAX_RAW_STDIO_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_RAW_STDIO_STDERR_BYTES = 256 * 1024
MAX_MCP_BATCH_ITEMS = 16
REMOTE_PROTOCOL_VERSION = "2025-06-18"

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
    "limited to an operator-approved, deny-by-default subset of projects in a "
    "tiny redacted read-only profile. A missing alias does not prove that a "
    "project is unregistered locally. Read disclosed Atlas state before "
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
PERSON_NAME_RE = re.compile(
    os.environ.get("ATLAS_MCP_PRIVATE_NAME_PATTERN", r"\bExample\s+Owner\b"),
    re.IGNORECASE,
)
PRIVATE_CONTEXT_KEYS = {
    "absolutePath",
    "context",
    "draft",
    "draftText",
    "email",
    "errorDetails",
    "fullPath",
    "githubRemoteUrl",
    "headSha",
    "localPath",
    "notes",
    "onlineHeadSha",
    "owner",
    "path",
    "privateContext",
    "proposalBody",
    "queueContext",
    "raw",
    "rawQueueContext",
    "repoPath",
    "repositoryPath",
    "remoteUrl",
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


class StdioOutputLimitError(RuntimeError):
    """Raised after terminating a stdio child that exceeded a hard pipe cap."""


def run_process_bounded(
    command: list[str],
    stdin_text: str,
    *,
    timeout: int,
    stdout_limit: int,
    stderr_limit: int,
) -> tuple[int, str]:
    """Run one child while draining both pipes incrementally under hard caps."""

    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout_chunks: list[bytes] = []
    exceeded = threading.Event()
    kill_lock = threading.Lock()

    def terminate() -> None:
        with kill_lock:
            if proc.poll() is None:
                try:
                    proc.kill()
                except OSError:
                    pass

    def close_pipes() -> None:
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass

    def drain(
        stream: Any,
        *,
        limit: int,
        chunks: list[bytes] | None,
    ) -> None:
        total = 0
        try:
            while True:
                chunk = stream.read(64 * 1024)
                if not chunk:
                    return
                total += len(chunk)
                if total > limit:
                    exceeded.set()
                    terminate()
                    return
                if chunks is not None:
                    chunks.append(chunk)
        except OSError:
            terminate()

    assert proc.stdout is not None
    assert proc.stderr is not None
    stdout_thread = threading.Thread(
        target=drain,
        kwargs={
            "stream": proc.stdout,
            "limit": stdout_limit,
            "chunks": stdout_chunks,
        },
        daemon=True,
    )
    stderr_thread = threading.Thread(
        target=drain,
        kwargs={
            "stream": proc.stderr,
            "limit": stderr_limit,
            "chunks": None,
        },
        daemon=True,
    )
    stdout_thread.start()
    stderr_thread.start()

    try:
        assert proc.stdin is not None
        proc.stdin.write(stdin_text.encode("utf-8"))
        proc.stdin.close()
    except OSError:
        terminate()

    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate()
        proc.wait()
        stdout_thread.join()
        stderr_thread.join()
        close_pipes()
        raise

    stdout_thread.join()
    stderr_thread.join()
    close_pipes()
    if exceeded.is_set():
        raise StdioOutputLimitError("Local MCP output exceeded its hard limit.")
    return proc.returncode, b"".join(stdout_chunks).decode("utf-8")


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
        if (
            not isinstance(response, dict)
            or "error" in response
            or not isinstance(response.get("result"), dict)
        ):
            return json_rpc_error(
                request.get("id"), -32603, "Gateway initialization failed", ""
            )
        result = {
            "protocolVersion": REMOTE_PROTOCOL_VERSION,
            "serverInfo": {
                "name": "project-atlas-gateway",
                "version": "0.2.0",
                "profile": "remote_readonly",
            },
            "capabilities": {"tools": {"listChanged": False}},
            "instructions": GATEWAY_INSTRUCTIONS,
            "_meta": {
                "gatewayProfile": "remote_readonly",
                "projectionSchema": REMOTE_PROJECTION_SCHEMA,
                "denyByDefault": True,
                "disclosurePolicyLoaded": True,
                "remoteWritesEnabled": False,
                "disclosureScope": REMOTE_SCOPE_NOTICE["scope"],
                "absenceDoesNotProveUnregistered": True,
            },
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
                return_code, stdout = run_process_bounded(
                    [str(self.exe), "--mcp-stdio"],
                    stdin_payload,
                    timeout=self.timeout,
                    stdout_limit=MAX_RAW_STDIO_RESPONSE_BYTES,
                    stderr_limit=MAX_RAW_STDIO_STDERR_BYTES,
                )
        except subprocess.TimeoutExpired:
            return json_rpc_error(response_id, -32603, "Gateway timeout", "")
        except (OSError, UnicodeError, StdioOutputLimitError):
            return json_rpc_error(
                response_id,
                -32603,
                "Project Atlas MCP failed",
                "Local MCP process failed.",
            )

        if return_code != 0:
            return json_rpc_error(
                response_id,
                -32603,
                "Project Atlas MCP failed",
                "Local MCP process failed.",
            )

        responses: list[dict[str, Any]] = []
        for line in stdout.splitlines():
            if not line.strip():
                continue
            try:
                decoded = json.loads(line)
            except json.JSONDecodeError:
                return json_rpc_error(
                    response_id,
                    -32603,
                    "Invalid stdio MCP response",
                    "Local MCP response was invalid.",
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


class OAuthConfig:
    def __init__(
        self,
        resource_url: str,
        authorization_servers: list[str],
        scope: str,
        resource_documentation: str | None = None,
        introspection_url: str | None = None,
        introspection_client_id: str | None = None,
        introspection_client_secret: str | None = None,
        jwks_url: str | None = None,
    ) -> None:
        self.resource_url = resource_url.rstrip("/")
        self.authorization_servers = authorization_servers
        self.scope = scope
        self.resource_documentation = resource_documentation
        self.introspection_url = introspection_url
        self.introspection_client_id = introspection_client_id
        self.introspection_client_secret = introspection_client_secret
        self.jwks_url = jwks_url

    @property
    def metadata_url(self) -> str:
        return f"{self.resource_url}/.well-known/oauth-protected-resource"

    @property
    def security_schemes(self) -> list[dict[str, Any]]:
        return [{"type": "oauth2", "scopes": [self.scope]}]


class TokenVerifier:
    def verify(self, token: str) -> tuple[bool, str]:
        raise NotImplementedError


class StaticTokenVerifier(TokenVerifier):
    def __init__(self, token: str) -> None:
        self.token = token

    def verify(self, token: str) -> tuple[bool, str]:
        if hmac.compare_digest(token, self.token):
            return True, ""
        return False, "invalid static bearer token"


class OAuthIntrospectionVerifier(TokenVerifier):
    def __init__(self, config: OAuthConfig, timeout: int) -> None:
        self.config = config
        self.timeout = timeout

    def verify(self, token: str) -> tuple[bool, str]:
        if not self.config.introspection_url:
            return False, "oauth introspection is not configured"

        body = urllib.parse.urlencode({"token": token}).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        if self.config.introspection_client_id is not None:
            credentials = (
                f"{self.config.introspection_client_id}:"
                f"{self.config.introspection_client_secret or ''}"
            )
            import base64

            encoded_credentials = base64.b64encode(credentials.encode("utf-8")).decode(
                "ascii"
            )
            headers["Authorization"] = f"Basic {encoded_credentials}"
        request = urllib.request.Request(
            self.config.introspection_url,
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            return False, f"oauth introspection failed: {error}"

        if not isinstance(payload, dict) or payload.get("active") is not True:
            return False, "oauth token is inactive"
        if not _scope_contains(payload.get("scope"), self.config.scope):
            return False, "oauth token is missing required scope"
        if not _audience_matches(payload, self.config.resource_url):
            return False, "oauth token audience does not match resource"
        return True, ""


class OAuthJwksVerifier(TokenVerifier):
    def __init__(self, config: OAuthConfig, timeout: int) -> None:
        self.config = config
        self.timeout = timeout
        try:
            import jwt
        except ImportError as error:
            raise RuntimeError(
                "PyJWT is required for OAuth JWKS validation. "
                "Install PyJWT or use --introspection-url."
            ) from error
        self.jwt = jwt
        self.jwk_client = jwt.PyJWKClient(
            config.jwks_url,
            timeout=timeout,
        )

    def verify(self, token: str) -> tuple[bool, str]:
        try:
            signing_key = self.jwk_client.get_signing_key_from_jwt(token)
            payload = self.jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=self.config.resource_url,
                options={"require": ["exp", "iat"]},
            )
        except Exception as error:
            return False, f"oauth jwt validation failed: {error}"
        if not isinstance(payload, dict):
            return False, "oauth jwt payload is invalid"
        if not _issuer_matches(payload, self.config.authorization_servers):
            return False, "oauth token issuer does not match authorization server"
        if not _payload_has_scope(payload, self.config.scope):
            return False, "oauth token is missing required scope"
        return True, ""


class DisclosureAuditLog:
    """Append-only local audit containing metadata, never MCP payload content."""

    def __init__(self, path: Path, policy_digest: str) -> None:
        self.path = path
        self.policy_digest = policy_digest
        self._lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with self.path.open("a", encoding="utf-8"):
                pass
        except OSError as error:
            raise RuntimeError("Disclosure audit log is not writable.") from error

    def record(
        self,
        *,
        correlation_id: str,
        tool: str,
        project_alias: str | None,
        decision: str,
        outcome: str,
        item_count: int,
        response_bytes: int,
        duration_ms: int,
    ) -> None:
        event = {
            "ts": dt.datetime.now(dt.timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "correlationId": correlation_id,
            "tool": tool,
            "projectAlias": project_alias,
            "decision": decision,
            "projectionSchema": REMOTE_PROJECTION_SCHEMA,
            "policyDigest": self.policy_digest,
            "items": max(0, item_count),
            "responseBytes": max(0, response_bytes),
            "durationMs": max(0, duration_ms),
            "outcome": outcome,
        }
        encoded = json.dumps(event, separators=(",", ":"), sort_keys=True)
        try:
            with self._lock, self.path.open("a", encoding="utf-8") as handle:
                handle.write(encoded + "\n")
        except OSError:
            logging.error("MCP disclosure audit write failed")


class GatewayState:
    def __init__(
        self,
        exe: Path,
        token: str | None,
        timeout: int,
        auth_mode: str,
        allowed_origins: set[str],
        disclosure_policy: DisclosurePolicy,
        disclosure_audit: DisclosureAuditLog,
        oauth_config: OAuthConfig | None = None,
    ) -> None:
        self.client = StdioMcpClient(exe, timeout)
        self.token = token
        self.auth_mode = auth_mode
        self.oauth_config = oauth_config
        self.allowed_origins = allowed_origins
        self.disclosure_policy = disclosure_policy
        self.disclosure_audit = disclosure_audit
        if auth_mode == AUTH_MODE_OAUTH:
            if oauth_config is None:
                raise ValueError("oauth_config is required for oauth mode")
            if bool(oauth_config.jwks_url) == bool(oauth_config.introspection_url):
                raise ValueError(
                    "oauth mode requires exactly one token verification endpoint"
                )
            if oauth_config.jwks_url:
                self.token_verifier: TokenVerifier = OAuthJwksVerifier(
                    oauth_config, timeout
                )
            else:
                self.token_verifier = OAuthIntrospectionVerifier(
                    oauth_config, timeout
                )
        elif token:
            self.token_verifier = StaticTokenVerifier(token)
        else:
            raise ValueError("token is required for static mode")
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


def _scope_contains(scope_value: Any, required_scope: str) -> bool:
    if isinstance(scope_value, str):
        return required_scope in scope_value.split()
    if isinstance(scope_value, list):
        return required_scope in {str(scope) for scope in scope_value}
    return False


def _payload_has_scope(payload: dict[str, Any], required_scope: str) -> bool:
    return (
        _scope_contains(payload.get("scope"), required_scope)
        or _scope_contains(payload.get("scp"), required_scope)
        or _scope_contains(payload.get("permissions"), required_scope)
    )


def _issuer_matches(payload: dict[str, Any], authorization_servers: list[str]) -> bool:
    issuer = payload.get("iss")
    if not isinstance(issuer, str):
        return False
    normalized_issuer = issuer.rstrip("/")
    return normalized_issuer in {server.rstrip("/") for server in authorization_servers}


def _audience_matches(payload: dict[str, Any], resource_url: str) -> bool:
    audience = payload.get("aud", payload.get("resource"))
    if isinstance(audience, str):
        return audience.rstrip("/") == resource_url.rstrip("/")
    if isinstance(audience, list):
        return resource_url.rstrip("/") in {str(item).rstrip("/") for item in audience}
    return False


def _split_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip().rstrip("/") for item in value.split(",") if item.strip()]


def _is_loopback_host(host: str | None) -> bool:
    if not host:
        return False
    normalized = host.strip("[]").lower()
    if normalized in LOCALHOST_NAMES:
        return True
    try:
        import ipaddress

        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def _is_loopback_url(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    return parsed.scheme == "http" and _is_loopback_host(parsed.hostname)


def _normalize_origin(origin: str) -> str:
    parsed = urllib.parse.urlparse(origin.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError(f"invalid origin: {origin}")
    hostname = parsed.hostname.lower()
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    default_port = 443 if parsed.scheme == "https" else 80
    port = "" if parsed.port in {None, default_port} else f":{parsed.port}"
    return f"{parsed.scheme}://{hostname}{port}"


def validate_bind_host(host: str, unsafe_bind_all: bool) -> None:
    if host in DEFAULT_UNSAFE_BIND_HOSTS and not unsafe_bind_all:
        raise ValueError(
            "Refusing to bind MCP gateway to 0.0.0.0 without "
            "--unsafe-bind-all. Use 127.0.0.1 behind a tunnel."
        )


def validate_oauth_resource_url(resource_url: str) -> None:
    parsed = urllib.parse.urlparse(resource_url)
    if parsed.scheme == "https" and parsed.hostname:
        return
    if _is_loopback_url(resource_url):
        return
    raise ValueError(
        "Refusing OAuth --resource-url that is not HTTPS. "
        "Only localhost HTTP is allowed for smoke tests."
    )


def build_allowed_origins(
    host: str,
    port: int,
    explicit_origins: list[str],
    oauth_config: OAuthConfig | None,
) -> set[str]:
    origins = {_normalize_origin(f"http://{host}:{port}")}
    if oauth_config is not None:
        origins.add(_normalize_origin(oauth_config.resource_url))
    origins.update(_normalize_origin(origin) for origin in explicit_origins)
    return origins


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


def filter_tools(
    response: dict[str, Any],
    allowed_tools: set[str],
    security_schemes: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    if not isinstance(response, dict) or "error" in response:
        raise RemoteProjectionError("upstream_error")
    result = response.get("result")
    if not isinstance(result, dict):
        raise RemoteProjectionError("invalid_upstream_shape")
    tools = result.get("tools")
    if not isinstance(tools, list):
        raise RemoteProjectionError("invalid_upstream_shape")
    upstream_names: set[str] = set()
    for tool in tools:
        if not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
            raise RemoteProjectionError("invalid_upstream_shape")
        name = tool.get("name")
        upstream_names.add(name)
    if not allowed_tools.issubset(upstream_names):
        raise RemoteProjectionError("invalid_upstream_shape")
    filtered = [
        _remote_tool_metadata({"name": name}, security_schemes)
        for name in sorted(allowed_tools)
    ]
    return {
        "jsonrpc": "2.0",
        "id": response.get("id"),
        "result": {"tools": filtered},
    }


def _remote_tool_metadata(
    tool: dict[str, Any],
    security_schemes: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    name = tool.get("name")
    if not isinstance(name, str):
        raise RemoteProjectionError("invalid_upstream_shape")
    contract = remote_tool_contract(name)
    annotated = {
        "name": name,
        "description": contract["description"],
        "inputSchema": contract["inputSchema"],
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    }
    meta = {
        "projectAtlasProfile": "remote_readonly",
        "projectionSchema": REMOTE_PROJECTION_SCHEMA,
        "requiresHumanApproval": False,
        "remoteWritesEnabled": False,
    }
    if security_schemes:
        annotated["securitySchemes"] = security_schemes
        meta["securitySchemes"] = security_schemes
    annotated["_meta"] = meta
    return annotated


class McpGatewayHandler(BaseHTTPRequestHandler):
    server_version = "ProjectAtlasMcpGateway/0.1"

    @property
    def state(self) -> GatewayState:
        return self.server.gateway_state  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        request_path = urllib.parse.urlparse(self.path).path
        if request_path in {"/healthz", "/health"}:
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if request_path in {
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-protected-resource/mcp",
        }:
            if self.state.oauth_config is None:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                return
            self._send_json(HTTPStatus.OK, self._oauth_protected_resource_metadata())
            return
        if request_path == "/.well-known/project-atlas-mcp":
            expected_policy_digest = self.headers.get(
                "X-Project-Atlas-Policy-Digest"
            )
            policy_matches = bool(
                isinstance(expected_policy_digest, str)
                and re.fullmatch(r"[0-9a-f]{64}", expected_policy_digest)
                and hmac.compare_digest(
                    expected_policy_digest,
                    self.state.disclosure_policy.digest,
                )
            )
            self._send_json(
                HTTPStatus.OK,
                {
                    "name": "Project Atlas MCP Gateway",
                    "transport": "streamable-http",
                    "mcpEndpoint": "/mcp",
                    "auth": self._auth_metadata(),
                    "profile": "remote_readonly",
                    "projectionSchema": REMOTE_PROJECTION_SCHEMA,
                    "denyByDefault": True,
                    "disclosurePolicyLoaded": True,
                    "disclosurePolicyMatches": policy_matches,
                    "allowedTools": sorted(self.state.allowed_tools),
                },
            )
            return
        if request_path == "/mcp":
            if not self._origin_allowed():
                self._send_forbidden_origin()
                return
            if not self._authorized():
                self._send_unauthorized()
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
        request_path = urllib.parse.urlparse(self.path).path
        if request_path != "/mcp":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_content_length"})
            return
        if length < 0 or length > MAX_MCP_REQUEST_BYTES:
            self._send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "payload_too_large"})
            return
        raw = self.rfile.read(length)
        if not self._origin_allowed():
            self._send_forbidden_origin()
            return
        if not self._authorized():
            self._send_unauthorized()
            return

        try:
            decoded = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                json_rpc_error(None, -32700, "Parse error", ""),
            )
            return

        responses = self._handle_json_rpc(decoded)
        if responses is None:
            self.send_response(HTTPStatus.ACCEPTED)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        if self._encoded_size(responses) > MAX_MCP_RESPONSE_BYTES:
            responses = json_rpc_error(
                None,
                -32603,
                "Remote projection failed",
                {"code": "projection_failed"},
            )
        self._send_json(HTTPStatus.OK, responses)

    def _handle_json_rpc(self, decoded: Any) -> Any:
        if isinstance(decoded, list):
            if not decoded or len(decoded) > MAX_MCP_BATCH_ITEMS:
                return json_rpc_error(None, -32600, "Invalid Request", "")
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
                self._audit(
                    correlation_id=str(uuid.uuid4()),
                    tool="unrecognized",
                    project_alias=None,
                    decision="denied",
                    outcome="tool_not_allowed",
                )
                return json_rpc_error(
                    request_id,
                    -32602,
                    "Tool not allowed by gateway profile",
                    {"profile": "remote_readonly"},
                )
            correlation_id = str(uuid.uuid4())
            started_at = time.monotonic()
            try:
                prepared_request, context = prepare_remote_tool_request(
                    request,
                    self.state.disclosure_policy,
                )
            except RemoteProjectionError as error:
                response = self._remote_projection_error(request_id, error)
                self._audit(
                    correlation_id=correlation_id,
                    tool=name,
                    project_alias=None,
                    decision="denied",
                    outcome=error.code,
                    response_bytes=self._encoded_size(response),
                    started_at=started_at,
                )
                return response

            if name == "atlas.workload_snapshot":
                visibility_request = {
                    "jsonrpc": "2.0",
                    "id": f"gateway-visibility-{uuid.uuid4()}",
                    "method": "tools/call",
                    "params": {
                        "name": "list_projects",
                        "arguments": {"includeArchived": False},
                    },
                }
                visibility_response = self.state.client.request(visibility_request)
                try:
                    if visibility_response is None:
                        raise RemoteProjectionError("upstream_error")
                    context = attach_remote_project_visibility(
                        visibility_response,
                        context,
                        self.state.disclosure_policy,
                    )
                except RemoteProjectionError as error:
                    projected_error = self._remote_projection_error(request_id, error)
                    self._audit(
                        correlation_id=correlation_id,
                        tool=name,
                        project_alias=context.project_alias,
                        decision="denied",
                        outcome=error.code,
                        response_bytes=self._encoded_size(projected_error),
                        started_at=started_at,
                    )
                    return projected_error

            response = self.state.client.request(prepared_request)
            if response is None:
                projected_error = self._remote_projection_error(
                    request_id,
                    RemoteProjectionError("upstream_error"),
                )
                self._audit(
                    correlation_id=correlation_id,
                    tool=name,
                    project_alias=context.project_alias,
                    decision="allowed",
                    outcome="upstream_error",
                    response_bytes=self._encoded_size(projected_error),
                    started_at=started_at,
                )
                return projected_error
            try:
                outcome = project_remote_tool_response(
                    response,
                    context,
                    self.state.disclosure_policy,
                    max_response_bytes=MAX_MCP_RESPONSE_BYTES,
                    scrubber=redact_gateway_payload,
                )
            except RemoteProjectionError as error:
                projected_error = self._remote_projection_error(request_id, error)
                self._audit(
                    correlation_id=correlation_id,
                    tool=name,
                    project_alias=context.project_alias,
                    decision="allowed",
                    outcome=error.code,
                    response_bytes=self._encoded_size(projected_error),
                    started_at=started_at,
                )
                return projected_error
            self._audit(
                correlation_id=correlation_id,
                tool=name,
                project_alias=context.project_alias,
                decision="allowed",
                outcome="ok",
                item_count=outcome.item_count,
                response_bytes=outcome.response_bytes,
                started_at=started_at,
            )
            return outcome.response
        elif method == "tools/list":
            correlation_id = str(uuid.uuid4())
            started_at = time.monotonic()
        elif method == "initialize":
            pass
        else:
            return json_rpc_error(request_id, -32601, "Method not found", str(method))

        response = self.state.client.request(dict(request))
        if response is None:
            return None
        if method == "tools/list":
            security_schemes = (
                self.state.oauth_config.security_schemes
                if self.state.oauth_config is not None
                else None
            )
            try:
                response = filter_tools(
                    response,
                    self.state.allowed_tools,
                    security_schemes,
                )
                response = redact_gateway_payload(response)
                if self._encoded_size(response) > MAX_MCP_RESPONSE_BYTES:
                    raise RemoteProjectionError("response_too_large")
            except RemoteProjectionError as error:
                response = self._remote_projection_error(
                    request_id,
                    error,
                )
                outcome = error.code
            else:
                outcome = "ok"
            self._audit(
                correlation_id=correlation_id,
                tool="tools/list",
                project_alias=None,
                decision="allowed",
                outcome=outcome,
                item_count=len(response.get("result", {}).get("tools", [])),
                response_bytes=self._encoded_size(response),
                started_at=started_at,
            )
            return response
        return redact_gateway_payload(response)

    @staticmethod
    def _encoded_size(value: Any) -> int:
        return len(json.dumps(value, separators=(",", ":")).encode("utf-8"))

    @staticmethod
    def _remote_projection_error(
        request_id: Any,
        error: RemoteProjectionError,
    ) -> dict[str, Any]:
        if error.code == "invalid_params":
            return json_rpc_error(
                request_id,
                -32602,
                "Invalid params",
                {"code": "invalid_params"},
            )
        if error.code == "not_found":
            return json_rpc_error(
                request_id,
                -32004,
                "Resource unavailable",
                {"code": "not_found", **REMOTE_SCOPE_NOTICE},
            )
        return json_rpc_error(
            request_id,
            -32603,
            "Remote projection failed",
            {"code": "projection_failed"},
        )

    def _audit(
        self,
        *,
        correlation_id: str,
        tool: str,
        project_alias: str | None,
        decision: str,
        outcome: str,
        item_count: int = 0,
        response_bytes: int = 0,
        started_at: float | None = None,
    ) -> None:
        duration_ms = 0
        if started_at is not None:
            duration_ms = int((time.monotonic() - started_at) * 1000)
        self.state.disclosure_audit.record(
            correlation_id=correlation_id,
            tool=tool,
            project_alias=project_alias,
            decision=decision,
            outcome=outcome,
            item_count=item_count,
            response_bytes=response_bytes,
            duration_ms=duration_ms,
        )

    def _authorized(self) -> bool:
        auth_header = self.headers.get("Authorization") or ""
        if not auth_header.startswith("Bearer "):
            return False
        token = auth_header.removeprefix("Bearer ").strip()
        ok, reason = self.state.token_verifier.verify(token)
        if not ok:
            logging.warning("MCP gateway auth rejected")
        return ok

    def _origin_allowed(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        try:
            normalized_origin = _normalize_origin(origin)
        except ValueError:
            logging.warning("MCP gateway rejected Origin: invalid")
            return False
        if normalized_origin not in self.state.allowed_origins:
            logging.warning("MCP gateway rejected Origin: not_allowed")
            return False
        return True

    def _auth_metadata(self) -> dict[str, Any]:
        if self.state.oauth_config is None:
            return {"type": "bearer", "mode": "static-dev"}
        return {
            "type": "oauth2",
            "mode": "oauth",
            "scope": self.state.oauth_config.scope,
            "protectedResource": "/.well-known/oauth-protected-resource",
        }

    def _oauth_protected_resource_metadata(self) -> dict[str, Any]:
        config = self.state.oauth_config
        if config is None:
            return {}
        metadata: dict[str, Any] = {
            "resource": config.resource_url,
            "authorization_servers": config.authorization_servers,
            "scopes_supported": [config.scope],
            "bearer_methods_supported": ["header"],
        }
        if config.resource_documentation:
            metadata["resource_documentation"] = config.resource_documentation
        if config.introspection_url:
            metadata["introspection_endpoint"] = config.introspection_url
        if config.jwks_url:
            metadata["jwks_uri"] = config.jwks_url
        return metadata

    def _send_unauthorized(self) -> None:
        headers = {}
        if self.state.oauth_config is not None:
            headers["WWW-Authenticate"] = self._www_authenticate_value()
        self._send_json(
            HTTPStatus.UNAUTHORIZED,
            {"error": "unauthorized"},
            headers=headers,
        )

    def _send_forbidden_origin(self) -> None:
        self._send_json(
            HTTPStatus.FORBIDDEN,
            {"error": "forbidden_origin"},
        )

    def _www_authenticate_value(self) -> str:
        config = self.state.oauth_config
        if config is None:
            return "Bearer"
        return (
            f'Bearer resource_metadata="{config.metadata_url}", '
            f'scope="{config.scope}"'
        )

    def _send_json(
        self,
        status: int,
        body: Any,
        headers: dict[str, str] | None = None,
    ) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(encoded)
        self.close_connection = True

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("MCP HTTP request completed")


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
    parser.add_argument(
        "--unsafe-bind-all",
        action="store_true",
        help="Allow binding the gateway to 0.0.0.0 for explicit local dev only.",
    )
    parser.add_argument("--exe", type=Path, default=Path(os.environ.get("PROJECT_ATLAS_EXE", default_exe_path())))
    parser.add_argument(
        "--auth-mode",
        choices=[AUTH_MODE_STATIC, AUTH_MODE_OAUTH],
        default=os.environ.get("ATLAS_MCP_AUTH_MODE", AUTH_MODE_STATIC),
    )
    parser.add_argument("--token", default=os.environ.get("ATLAS_MCP_GATEWAY_TOKEN"))
    parser.add_argument(
        "--resource-url",
        default=os.environ.get("ATLAS_MCP_RESOURCE_URL"),
        help="Canonical public HTTPS origin for OAuth protected-resource metadata.",
    )
    parser.add_argument(
        "--allowed-origin",
        action="append",
        default=[],
        help="Additional allowed Origin for /mcp requests. May be passed multiple times.",
    )
    parser.add_argument(
        "--authorization-server",
        action="append",
        default=[],
        help="OAuth authorization server issuer URL. May be passed multiple times.",
    )
    parser.add_argument(
        "--scope",
        default=os.environ.get("ATLAS_MCP_OAUTH_SCOPE", DEFAULT_OAUTH_SCOPE),
    )
    parser.add_argument(
        "--resource-documentation",
        default=os.environ.get("ATLAS_MCP_RESOURCE_DOCUMENTATION"),
    )
    parser.add_argument(
        "--introspection-url",
        default=os.environ.get("ATLAS_MCP_INTROSPECTION_URL"),
    )
    parser.add_argument(
        "--introspection-client-id",
        default=os.environ.get("ATLAS_MCP_INTROSPECTION_CLIENT_ID"),
    )
    parser.add_argument(
        "--introspection-client-secret",
        default=os.environ.get("ATLAS_MCP_INTROSPECTION_CLIENT_SECRET"),
    )
    parser.add_argument(
        "--jwks-url",
        default=os.environ.get("ATLAS_MCP_JWKS_URL"),
        help="JWKS endpoint for JWT bearer-token validation, for example Auth0.",
    )
    policy_from_env = os.environ.get("ATLAS_MCP_DISCLOSURE_POLICY")
    parser.add_argument(
        "--disclosure-policy",
        type=Path,
        default=Path(policy_from_env) if policy_from_env else None,
        help="Required ignored JSON policy mapping approved project IDs to remote aliases.",
    )
    audit_from_env = os.environ.get("ATLAS_MCP_DISCLOSURE_AUDIT_LOG")
    parser.add_argument(
        "--disclosure-audit-log",
        type=Path,
        default=(
            Path(audit_from_env)
            if audit_from_env
            else repo_root() / ".local" / "runs" / "atlas-mcp-disclosure-audit.jsonl"
        ),
    )
    parser.add_argument("--timeout", type=int, default=45)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    oauth_config = None
    explicit_allowed_origins = [
        *(_split_csv(os.environ.get("ATLAS_MCP_ALLOWED_ORIGINS"))),
        *[item.rstrip("/") for item in args.allowed_origin if item],
    ]
    try:
        validate_bind_host(args.host, args.unsafe_bind_all)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    if args.disclosure_policy is None:
        print(
            "Refusing to start: pass --disclosure-policy or set "
            "ATLAS_MCP_DISCLOSURE_POLICY.",
            file=sys.stderr,
        )
        return 2
    try:
        disclosure_policy = load_disclosure_policy(args.disclosure_policy)
        disclosure_audit = DisclosureAuditLog(
            args.disclosure_audit_log,
            disclosure_policy.digest,
        )
    except (DisclosurePolicyError, RuntimeError) as error:
        print(f"Refusing to start: {error}", file=sys.stderr)
        return 2
    if args.auth_mode == AUTH_MODE_STATIC and not args.token:
        print(
            "Refusing to start: set ATLAS_MCP_GATEWAY_TOKEN or pass --token.",
            file=sys.stderr,
        )
        return 2
    if args.auth_mode == AUTH_MODE_OAUTH:
        authorization_servers = [
            *(_split_csv(os.environ.get("ATLAS_MCP_AUTHORIZATION_SERVERS"))),
            *[item.rstrip("/") for item in args.authorization_server if item],
        ]
        if not args.resource_url or not authorization_servers:
            print(
                "Refusing to start OAuth mode: pass --resource-url and at least "
                "one --authorization-server.",
                file=sys.stderr,
            )
            return 2
        if bool(args.jwks_url) == bool(args.introspection_url):
            print(
                "Refusing to start OAuth mode: configure exactly one of "
                "--jwks-url or --introspection-url.",
                file=sys.stderr,
            )
            return 2
        try:
            validate_oauth_resource_url(args.resource_url)
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 2
        oauth_config = OAuthConfig(
            resource_url=args.resource_url,
            authorization_servers=authorization_servers,
            scope=args.scope,
            resource_documentation=args.resource_documentation,
            introspection_url=args.introspection_url,
            introspection_client_id=args.introspection_client_id,
            introspection_client_secret=args.introspection_client_secret,
            jwks_url=args.jwks_url,
        )
    try:
        allowed_origins = build_allowed_origins(
            args.host,
            args.port,
            explicit_allowed_origins,
            oauth_config,
        )
    except ValueError as error:
        print(f"Refusing to start: {error}", file=sys.stderr)
        return 2
    state = GatewayState(
        args.exe,
        args.token,
        args.timeout,
        args.auth_mode,
        allowed_origins,
        disclosure_policy,
        disclosure_audit,
        oauth_config,
    )
    server = GatewayServer((args.host, args.port), McpGatewayHandler, state)
    logging.info("Project Atlas MCP gateway listening on http://%s:%s/mcp", args.host, args.port)
    logging.info("Remote projection policy loaded")
    logging.info("Gateway auth mode: %s", args.auth_mode)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
