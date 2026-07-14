#!/usr/bin/env python3
"""Fail-closed disclosure policy and DTO projection for remote Atlas MCP reads."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


DISCLOSURE_POLICY_SCHEMA_V1 = "project_atlas.remote_disclosure_policy.v1"
DISCLOSURE_POLICY_SCHEMA_V2 = "project_atlas.remote_disclosure_policy.v2"
# Compatibility name retained for v1 policy fixtures and the staged migration.
DISCLOSURE_POLICY_SCHEMA = DISCLOSURE_POLICY_SCHEMA_V1
REMOTE_PROJECTION_SCHEMA = "project_atlas.remote_projection.v1"
MAX_DISCLOSURE_POLICY_BYTES = 128 * 1024
MAX_INVENTORY_PROJECTS = 256
MAX_DETAIL_PROJECTS = 64
MAX_APPROVED_PROJECTS = MAX_DETAIL_PROJECTS
MAX_REMOTE_PROJECT_PAGE = 64
DEFAULT_REMOTE_PROJECT_PAGE = 64
MAX_REMOTE_WORKLOAD_ITEMS = 25
MAX_REMOTE_PLANNING_ITEMS = 5

_ALIAS_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()\-]{0,79}$")
_TOKEN_SHAPED_LABEL_RE = re.compile(
    r"(?:[0-9a-fA-F]{20,}|[A-Za-z0-9_-]{32,})"
)
_SOURCE_TITLE_FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")

PROJECT_STATUSES = frozenset(
    {
        "active",
        "stale",
        "needs_update",
        "needs_review",
        "local_only",
        "public_mismatch",
        "paused",
        "blocked",
        "completed",
        "archived",
    }
)
REMOTE_VISIBLE_PROJECT_STATUSES = PROJECT_STATUSES - {"archived"}
ATTENTION_PROJECT_STATUSES = frozenset(
    {"stale", "needs_update", "needs_review", "local_only", "public_mismatch", "blocked"}
)
REMOTE_SCOPE_NOTICE = {
    "scope": "operator_approved_portfolio_inventory",
    "denyByDefault": True,
    "absenceDoesNotProveUnregistered": True,
    "detailsRequireSeparateApproval": True,
}
REMOTE_DETAIL_SCOPE_NOTICE = {
    "scope": "operator_approved_detail_subset",
    "denyByDefault": True,
    "absenceDoesNotProveUnregistered": True,
    "inventoryVisibilityDoesNotGrantDetails": True,
}
PROJECT_PHASES = frozenset({"idea", "design", "build", "test", "ship", "stabilize"})
PRIORITIES = frozenset({"low", "normal", "high", "urgent"})
FRESHNESS_STATUSES = frozenset({"current", "stale", "unknown"})
CONFIDENCE_VALUES = frozenset({"low", "medium", "high"})
FRESHNESS_REASON_VALUES = frozenset(
    {
        "missing_local_registry",
        "linked_registry_without_observation",
        "missing_local_observation",
        "invalid_local_observation_timestamp",
        "old_local_observation",
        "local_dirty_state",
        "github_remote_detected_but_uncached",
        "github_metadata_missing",
        "github_refresh_failed",
        "old_github_check",
        "github_metadata_unverified",
        "github_online_head_missing",
        "github_remote_push_time_unknown",
        "capsule_errors",
        "capsule_metadata_missing",
        "blocked_work_items",
        "high_priority_without_active_work",
        *{f"project_status_{status}" for status in PROJECT_STATUSES},
    }
)
PLANNING_REASON_VALUES = frozenset(
    {
        "blocked_work_items",
        "high_priority_without_active_work",
        "capsule_errors",
        *{f"project_status_{status}" for status in ATTENTION_PROJECT_STATUSES},
    }
)
SIGNAL_REASON_CLASSES = frozenset(
    {
        "lifecycle",
        "workload",
        "local_evidence",
        "remote_evidence",
        "capsule",
        "freshness_stale",
        "freshness_unknown",
    }
)
WORKLOAD_READINESS_VALUES = frozenset(
    {"ready", "blocked", "needs_decision", "needs_context", "review_needed"}
)
WORKLOAD_BOARD_GROUPS = frozenset(
    {"ready", "needs_decision", "blocked", "in_progress", "review_needed", "done_closed"}
)
WORKLOAD_SIZE_VALUES = frozenset({"tiny", "small", "medium", "large"})
WORKLOAD_RISK_VALUES = frozenset(
    {"docs_only", "low_code", "medium_code", "db_schema", "release", "external_facing"}
)
WORKLOAD_ACTOR_VALUES = frozenset(
    {"user", "codex", "claude", "local_llm", "manual_review"}
)
WORKLOAD_VERIFICATION_VALUES = frozenset(
    {"none", "tests", "smoke", "build", "manual_ui"}
)
WORKLOAD_KIND_VALUES = frozenset({"work_item", "llm_queue_item"})
WORKLOAD_STATUS_VALUES = frozenset(
    {
        "inbox",
        "next",
        "doing",
        "waiting",
        "done",
        "archived",
        "pending",
        "leased",
        "completed",
        "failed",
        "cancelled",
    }
)
WORKLOAD_ORIGIN_VALUES = frozenset(
    {
        "manual",
        "imported_checklist",
        "local_refresh",
        "placeholder",
        "workboard_generated",
        "agent_generated",
        "agent_proposal",
        "imported_work_item",
        "llm_queue",
    }
)
WORKLOAD_STALE_REASON_VALUES = frozenset(
    {
        "imported_template_unreviewed",
        "no_last_reviewed_at",
        "old_last_reviewed_at",
        "placeholder_title",
    }
)

WORKLOAD_FILTER_VALUES = {
    "readiness": WORKLOAD_READINESS_VALUES,
    "actor": WORKLOAD_ACTOR_VALUES,
    "risk": WORKLOAD_RISK_VALUES,
    "size": WORKLOAD_SIZE_VALUES,
}


class DisclosurePolicyError(ValueError):
    """Raised when the local disclosure policy is missing or unsafe."""


class RemoteProjectionError(ValueError):
    """Raised when a remote request or upstream response cannot be made safe."""

    def __init__(self, code: str, message: str = "Remote request unavailable.") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class DisclosureProject:
    local_project_id: str
    alias: str
    label: str
    access: frozenset[str]
    source_title_fingerprint: str | None = None

    @property
    def inventory_enabled(self) -> bool:
        return "inventory" in self.access

    @property
    def detail_enabled(self) -> bool:
        return "detail" in self.access


@dataclass(frozen=True)
class DisclosurePolicy:
    schema: str
    projects: tuple[DisclosureProject, ...]
    digest: str

    @property
    def inventory_projects(self) -> tuple[DisclosureProject, ...]:
        return tuple(project for project in self.projects if project.inventory_enabled)

    @property
    def detail_projects(self) -> tuple[DisclosureProject, ...]:
        return tuple(project for project in self.projects if project.detail_enabled)

    @property
    def inventory_by_local_id(self) -> dict[str, DisclosureProject]:
        return {project.local_project_id: project for project in self.inventory_projects}

    @property
    def inventory_by_alias(self) -> dict[str, DisclosureProject]:
        return {project.alias: project for project in self.inventory_projects}

    @property
    def detail_by_local_id(self) -> dict[str, DisclosureProject]:
        return {project.local_project_id: project for project in self.detail_projects}

    @property
    def detail_by_alias(self) -> dict[str, DisclosureProject]:
        return {project.alias: project for project in self.detail_projects}

    @property
    def all_local_project_ids(self) -> frozenset[str]:
        return frozenset(project.local_project_id for project in self.projects)

    # Compatibility views. New authorization code uses the explicit tier maps.
    @property
    def by_local_id(self) -> dict[str, DisclosureProject]:
        return self.inventory_by_local_id

    @property
    def by_alias(self) -> dict[str, DisclosureProject]:
        return self.inventory_by_alias


@dataclass(frozen=True)
class RemoteCallContext:
    tool: str
    project: DisclosureProject | None = None
    offset: int = 0
    limit: int = DEFAULT_REMOTE_PROJECT_PAGE
    visible_local_project_ids: frozenset[str] | None = None

    @property
    def project_alias(self) -> str | None:
        return self.project.alias if self.project is not None else None


@dataclass(frozen=True)
class ProjectionOutcome:
    response: dict[str, Any]
    response_bytes: int
    item_count: int


REMOTE_TOOL_CONTRACTS: dict[str, dict[str, Any]] = {
    "list_projects": {
        "description": (
            "List operator-approved remote project aliases with compact lifecycle, "
            "workload, and freshness signals. Results are an operator-approved "
            "deny-by-default subset; absence does not prove a project is unregistered."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "offset": {"type": "integer", "minimum": 0},
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_REMOTE_PROJECT_PAGE,
                },
            },
            "additionalProperties": False,
        },
    },
    "get_project_status": {
        "description": (
            "Read compact status for one operator-approved remote project alias."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "projectId": {
                    "type": "string",
                    "pattern": _ALIAS_RE.pattern,
                }
            },
            "required": ["projectId"],
            "additionalProperties": False,
        },
    },
    "atlas.workload_snapshot": {
        "description": (
            "Read a bounded workload summary containing only operator-approved "
            "projects and structured planning classifications."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "projectId": {"type": "string", "pattern": _ALIAS_RE.pattern},
                "readiness": {
                    "type": "string",
                    "enum": sorted(WORKLOAD_READINESS_VALUES),
                },
                "actor": {
                    "type": "string",
                    "enum": sorted(WORKLOAD_ACTOR_VALUES),
                },
                "risk": {
                    "type": "string",
                    "enum": sorted(WORKLOAD_RISK_VALUES),
                },
                "size": {
                    "type": "string",
                    "enum": sorted(WORKLOAD_SIZE_VALUES),
                },
                "blockedOnly": {"type": "boolean"},
                "blocksProgressOnly": {"type": "boolean"},
                "reviewNeededOnly": {"type": "boolean"},
                "staleOnly": {"type": "boolean"},
                "highPriorityOnly": {"type": "boolean"},
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_REMOTE_WORKLOAD_ITEMS,
                },
            },
            "additionalProperties": False,
        },
    },
    "atlas.project_planning_context": {
        "description": (
            "Read a bounded structured planning preflight for one operator-approved "
            "remote project alias. Free-text notes and accepted-truth claims are withheld."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "projectId": {"type": "string", "pattern": _ALIAS_RE.pattern}
            },
            "required": ["projectId"],
            "additionalProperties": False,
        },
    },
}


def load_disclosure_policy(path: Path) -> DisclosurePolicy:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise DisclosurePolicyError("Disclosure policy is missing or unreadable.") from error
    if not raw or len(raw) > MAX_DISCLOSURE_POLICY_BYTES:
        raise DisclosurePolicyError("Disclosure policy is empty or too large.")
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DisclosurePolicyError("Disclosure policy is not valid UTF-8 JSON.") from error
    if not isinstance(decoded, dict) or set(decoded) != {"schema", "projects"}:
        raise DisclosurePolicyError("Disclosure policy has an unexpected root shape.")
    schema = decoded.get("schema")
    if schema not in {DISCLOSURE_POLICY_SCHEMA_V1, DISCLOSURE_POLICY_SCHEMA_V2}:
        raise DisclosurePolicyError("Disclosure policy schema is unsupported.")
    project_rows = decoded.get("projects")
    capacity = (
        MAX_APPROVED_PROJECTS
        if schema == DISCLOSURE_POLICY_SCHEMA_V1
        else MAX_INVENTORY_PROJECTS
    )
    if not isinstance(project_rows, list) or len(project_rows) > capacity:
        raise DisclosurePolicyError("Disclosure policy project list is invalid.")

    projects: list[DisclosureProject] = []
    local_ids: set[str] = set()
    aliases: set[str] = set()
    for row in project_rows:
        allowed_keys = (
            {"projectId", "alias", "label"}
            if schema == DISCLOSURE_POLICY_SCHEMA_V1
            else {
                "projectId",
                "alias",
                "label",
                "access",
                "sourceTitleFingerprint",
            }
        )
        if not isinstance(row, dict) or not set(row).issubset(allowed_keys):
            raise DisclosurePolicyError("Disclosure policy project entry is invalid.")
        required_keys = (
            {"projectId", "alias"}
            if schema == DISCLOSURE_POLICY_SCHEMA_V1
            else {"projectId", "alias", "label", "access"}
        )
        if not required_keys.issubset(row):
            raise DisclosurePolicyError("Disclosure policy project entry is incomplete.")
        local_project_id = row.get("projectId")
        alias = row.get("alias")
        label = row.get("label", alias)
        if (
            not isinstance(local_project_id, str)
            or not local_project_id.strip()
            or len(local_project_id.strip()) < 8
            or len(local_project_id) > 128
            or any(ord(char) < 32 for char in local_project_id)
        ):
            raise DisclosurePolicyError("Disclosure policy local project ID is invalid.")
        if not isinstance(alias, str) or not _ALIAS_RE.fullmatch(alias):
            raise DisclosurePolicyError("Disclosure policy alias is invalid.")
        if (
            not isinstance(label, str)
            or not _LABEL_RE.fullmatch(label)
            or _TOKEN_SHAPED_LABEL_RE.fullmatch(label)
        ):
            raise DisclosurePolicyError("Disclosure policy label is invalid.")
        if schema == DISCLOSURE_POLICY_SCHEMA_V1:
            access = frozenset({"inventory", "detail"})
        else:
            raw_access = row.get("access")
            if (
                not isinstance(raw_access, list)
                or not raw_access
                or any(not isinstance(item, str) for item in raw_access)
                or len(set(raw_access)) != len(raw_access)
                or not set(raw_access).issubset({"inventory", "detail"})
                or "inventory" not in raw_access
            ):
                raise DisclosurePolicyError("Disclosure policy access is invalid.")
            access = frozenset(raw_access)
        source_title_fingerprint = row.get("sourceTitleFingerprint")
        if (
            source_title_fingerprint is not None
            and (
                not isinstance(source_title_fingerprint, str)
                or not _SOURCE_TITLE_FINGERPRINT_RE.fullmatch(
                    source_title_fingerprint
                )
            )
        ):
            raise DisclosurePolicyError(
                "Disclosure policy source title fingerprint is invalid."
            )
        if alias == local_project_id or label == local_project_id:
            raise DisclosurePolicyError(
                "Disclosure policy aliases and labels must not expose local IDs."
            )
        if local_project_id in local_ids or alias in aliases:
            raise DisclosurePolicyError("Disclosure policy contains duplicate projects.")
        local_ids.add(local_project_id)
        aliases.add(alias)
        projects.append(
            DisclosureProject(
                local_project_id=local_project_id,
                alias=alias,
                label=label,
                access=access,
                source_title_fingerprint=source_title_fingerprint,
            )
        )
    for project in projects:
        for local_project_id in local_ids:
            if (
                project.alias == local_project_id
                or project.label == local_project_id
                or (
                    len(local_project_id) >= 8
                    and (
                        local_project_id in project.alias
                        or local_project_id in project.label
                    )
                )
            ):
                raise DisclosurePolicyError(
                    "Disclosure policy aliases and labels must not expose local IDs."
                )
    if sum(project.detail_enabled for project in projects) > MAX_DETAIL_PROJECTS:
        raise DisclosurePolicyError("Disclosure policy detail project list is invalid.")
    return DisclosurePolicy(
        schema=schema,
        projects=tuple(projects),
        digest=hashlib.sha256(raw).hexdigest(),
    )


def remote_tool_contract(name: str) -> dict[str, Any]:
    contract = REMOTE_TOOL_CONTRACTS.get(name)
    if contract is None:
        raise RemoteProjectionError("tool_not_allowed")
    return json.loads(json.dumps(contract))


def prepare_remote_tool_request(
    request: dict[str, Any],
    policy: DisclosurePolicy,
) -> tuple[dict[str, Any], RemoteCallContext]:
    params = request.get("params")
    if not isinstance(params, dict):
        raise RemoteProjectionError("invalid_params")
    name = params.get("name")
    if name not in REMOTE_TOOL_CONTRACTS:
        raise RemoteProjectionError("tool_not_allowed")
    arguments = params.get("arguments", {})
    if not isinstance(arguments, dict):
        raise RemoteProjectionError("invalid_params")

    forwarded: dict[str, Any]
    context: RemoteCallContext
    if name == "list_projects":
        _reject_unknown_keys(arguments, {"offset", "limit", "includeArchived"})
        offset = _bounded_int(arguments.get("offset", 0), minimum=0, maximum=1_000_000)
        limit = _bounded_int(
            arguments.get("limit", DEFAULT_REMOTE_PROJECT_PAGE),
            minimum=1,
            maximum=MAX_REMOTE_PROJECT_PAGE,
        )
        forwarded = {"includeArchived": False}
        context = RemoteCallContext(name, offset=offset, limit=limit)
    elif name in {"get_project_status", "atlas.project_planning_context"}:
        _reject_unknown_keys(arguments, {"projectId"})
        project = _detail_project_for_alias(arguments.get("projectId"), policy)
        forwarded = {"projectId": project.local_project_id}
        context = RemoteCallContext(
            name,
            project=project,
            limit=(
                MAX_REMOTE_PLANNING_ITEMS
                if name == "atlas.project_planning_context"
                else 10
            ),
        )
    else:
        allowed = {
            "projectId",
            "readiness",
            "actor",
            "risk",
            "size",
            "blockedOnly",
            "blocksProgressOnly",
            "reviewNeededOnly",
            "staleOnly",
            "highPriorityOnly",
            "limit",
        }
        _reject_unknown_keys(arguments, allowed)
        forwarded = {}
        project = None
        if "projectId" in arguments:
            project = _detail_project_for_alias(arguments.get("projectId"), policy)
            forwarded["projectId"] = project.local_project_id
        for key in ("readiness", "actor", "risk", "size"):
            if key in arguments:
                forwarded[key] = _required_enum(
                    arguments[key], WORKLOAD_FILTER_VALUES[key]
                )
        for key in (
            "blockedOnly",
            "blocksProgressOnly",
            "reviewNeededOnly",
            "staleOnly",
            "highPriorityOnly",
        ):
            if key in arguments:
                if not isinstance(arguments[key], bool):
                    raise RemoteProjectionError("invalid_params")
                forwarded[key] = arguments[key]
        limit = _bounded_int(
            arguments.get("limit", 10),
            minimum=1,
            maximum=MAX_REMOTE_WORKLOAD_ITEMS,
            clamp_max=True,
        )
        forwarded["limit"] = limit
        context = RemoteCallContext(name, project=project, limit=limit)

    prepared = {
        "jsonrpc": "2.0",
        "id": request.get("id"),
        "method": "tools/call",
        "params": {"name": name, "arguments": forwarded},
    }
    return prepared, context


def attach_remote_project_visibility(
    response: dict[str, Any],
    context: RemoteCallContext,
    policy: DisclosurePolicy,
) -> RemoteCallContext:
    """Bind a workload call to the current non-archived approved project set."""

    if context.tool != "atlas.workload_snapshot":
        raise RemoteProjectionError("invalid_visibility_context")
    payload = _extract_inner_payload(response)
    if not isinstance(payload, list):
        raise RemoteProjectionError("invalid_upstream_shape")
    approved_ids = policy.detail_by_local_id
    visible: set[str] = set()
    for row in payload:
        if not isinstance(row, dict):
            raise RemoteProjectionError("invalid_upstream_shape")
        local_project_id = row.get("id")
        if not isinstance(local_project_id, str):
            raise RemoteProjectionError("invalid_upstream_shape")
        if local_project_id not in approved_ids:
            continue
        status = _safe_enum(row.get("status"), PROJECT_STATUSES)
        if status in REMOTE_VISIBLE_PROJECT_STATUSES:
            visible.add(local_project_id)
    if (
        context.project is not None
        and context.project.local_project_id not in visible
    ):
        raise RemoteProjectionError("not_found")
    return RemoteCallContext(
        tool=context.tool,
        project=context.project,
        offset=context.offset,
        limit=context.limit,
        visible_local_project_ids=frozenset(visible),
    )


def project_remote_tool_response(
    response: dict[str, Any],
    context: RemoteCallContext,
    policy: DisclosurePolicy,
    *,
    max_response_bytes: int,
    scrubber: Callable[[Any], Any] | None = None,
) -> ProjectionOutcome:
    payload = _extract_inner_payload(response)
    if context.tool == "list_projects":
        projected, item_count = _project_list_projects(payload, context, policy)
    elif context.tool == "get_project_status":
        projected, item_count = _project_status(payload, context)
    elif context.tool == "atlas.workload_snapshot":
        projected, item_count = _project_workload(payload, context, policy)
    elif context.tool == "atlas.project_planning_context":
        projected, item_count = _project_planning_context(payload, context)
    else:
        raise RemoteProjectionError("tool_not_allowed")

    if scrubber is not None:
        projected = scrubber(projected)
    _reject_local_identifiers(projected, policy)
    text = json.dumps(projected, separators=(",", ":"), sort_keys=True)
    rebuilt = {
        "jsonrpc": "2.0",
        "id": response.get("id"),
        "result": {
            "content": [{"type": "text", "text": text}],
            "isError": False,
        },
    }
    response_bytes = len(
        json.dumps(rebuilt, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    if response_bytes > max_response_bytes:
        raise RemoteProjectionError("response_too_large")
    return ProjectionOutcome(rebuilt, response_bytes, item_count)


def _extract_inner_payload(response: dict[str, Any]) -> Any:
    if not isinstance(response, dict) or "error" in response:
        raise RemoteProjectionError("upstream_error")
    result = response.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("isError"), bool):
        raise RemoteProjectionError("invalid_upstream_shape")
    if result["isError"]:
        raise RemoteProjectionError("upstream_error")
    content = result.get("content")
    if not isinstance(content, list) or len(content) != 1:
        raise RemoteProjectionError("invalid_upstream_shape")
    block = content[0]
    if (
        not isinstance(block, dict)
        or block.get("type") != "text"
        or not isinstance(block.get("text"), str)
    ):
        raise RemoteProjectionError("invalid_upstream_shape")
    try:
        return json.loads(block["text"])
    except json.JSONDecodeError as error:
        raise RemoteProjectionError("invalid_upstream_json") from error


def _project_list_projects(
    payload: Any,
    context: RemoteCallContext,
    policy: DisclosurePolicy,
) -> tuple[dict[str, Any], int]:
    if not isinstance(payload, list):
        raise RemoteProjectionError("invalid_upstream_shape")
    by_local = policy.inventory_by_local_id
    approved: list[dict[str, Any]] = []
    for row in payload:
        if not isinstance(row, dict):
            raise RemoteProjectionError("invalid_upstream_shape")
        local_project_id = row.get("id")
        if not isinstance(local_project_id, str):
            raise RemoteProjectionError("invalid_upstream_shape")
        project = by_local.get(local_project_id)
        if project is None:
            continue
        status = _safe_enum(row.get("status"), PROJECT_STATUSES)
        if status not in REMOTE_VISIBLE_PROJECT_STATUSES:
            continue
        approved.append(_project_inventory_summary(row, project))
    approved.sort(key=lambda row: str(row["projectId"]))
    total = len(approved)
    page = approved[context.offset : context.offset + context.limit]
    projected = {
        "schema": "project_atlas.remote_project_inventory.v3",
        "projects": page,
        "page": {
            "offset": context.offset,
            "limit": context.limit,
            "returned": len(page),
            "total": total,
            "truncated": context.offset + len(page) < total,
            "nextOffset": (
                context.offset + len(page)
                if context.offset + len(page) < total
                else None
            ),
        },
        "disclosure": dict(REMOTE_SCOPE_NOTICE),
    }
    return projected, len(page)


def _project_status(
    payload: Any,
    context: RemoteCallContext,
) -> tuple[dict[str, Any], int]:
    project = context.project
    if project is None or payload is None:
        raise RemoteProjectionError("not_found")
    if not isinstance(payload, dict) or payload.get("id") != project.local_project_id:
        raise RemoteProjectionError("invalid_upstream_shape")
    if (
        _safe_enum(payload.get("status"), PROJECT_STATUSES)
        not in REMOTE_VISIBLE_PROJECT_STATUSES
    ):
        raise RemoteProjectionError("not_found")
    return (
        {
            "schema": "project_atlas.remote_project_status.v2",
            "project": _project_status_summary(payload, project),
        },
        1,
    )


def _project_status_summary(
    row: dict[str, Any], project: DisclosureProject
) -> dict[str, Any]:
    if row.get("id", row.get("projectId")) != project.local_project_id:
        raise RemoteProjectionError("invalid_upstream_shape")
    status = _safe_enum(row.get("status"), PROJECT_STATUSES)
    freshness = _freshness_summary(row.get("freshness"))
    blocked = _safe_optional_count(row.get("blockedWorkItems"))
    blocks_progress = _safe_optional_count(row.get("blocksProgressWorkItems"))
    if blocks_progress is None:
        blocks_progress = blocked
    signals = _signal_summary(status, freshness, blocks_progress)
    return {
        "projectId": project.alias,
        "title": project.label,
        "status": status,
        "phase": _safe_enum(row.get("phase"), PROJECT_PHASES),
        "priority": _safe_enum(row.get("priority"), PRIORITIES),
        "workItems": {
            "active": _safe_optional_count(row.get("activeWorkItems")),
            "blocked": blocked,
            "blocksProgress": blocks_progress,
        },
        "records": {
            "documents": _safe_optional_count(row.get("documents")),
            "media": _safe_optional_count(row.get("media")),
            "risks": _safe_optional_count(row.get("risks")),
            "decisions": _safe_optional_count(row.get("decisions")),
        },
        "freshness": freshness,
        "signals": signals,
        "needsAttention": signals["planningActionRequired"],
    }


def _project_inventory_summary(
    row: dict[str, Any], project: DisclosureProject
) -> dict[str, Any]:
    if row.get("id", row.get("projectId")) != project.local_project_id:
        raise RemoteProjectionError("invalid_upstream_shape")
    status = _safe_enum(row.get("status"), PROJECT_STATUSES)
    freshness = _freshness_summary(row.get("freshness"))
    blocked = _safe_optional_count(row.get("blockedWorkItems"))
    blocks_progress = _safe_optional_count(row.get("blocksProgressWorkItems"))
    if blocks_progress is None:
        blocks_progress = blocked
    signals = _signal_summary(status, freshness, blocks_progress)
    return {
        "projectId": project.alias,
        "title": project.label,
        "status": status,
        "phase": _safe_enum(row.get("phase"), PROJECT_PHASES),
        "priority": _safe_enum(row.get("priority"), PRIORITIES),
        "needsAttention": signals["planningActionRequired"],
        "freshness": {"status": freshness["status"]},
        "signals": signals,
        "workItems": {
            "active": _safe_optional_count(row.get("activeWorkItems")),
            "blocked": blocked,
            "blocksProgress": blocks_progress,
        },
        "detailsAvailable": project.detail_enabled,
    }


def _freshness_summary(value: Any) -> dict[str, Any]:
    source = value if isinstance(value, dict) else {}
    status = _safe_enum(source.get("status"), FRESHNESS_STATUSES)
    stale_reasons = _safe_enum_list(
        source.get("staleReasons"), FRESHNESS_REASON_VALUES
    )
    attention_reasons = _safe_enum_list(
        source.get("attentionReasons"), FRESHNESS_REASON_VALUES
    )
    data_refresh_required = (
        status in {"stale", "unknown"}
        or bool(stale_reasons)
        or any(reason not in PLANNING_REASON_VALUES for reason in attention_reasons)
    )
    return {
        "status": status,
        "confidence": _safe_enum(source.get("confidence"), CONFIDENCE_VALUES),
        "staleReasons": stale_reasons,
        "attentionReasons": attention_reasons,
        "dataRefreshRequired": data_refresh_required,
    }


def _signal_summary(
    project_status: str,
    freshness: dict[str, Any],
    blocks_progress: int | None,
) -> dict[str, Any]:
    stale_reasons = freshness["staleReasons"]
    attention_reasons = freshness["attentionReasons"]
    planning_action_required = (
        project_status in ATTENTION_PROJECT_STATUSES
        or any(reason in PLANNING_REASON_VALUES for reason in attention_reasons)
        or bool(blocks_progress)
    )
    data_refresh_required = freshness["dataRefreshRequired"]
    reason_classes = _signal_reason_classes(
        project_status=project_status,
        freshness_status=freshness["status"],
        stale_reasons=stale_reasons,
        attention_reasons=attention_reasons,
        blocks_progress=blocks_progress,
    )
    severity = _signal_severity(
        project_status=project_status,
        freshness_status=freshness["status"],
        attention_reasons=attention_reasons,
        blocks_progress=blocks_progress,
        planning_action_required=planning_action_required,
        data_refresh_required=data_refresh_required,
    )
    return {
        "planningActionRequired": planning_action_required,
        "dataRefreshRequired": data_refresh_required,
        "severity": severity,
        "reasonClasses": reason_classes,
    }


def _signal_reason_classes(
    *,
    project_status: str,
    freshness_status: str,
    stale_reasons: list[str],
    attention_reasons: list[str],
    blocks_progress: int | None,
) -> list[str]:
    reasons = {*stale_reasons, *attention_reasons}
    classes: set[str] = set()
    if project_status in ATTENTION_PROJECT_STATUSES or any(
        reason.startswith("project_status_") for reason in reasons
    ):
        classes.add("lifecycle")
    if blocks_progress or reasons.intersection(
        {"blocked_work_items", "high_priority_without_active_work"}
    ):
        classes.add("workload")
    if any(
        reason.startswith(
            (
                "missing_local_",
                "linked_registry_",
                "invalid_local_",
                "old_local_",
            )
        )
        or reason == "local_dirty_state"
        for reason in reasons
    ):
        classes.add("local_evidence")
    if any(
        reason.startswith("github_") or reason == "old_github_check"
        for reason in reasons
    ):
        classes.add("remote_evidence")
    if any(reason.startswith("capsule_") for reason in reasons):
        classes.add("capsule")
    if freshness_status == "stale":
        classes.add("freshness_stale")
    elif freshness_status == "unknown":
        classes.add("freshness_unknown")
    return sorted(classes.intersection(SIGNAL_REASON_CLASSES))


def _signal_severity(
    *,
    project_status: str,
    freshness_status: str,
    attention_reasons: list[str],
    blocks_progress: int | None,
    planning_action_required: bool,
    data_refresh_required: bool,
) -> str:
    reasons = set(attention_reasons)
    if (
        blocks_progress
        or project_status == "blocked"
        or reasons.intersection({"blocked_work_items", "capsule_errors"})
    ):
        return "high"
    if planning_action_required or freshness_status == "unknown":
        return "medium"
    if data_refresh_required:
        return "low"
    return "none"


def _project_workload(
    payload: Any,
    context: RemoteCallContext,
    policy: DisclosurePolicy,
) -> tuple[dict[str, Any], int]:
    if not isinstance(payload, dict) or not isinstance(payload.get("cards"), list):
        raise RemoteProjectionError("invalid_upstream_shape")
    if context.visible_local_project_ids is None:
        raise RemoteProjectionError("invalid_visibility_context")
    approved_cards = _approved_cards(payload["cards"], context, policy)
    execution = _project_card_list(
        payload.get("executionCandidates"), context, policy, context.limit
    )
    planning = _project_card_list(
        payload.get("planningCandidateItems"), context, policy, context.limit
    )
    review = _project_card_list(
        payload.get("reviewNeededItems"), context, policy, context.limit
    )
    projected = {
        "schema": "project_atlas.remote_workload_snapshot.v2",
        "generatedAt": _projection_timestamp(payload.get("generatedAt")),
        "scope": {
            "projectId": context.project_alias,
            "title": context.project.label if context.project is not None else None,
        },
        "counts": _recomputed_workload_counts(approved_cards),
        "executionCandidates": execution,
        "planningCandidateItems": planning,
        "reviewNeededItems": review,
        "returned": {
            "execution": len(execution),
            "planning": len(planning),
            "review": len(review),
        },
        "truncated": _workload_lists_truncated(
            approved_cards,
            execution_count=len(execution),
            planning_count=len(planning),
            review_count=len(review),
            project_scoped=context.project is not None,
        ),
    }
    return projected, len(execution) + len(planning) + len(review)


def _approved_cards(
    value: Any,
    context: RemoteCallContext,
    policy: DisclosurePolicy,
) -> list[tuple[dict[str, Any], DisclosureProject]]:
    if not isinstance(value, list):
        raise RemoteProjectionError("invalid_upstream_shape")
    approved: list[tuple[dict[str, Any], DisclosureProject]] = []
    by_local = policy.detail_by_local_id
    for row in value:
        if not isinstance(row, dict):
            raise RemoteProjectionError("invalid_upstream_shape")
        local_project_id = row.get("projectId")
        if not isinstance(local_project_id, str):
            raise RemoteProjectionError("invalid_upstream_shape")
        project = by_local.get(local_project_id)
        if project is None:
            continue
        if local_project_id not in context.visible_local_project_ids:
            continue
        if context.project is not None and project != context.project:
            continue
        approved.append((row, project))
    return approved


def _project_card_list(
    value: Any,
    context: RemoteCallContext,
    policy: DisclosurePolicy,
    limit: int,
) -> list[dict[str, Any]]:
    return [
        _project_card(row, project)
        for row, project in _approved_cards(value, context, policy)[:limit]
    ]


def _project_card(
    row: dict[str, Any], project: DisclosureProject
) -> dict[str, Any]:
    return {
        "projectId": project.alias,
        "projectTitle": project.label,
        "kind": _safe_enum(row.get("kind"), WORKLOAD_KIND_VALUES),
        "readiness": _safe_enum(
            row.get("readiness"), WORKLOAD_READINESS_VALUES
        ),
        "boardGroup": _safe_enum(
            row.get("boardGroup"), WORKLOAD_BOARD_GROUPS
        ),
        "size": _safe_enum(row.get("size"), WORKLOAD_SIZE_VALUES),
        "risk": _safe_enum(row.get("risk"), WORKLOAD_RISK_VALUES),
        "suggestedActor": _safe_enum(
            row.get("suggestedActor"), WORKLOAD_ACTOR_VALUES
        ),
        "verificationNeeded": _safe_enum(
            row.get("verificationNeeded"), WORKLOAD_VERIFICATION_VALUES
        ),
        "priority": _safe_enum(row.get("priority"), PRIORITIES),
        "status": _safe_enum(row.get("status"), WORKLOAD_STATUS_VALUES),
        "blocksProgress": (
            row.get("blocksProgress")
            if isinstance(row.get("blocksProgress"), bool)
            else None
        ),
        "stale": row.get("stale") if isinstance(row.get("stale"), bool) else None,
        "staleReasons": _safe_enum_list(
            row.get("staleReasons"), WORKLOAD_STALE_REASON_VALUES
        ),
        "originKind": _safe_enum(
            row.get("originKind"), WORKLOAD_ORIGIN_VALUES
        ),
    }


def _recomputed_workload_counts(
    cards: list[tuple[dict[str, Any], DisclosureProject]],
) -> dict[str, int]:
    rows = [row for row, _project in cards]
    return {
        "total": len(rows),
        "ready": sum(row.get("boardGroup") == "ready" for row in rows),
        "blocked": sum(row.get("boardGroup") == "blocked" for row in rows),
        "blockedBoardGroup": sum(
            row.get("boardGroup") == "blocked" for row in rows
        ),
        "blocksProgress": sum(row.get("blocksProgress") is True for row in rows),
        "reviewNeeded": sum(
            row.get("boardGroup") == "review_needed" for row in rows
        ),
        "stale": sum(row.get("stale") is True for row in rows),
        "importedChecklist": sum(
            row.get("originKind") == "imported_checklist" for row in rows
        ),
        "workItems": sum(row.get("kind") == "work_item" for row in rows),
        "llmQueueItems": sum(
            row.get("kind") == "llm_queue_item" for row in rows
        ),
    }


def _workload_lists_truncated(
    cards: list[tuple[dict[str, Any], DisclosureProject]],
    *,
    execution_count: int,
    planning_count: int,
    review_count: int,
    project_scoped: bool,
) -> bool:
    rows = [row for row, _project in cards]
    available_execution = sum(
        row.get("boardGroup") == "ready"
        and (
            project_scoped
            or row.get("originKind") != "imported_checklist"
        )
        for row in rows
    )
    available_planning = sum(
        row.get("boardGroup") == "needs_decision"
        and row.get("readiness") in {"needs_decision", "needs_context"}
        for row in rows
    )
    available_review = sum(
        row.get("boardGroup") == "review_needed" for row in rows
    )
    return (
        available_execution > execution_count
        or available_planning > planning_count
        or available_review > review_count
    )


def _project_planning_context(
    payload: Any,
    context: RemoteCallContext,
) -> tuple[dict[str, Any], int]:
    project = context.project
    if project is None or payload is None:
        raise RemoteProjectionError("not_found")
    if not isinstance(payload, dict):
        raise RemoteProjectionError("invalid_upstream_shape")
    project_source = payload.get("project")
    workload = payload.get("workload")
    if (
        not isinstance(project_source, dict)
        or project_source.get("projectId") != project.local_project_id
        or not isinstance(workload, dict)
    ):
        raise RemoteProjectionError("invalid_upstream_shape")
    project_status = _safe_enum(project_source.get("status"), PROJECT_STATUSES)
    if project_status not in REMOTE_VISIBLE_PROJECT_STATUSES:
        raise RemoteProjectionError("not_found")
    counts = workload.get("counts") if isinstance(workload.get("counts"), dict) else {}
    ready = _planning_card_list(workload.get("readyItems"), project, context.limit)
    planning = _planning_card_list(
        workload.get("planningCandidateItems"), project, context.limit
    )
    review = _planning_card_list(
        workload.get("reviewNeededItems"), project, context.limit
    )
    blocked = _planning_card_list(workload.get("blockedItems"), project, context.limit)
    safe_constraints = payload.get("safeConstraints")
    verification = payload.get("verification")
    freshness = _freshness_summary(project_source.get("freshness"))
    signals = _signal_summary(
        project_status,
        freshness,
        _safe_optional_count(project_source.get("blocksProgressWorkItems")),
    )
    projected = {
        "schema": "project_atlas.remote_planning_context.v2",
        "generatedAt": _projection_timestamp(payload.get("generatedAt")),
        "project": {
            "projectId": project.alias,
            "title": project.label,
            "status": project_status,
            "phase": _safe_enum(project_source.get("phase"), PROJECT_PHASES),
            "priority": _safe_enum(project_source.get("priority"), PRIORITIES),
            "needsAttention": signals["planningActionRequired"],
            "freshness": freshness,
            "signals": signals,
        },
        "workload": {
            "counts": {
                key: _safe_optional_count(counts.get(key))
                for key in (
                    "total",
                    "ready",
                    "blocked",
                    "blockedBoardGroup",
                    "blocksProgress",
                    "reviewNeeded",
                    "stale",
                    "demotedImportedChecklist",
                    "workItems",
                    "llmQueueItems",
                )
            },
            "executionCandidates": ready,
            "planningCandidateItems": planning,
            "reviewNeededItems": review,
            "blockedItems": blocked,
            "truncated": (
                any(
                    len(items) >= context.limit
                    for items in (ready, planning, review, blocked)
                )
                or _count_exceeds(counts.get("ready"), len(ready))
                or _count_exceeds(counts.get("blocked"), len(blocked))
                or _count_exceeds(counts.get("blocksProgress"), len(blocked))
                or _count_exceeds(counts.get("reviewNeeded"), len(review))
            ),
        },
        "safeConstraints": _safe_constraints(safe_constraints),
        "verification": {
            "categories": _safe_enum_list(
                verification.get("workloadVerificationNeeded")
                if isinstance(verification, dict)
                else None,
                WORKLOAD_VERIFICATION_VALUES,
            )
        },
        "integrityNotice": (
            "Accepted-truth claims, commands, free-text notes, and evidence excerpts "
            "are withheld pending semantic hardening."
        ),
    }
    item_count = len(ready) + len(planning) + len(review) + len(blocked)
    return projected, item_count


def _planning_card_list(
    value: Any,
    project: DisclosureProject,
    limit: int,
) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise RemoteProjectionError("invalid_upstream_shape")
    result = []
    for row in value[:limit]:
        if not isinstance(row, dict):
            raise RemoteProjectionError("invalid_upstream_shape")
        if "projectId" in row and row.get("projectId") != project.local_project_id:
            raise RemoteProjectionError("invalid_upstream_shape")
        result.append(_project_card(row, project))
    return result


def _safe_constraints(value: Any) -> dict[str, bool]:
    source = value if isinstance(value, dict) else {}
    keys = (
        "humanFinal",
        "noDirectFileMutationByChatGPT",
        "noRemoteWriteTools",
        "noQueueClaimOrComplete",
        "noProjectBriefExposureByDefault",
        "noRawLocalPaths",
        "noSecrets",
        "noToolBus",
        "noCloudAdapter",
        "noAutonomousExecution",
    )
    return {key: source.get(key) is True for key in keys}


def _reject_unknown_keys(value: dict[str, Any], allowed: set[str]) -> None:
    if not set(value).issubset(allowed):
        raise RemoteProjectionError("invalid_params")


def _detail_project_for_alias(
    value: Any, policy: DisclosurePolicy
) -> DisclosureProject:
    if not isinstance(value, str) or not _ALIAS_RE.fullmatch(value):
        raise RemoteProjectionError("not_found")
    project = policy.detail_by_alias.get(value)
    if project is None:
        raise RemoteProjectionError("not_found")
    return project


def _required_enum(value: Any, allowed: frozenset[str]) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise RemoteProjectionError("invalid_params")
    return value


def _bounded_int(
    value: Any,
    *,
    minimum: int,
    maximum: int,
    clamp_max: bool = False,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise RemoteProjectionError("invalid_params")
    if value > maximum:
        if clamp_max:
            return maximum
        raise RemoteProjectionError("invalid_params")
    return value


def _safe_enum(value: Any, allowed: frozenset[str]) -> str:
    return value if isinstance(value, str) and value in allowed else "unknown"


def _safe_enum_list(value: Any, allowed: frozenset[str]) -> list[str]:
    if not isinstance(value, list):
        return []
    result = {item for item in value if isinstance(item, str) and item in allowed}
    return sorted(result)[:32]


def _count_exceeds(value: Any, returned: int) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, int)
        and value > returned
    )


def _safe_optional_count(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return min(value, 2_147_483_647)


def _safe_timestamp(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > 40:
        return None
    if not (value.endswith("Z") or re.search(r"[+-]\d\d:\d\d$", value)):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.year < 2000 or parsed.year > 2100:
        return None
    return parsed.isoformat().replace("+00:00", "Z")


def _projection_timestamp(value: Any) -> str:
    return _safe_timestamp(value) or datetime.now(timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def _reject_local_identifiers(value: Any, policy: DisclosurePolicy) -> None:
    local_ids = tuple(policy.all_local_project_ids)

    def visit(item: Any) -> bool:
        if isinstance(item, dict):
            return any(visit(child) for child in item.values())
        if isinstance(item, list):
            return any(visit(child) for child in item)
        if not isinstance(item, str):
            return False
        return any(
            item == local_id or (len(local_id) >= 8 and local_id in item)
            for local_id in local_ids
        )

    if visit(value):
        raise RemoteProjectionError("local_identifier_exposed")
