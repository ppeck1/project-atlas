from __future__ import annotations

import unittest

try:
    from build_mcp_signal_reason_matrix import render_reason_matrix
except ModuleNotFoundError:
    from tools.build_mcp_signal_reason_matrix import render_reason_matrix


class SignalReasonMatrixTest(unittest.TestCase):
    def test_renderer_uses_only_projected_aliases_and_bounded_signals(self) -> None:
        projected = {
            "schema": "project_atlas.remote_project_inventory.v3",
            "projects": [
                {
                    "projectId": "approved-alias",
                    "title": "Approved Label",
                    "status": "active",
                    "freshness": {"status": "stale"},
                    "signals": {
                        "planningActionRequired": False,
                        "dataRefreshRequired": True,
                        "severity": "low",
                        "reasonClasses": ["freshness_stale", "local_evidence"],
                    },
                }
            ],
            "page": {"returned": 1, "total": 1, "truncated": False},
        }
        rendered = render_reason_matrix(
            projected,
            captured_at="2026-07-14T00:00:00Z",
            source_commit="abc1234",
        )
        self.assertIn("| approved-alias | Approved Label |", rendered)
        self.assertIn("| Planning action required | 0 |", rendered)
        self.assertIn("| Data refresh required | 1 |", rendered)
        self.assertNotIn("local-project-id", rendered)


if __name__ == "__main__":
    unittest.main()
