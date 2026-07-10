from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

try:
    from atlas_mcp_remote_policy import (
        DISCLOSURE_POLICY_SCHEMA,
        DisclosurePolicyError,
        RemoteCallContext,
        RemoteProjectionError,
        attach_remote_project_visibility,
        load_disclosure_policy,
        prepare_remote_tool_request,
        project_remote_tool_response,
        remote_tool_contract,
    )
except ModuleNotFoundError:
    from tools.atlas_mcp_remote_policy import (
        DISCLOSURE_POLICY_SCHEMA,
        DisclosurePolicyError,
        RemoteCallContext,
        RemoteProjectionError,
        attach_remote_project_visibility,
        load_disclosure_policy,
        prepare_remote_tool_request,
        project_remote_tool_response,
        remote_tool_contract,
    )

try:
    from atlas_mcp_gateway import (
        DisclosureAuditLog,
        StdioMcpClient,
        StdioOutputLimitError,
        filter_tools,
        run_process_bounded,
    )
except ModuleNotFoundError:
    from tools.atlas_mcp_gateway import (
        DisclosureAuditLog,
        StdioMcpClient,
        StdioOutputLimitError,
        filter_tools,
        run_process_bounded,
    )


def wire(payload: object, *, is_error: bool = False) -> dict[str, object]:
    return {
        "jsonrpc": "2.0",
        "id": 7,
        "result": {
            "content": [{"type": "text", "text": json.dumps(payload)}],
            "isError": is_error,
        },
    }


def decode_projected(response: dict[str, object]) -> object:
    result = response["result"]
    assert isinstance(result, dict)
    content = result["content"]
    assert isinstance(content, list)
    return json.loads(content[0]["text"])


class RemotePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.policy_path = Path(self.temp.name) / "policy.json"
        self.policy_path.write_text(
            json.dumps(
                {
                    "schema": DISCLOSURE_POLICY_SCHEMA,
                    "projects": [
                        {
                            "projectId": "local-approved",
                            "alias": "approved-project",
                            "label": "Approved Project",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.policy = load_disclosure_policy(self.policy_path)
        self.approved = self.policy.projects[0]

    def test_policy_rejects_unknown_keys_duplicates_and_bad_aliases(self) -> None:
        invalid_documents = [
            {
                "schema": DISCLOSURE_POLICY_SCHEMA,
                "projects": [],
                "exposeAll": True,
            },
            {
                "schema": DISCLOSURE_POLICY_SCHEMA,
                "projects": [
                    {"projectId": "one", "alias": "same"},
                    {"projectId": "two", "alias": "same"},
                ],
            },
            {
                "schema": DISCLOSURE_POLICY_SCHEMA,
                "projects": [{"projectId": "one", "alias": "Bad Alias"}],
            },
            {
                "schema": DISCLOSURE_POLICY_SCHEMA,
                "projects": [{"projectId": "same-id", "alias": "same-id"}],
            },
        ]
        for index, document in enumerate(invalid_documents):
            path = Path(self.temp.name) / f"invalid-{index}.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.subTest(index=index), self.assertRaises(DisclosurePolicyError):
                load_disclosure_policy(path)

    def test_request_rewrite_uses_aliases_and_forces_archived_false(self) -> None:
        list_request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "list_projects",
                "arguments": {"includeArchived": True, "offset": 2, "limit": 999},
            },
        }
        prepared, context = prepare_remote_tool_request(list_request, self.policy)
        self.assertEqual(
            prepared["params"],
            {"name": "list_projects", "arguments": {"includeArchived": False}},
        )
        self.assertEqual(context.offset, 2)
        self.assertEqual(context.limit, 25)

        status_request = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "get_project_status",
                "arguments": {"projectId": "approved-project"},
            },
        }
        prepared, context = prepare_remote_tool_request(status_request, self.policy)
        self.assertEqual(
            prepared["params"]["arguments"], {"projectId": "local-approved"}
        )
        self.assertEqual(context.project_alias, "approved-project")

        for identifier in ("local-approved", "hidden-project", "Approved-Project"):
            status_request["params"]["arguments"]["projectId"] = identifier
            with self.subTest(identifier=identifier), self.assertRaises(
                RemoteProjectionError
            ) as caught:
                prepare_remote_tool_request(status_request, self.policy)
            self.assertEqual(caught.exception.code, "not_found")

    def test_tools_list_contract_is_rebuilt_from_fixed_metadata(self) -> None:
        contract = remote_tool_contract("list_projects")
        self.assertEqual(set(contract), {"description", "inputSchema"})
        self.assertNotIn("includeArchived", contract["inputSchema"]["properties"])
        self.assertFalse(contract["inputSchema"]["additionalProperties"])

        projected = filter_tools(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "privateRoot": "PRIVATE_ROOT",
                "result": {
                    "privateResult": "PRIVATE_RESULT",
                    "tools": [
                        {
                            "name": "list_projects",
                            "description": "PRIVATE_DESCRIPTION",
                            "inputSchema": {"private": True},
                            "_meta": {"private": "PRIVATE_META"},
                        },
                        {"name": "get_project_brief"},
                    ],
                },
            },
            {"list_projects"},
        )
        self.assertEqual(set(projected), {"jsonrpc", "id", "result"})
        self.assertEqual(set(projected["result"]), {"tools"})
        tool = projected["result"]["tools"][0]
        self.assertEqual(tool["description"], contract["description"])
        self.assertNotIn("PRIVATE", json.dumps(projected))

        malformed = [
            {},
            {"error": {"data": "PRIVATE_ERROR"}},
            {"result": {}},
            {"result": {"tools": "not-a-list"}},
            {"result": {"tools": [{"description": "missing name"}]}},
            {"result": {"tools": [{"name": "get_project_brief"}]}},
        ]
        for index, response in enumerate(malformed):
            with self.subTest(index=index), self.assertRaises(
                RemoteProjectionError
            ):
                filter_tools(response, {"list_projects"})

    def test_initialize_is_rebuilt_from_fixed_metadata(self) -> None:
        client = StdioMcpClient(Path("unused.exe"), timeout=1)
        client._run_stdio = lambda *_args, **_kwargs: {  # type: ignore[method-assign]
            "jsonrpc": "2.0",
            "id": 4,
            "result": {
                "protocolVersion": "PRIVATE_VERSION",
                "serverInfo": {
                    "name": "PRIVATE_NAME",
                    "token": "PRIVATE_TOKEN",
                },
                "privateRoot": "PRIVATE_ROOT",
            },
        }
        response = client._initialize({"jsonrpc": "2.0", "id": 4})
        self.assertEqual(set(response), {"jsonrpc", "id", "result"})
        result = response["result"]
        self.assertEqual(
            set(result),
            {
                "protocolVersion",
                "serverInfo",
                "capabilities",
                "instructions",
                "_meta",
            },
        )
        self.assertNotIn("PRIVATE", json.dumps(response))

    def test_stdio_runner_enforces_stdout_and_stderr_caps(self) -> None:
        commands = [
            [
                sys.executable,
                "-c",
                "import sys; sys.stdout.buffer.write(b'x' * 4096)",
            ],
            [
                sys.executable,
                "-c",
                "import sys; sys.stderr.buffer.write(b'x' * 4096)",
            ],
        ]
        for index, command in enumerate(commands):
            with self.subTest(index=index), self.assertRaises(
                StdioOutputLimitError
            ):
                run_process_bounded(
                    command,
                    "",
                    timeout=5,
                    stdout_limit=1024,
                    stderr_limit=1024,
                )

    def test_disclosure_audit_contains_only_safe_metadata(self) -> None:
        audit_path = Path(self.temp.name) / "audit.jsonl"
        audit = DisclosureAuditLog(audit_path, self.policy.digest)
        audit.record(
            correlation_id="generated-correlation-id",
            tool="get_project_status",
            project_alias="approved-project",
            decision="allowed",
            outcome="ok",
            item_count=1,
            response_bytes=512,
            duration_ms=4,
        )
        event = json.loads(audit_path.read_text(encoding="utf-8"))
        self.assertEqual(
            set(event),
            {
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
            },
        )
        encoded = json.dumps(event)
        for forbidden in ("local-approved", "token", "arguments", "payload"):
            self.assertNotIn(forbidden, encoded)

    def test_list_projects_filters_hidden_rows_and_unknown_fields(self) -> None:
        payload = [
            {
                "id": "local-approved",
                "title": "Private Source Title",
                "status": "active",
                "phase": "build",
                "priority": "high",
                "activeWorkItems": 3,
                "blockedWorkItems": 1,
                "documents": 20,
                "media": 4,
                "risks": 2,
                "decisions": 1,
                "needsAttention": True,
                "owner": "PRIVATE_OWNER",
                "githubRemote": {"rawJson": "PRIVATE_RAW_JSON"},
                "__unexpected__": "PRIVATE_UNKNOWN",
                "freshness": {
                    "status": "stale",
                    "confidence": "low",
                    "staleReasons": ["old_github_check"],
                    "attentionReasons": ["blocked_work_items"],
                    "actionRequiredBeforePlanning": (
                        "Run PRIVATE_COMMAND from B:\\private with PRIVATE_TOKEN"
                    ),
                    "localObservation": {"path": "B:\\private"},
                },
            },
            {
                "id": "hidden-local",
                "title": "Hidden Project",
                "status": "active",
            },
        ]
        context = RemoteCallContext("list_projects", offset=0, limit=10)
        outcome = project_remote_tool_response(
            wire(payload), context, self.policy, max_response_bytes=65_536
        )
        projected = decode_projected(outcome.response)
        self.assertEqual(
            set(projected), {"schema", "projects", "page"}
        )
        self.assertEqual(len(projected["projects"]), 1)
        project = projected["projects"][0]
        self.assertEqual(
            set(project),
            {
                "projectId",
                "title",
                "status",
                "phase",
                "priority",
                "workItems",
                "records",
                "freshness",
                "needsAttention",
            },
        )
        self.assertEqual(project["projectId"], "approved-project")
        self.assertEqual(project["title"], "Approved Project")
        self.assertEqual(
            set(project["freshness"]),
            {
                "status",
                "confidence",
                "staleReasons",
                "attentionReasons",
                "planningActionRequired",
            },
        )
        self.assertIs(project["freshness"]["planningActionRequired"], True)
        encoded = json.dumps(projected)
        for forbidden in (
            "local-approved",
            "Private Source Title",
            "PRIVATE_OWNER",
            "PRIVATE_RAW_JSON",
            "PRIVATE_UNKNOWN",
            "Hidden Project",
            "B:\\private",
            "PRIVATE_COMMAND",
            "PRIVATE_TOKEN",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_status_projection_has_exact_compact_shape(self) -> None:
        payload = {
            "id": "local-approved",
            "title": "Source title",
            "status": "active",
            "phase": "build",
            "priority": "high",
            "activeWorkItems": 2,
            "blockedWorkItems": 0,
            "documents": 4,
            "media": 5,
            "risks": 1,
            "decisions": 2,
            "needsAttention": False,
            "freshness": {
                "status": "unknown",
                "confidence": "missing",
                "staleReasons": ["missing_local_observation"],
                "attentionReasons": [],
                "actionRequiredBeforePlanning": "PRIVATE_STATUS_ACTION token123",
                "github": {"onlineHeadSha": "abc123"},
            },
        }
        context = RemoteCallContext("get_project_status", project=self.approved)
        outcome = project_remote_tool_response(
            wire(payload), context, self.policy, max_response_bytes=65_536
        )
        projected = decode_projected(outcome.response)
        self.assertEqual(set(projected), {"schema", "project"})
        encoded = json.dumps(projected)
        self.assertNotIn("abc123", encoded)
        self.assertNotIn("PRIVATE_STATUS_ACTION", encoded)

    def test_workload_projection_recomputes_approved_counts_and_omits_text(self) -> None:
        approved_card = {
            "id": "private-item-id",
            "projectId": "local-approved",
            "projectTitle": "Private title",
            "title": "Secret task text",
            "kind": "work_item",
            "readiness": "ready",
            "boardGroup": "ready",
            "size": "small",
            "risk": "docs_only",
            "suggestedActor": "codex",
            "verificationNeeded": "tests",
            "priority": "high",
            "status": "next",
            "stale": False,
            "staleReasons": [],
            "originKind": "manual",
            "notes": "token=PRIVATE_TOKEN",
        }
        hidden_card = dict(approved_card, projectId="hidden-local", title="Hidden")
        payload = {
            "schema": "atlas.workload_snapshot.v1",
            "generatedAt": "2026-07-09T22:00:00Z",
            "counts": {"total": 999, "ready": 999},
            "cards": [approved_card, hidden_card],
            "executionCandidates": [approved_card, hidden_card],
            "planningCandidateItems": [],
            "reviewNeededItems": [],
            "suggestedNextItems": [approved_card],
        }
        context = RemoteCallContext(
            "atlas.workload_snapshot",
            limit=10,
            visible_local_project_ids=frozenset({"local-approved"}),
        )
        outcome = project_remote_tool_response(
            wire(payload), context, self.policy, max_response_bytes=65_536
        )
        projected = decode_projected(outcome.response)
        self.assertEqual(projected["counts"]["total"], 1)
        self.assertEqual(projected["counts"]["ready"], 1)
        self.assertEqual(len(projected["executionCandidates"]), 1)
        encoded = json.dumps(projected)
        for forbidden in (
            "private-item-id",
            "Secret task text",
            "PRIVATE_TOKEN",
            "hidden-local",
            "suggestedNextItems",
            '"cards"',
            "999",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_planning_projection_withholds_accepted_truth_commands_and_excerpts(self) -> None:
        card = {
            "id": "private-item-id",
            "title": "Secret work item",
            "kind": "work_item",
            "readiness": "ready",
            "boardGroup": "ready",
            "size": "small",
            "risk": "docs_only",
            "suggestedActor": "codex",
            "verificationNeeded": "tests",
            "priority": "high",
            "status": "next",
            "stale": False,
            "staleReasons": [],
            "originKind": "manual",
        }
        payload = {
            "schema": "atlas.project_planning_context.v1",
            "generatedAt": "2026-07-09T22:00:00Z",
            "project": {
                "projectId": "local-approved",
                "title": "Private source title",
                "status": "active",
                "phase": "build",
                "priority": "high",
                "needsAttention": True,
                "freshness": {
                    "status": "stale",
                    "confidence": "low",
                    "staleReasons": ["old_github_check"],
                    "attentionReasons": ["local_dirty_state"],
                    "actionRequiredBeforePlanning": "PRIVATE_PLANNING_ACTION",
                },
            },
            "currentAcceptedTruth": {"currentActiveTask": "PRIVATE_TASK"},
            "workload": {
                "counts": {"total": 1, "ready": 1},
                "readyItems": [card],
                "planningCandidateItems": [],
                "reviewNeededItems": [],
                "blockedItems": [],
            },
            "safeConstraints": {"humanFinal": True, "noRemoteWriteTools": True},
            "verification": {
                "commands": ["PRIVATE_COMMAND"],
                "workloadVerificationNeeded": ["tests"],
            },
            "recentEvidence": [{"detail": "PRIVATE_EVIDENCE"}],
            "contextExcerpts": [{"summary": "PRIVATE_EXCERPT"}],
        }
        context = RemoteCallContext(
            "atlas.project_planning_context", project=self.approved, limit=10
        )
        outcome = project_remote_tool_response(
            wire(payload), context, self.policy, max_response_bytes=65_536
        )
        projected = decode_projected(outcome.response)
        self.assertEqual(
            set(projected),
            {
                "schema",
                "generatedAt",
                "project",
                "workload",
                "safeConstraints",
                "verification",
                "integrityNotice",
            },
        )
        encoded = json.dumps(projected)
        for forbidden in (
            "currentAcceptedTruth",
            "PRIVATE_TASK",
            "PRIVATE_COMMAND",
            "PRIVATE_EVIDENCE",
            "PRIVATE_EXCERPT",
            "Secret work item",
            "private-item-id",
            "PRIVATE_PLANNING_ACTION",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_projected_string_fields_use_semantic_allowlists(self) -> None:
        token_like = "abc123deadbeef987654321"
        payload = {
            "id": "local-approved",
            "status": "active",
            "phase": token_like,
            "priority": token_like,
            "freshness": {
                "status": token_like,
                "confidence": token_like,
                "staleReasons": [token_like, "old_github_check"],
                "attentionReasons": ["PRIVATE_COMMAND", "local_dirty_state"],
            },
        }
        outcome = project_remote_tool_response(
            wire(payload),
            RemoteCallContext("get_project_status", project=self.approved),
            self.policy,
            max_response_bytes=65_536,
        )
        projected = decode_projected(outcome.response)
        encoded = json.dumps(projected)
        self.assertNotIn(token_like, encoded)
        self.assertNotIn("PRIVATE_COMMAND", encoded)
        self.assertEqual(projected["project"]["phase"], "unknown")
        self.assertEqual(
            projected["project"]["freshness"]["staleReasons"],
            ["old_github_check"],
        )

        card = {
            "projectId": "local-approved",
            "kind": token_like,
            "readiness": token_like,
            "boardGroup": token_like,
            "size": token_like,
            "risk": token_like,
            "suggestedActor": token_like,
            "verificationNeeded": token_like,
            "priority": token_like,
            "status": token_like,
            "stale": True,
            "staleReasons": [token_like],
            "originKind": token_like,
        }
        outcome = project_remote_tool_response(
            wire(
                {
                    "generatedAt": token_like,
                    "cards": [card],
                    "executionCandidates": [card],
                    "planningCandidateItems": [],
                    "reviewNeededItems": [],
                }
            ),
            RemoteCallContext(
                "atlas.workload_snapshot",
                visible_local_project_ids=frozenset({"local-approved"}),
            ),
            self.policy,
            max_response_bytes=65_536,
        )
        projected = decode_projected(outcome.response)
        self.assertNotIn(token_like, json.dumps(projected))
        self.assertEqual(projected["executionCandidates"][0]["kind"], "unknown")

    def test_archived_projects_are_hidden_from_every_remote_read(self) -> None:
        archived_status = {
            "id": "local-approved",
            "status": "archived",
            "phase": "stabilize",
            "priority": "normal",
            "freshness": {},
        }
        with self.assertRaises(RemoteProjectionError) as caught:
            project_remote_tool_response(
                wire(archived_status),
                RemoteCallContext("get_project_status", project=self.approved),
                self.policy,
                max_response_bytes=65_536,
            )
        self.assertEqual(caught.exception.code, "not_found")

        archived_planning = {
            "project": {
                "projectId": "local-approved",
                "status": "archived",
            },
            "workload": {
                "counts": {},
                "readyItems": [],
                "planningCandidateItems": [],
                "reviewNeededItems": [],
                "blockedItems": [],
            },
        }
        with self.assertRaises(RemoteProjectionError) as caught:
            project_remote_tool_response(
                wire(archived_planning),
                RemoteCallContext(
                    "atlas.project_planning_context", project=self.approved, limit=5
                ),
                self.policy,
                max_response_bytes=65_536,
            )
        self.assertEqual(caught.exception.code, "not_found")

        global_context = attach_remote_project_visibility(
            wire([archived_status]),
            RemoteCallContext("atlas.workload_snapshot"),
            self.policy,
        )
        card = {
            "projectId": "local-approved",
            "kind": "work_item",
            "readiness": "ready",
            "boardGroup": "ready",
            "size": "small",
            "risk": "low_code",
            "suggestedActor": "codex",
            "verificationNeeded": "tests",
            "priority": "normal",
            "status": "next",
            "stale": False,
            "staleReasons": [],
            "originKind": "manual",
        }
        workload = {
            "cards": [card],
            "executionCandidates": [card],
            "planningCandidateItems": [],
            "reviewNeededItems": [],
        }
        outcome = project_remote_tool_response(
            wire(workload),
            global_context,
            self.policy,
            max_response_bytes=65_536,
        )
        projected = decode_projected(outcome.response)
        self.assertEqual(projected["counts"]["total"], 0)
        self.assertEqual(projected["executionCandidates"], [])

        with self.assertRaises(RemoteProjectionError) as caught:
            attach_remote_project_visibility(
                wire([archived_status]),
                RemoteCallContext(
                    "atlas.workload_snapshot", project=self.approved
                ),
                self.policy,
            )
        self.assertEqual(caught.exception.code, "not_found")

    def test_unhashable_upstream_ids_fail_closed(self) -> None:
        with self.assertRaises(RemoteProjectionError):
            project_remote_tool_response(
                wire([{"id": [], "status": "active"}]),
                RemoteCallContext("list_projects"),
                self.policy,
                max_response_bytes=65_536,
            )

        malformed_card = {"projectId": {"private": "value"}}
        with self.assertRaises(RemoteProjectionError):
            project_remote_tool_response(
                wire(
                    {
                        "cards": [malformed_card],
                        "executionCandidates": [],
                        "planningCandidateItems": [],
                        "reviewNeededItems": [],
                    }
                ),
                RemoteCallContext(
                    "atlas.workload_snapshot",
                    visible_local_project_ids=frozenset({"local-approved"}),
                ),
                self.policy,
                max_response_bytes=65_536,
            )

    def test_malformed_and_upstream_errors_fail_closed(self) -> None:
        context = RemoteCallContext("list_projects")
        malformed = [
            {},
            {"result": {}},
            {"result": {"isError": "false", "content": []}},
            {"result": {"isError": False, "content": []}},
            {
                "result": {
                    "isError": False,
                    "content": [
                        {"type": "text", "text": "[]"},
                        {"type": "text", "text": "[]"},
                    ],
                }
            },
            {"result": {"isError": False, "content": [{"type": "image"}]}},
            {
                "result": {
                    "isError": False,
                    "content": [{"type": "text", "text": "not-json PRIVATE"}],
                }
            },
            wire({"error": "PRIVATE"}, is_error=True),
        ]
        for index, response in enumerate(malformed):
            with self.subTest(index=index), self.assertRaises(RemoteProjectionError):
                project_remote_tool_response(
                    response, context, self.policy, max_response_bytes=65_536
                )

    def test_projected_response_limit_fails_closed(self) -> None:
        payload = [
            {
                "id": "local-approved",
                "status": "active",
                "phase": "build",
                "priority": "high",
                "freshness": {},
            }
        ]
        with self.assertRaises(RemoteProjectionError) as caught:
            project_remote_tool_response(
                wire(payload),
                RemoteCallContext("list_projects"),
                self.policy,
                max_response_bytes=10,
            )
        self.assertEqual(caught.exception.code, "response_too_large")


if __name__ == "__main__":
    unittest.main()
