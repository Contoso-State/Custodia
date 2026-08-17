"""FOIAIQ — reference Python client for the Microsoft Purview eDiscovery (Premium) flow.

This module mirrors exactly the operations the FOIAIQ Copilot Studio agent is permitted to
perform, and nothing more:

    list cases -> get case -> create case -> create search -> estimate statistics
    -> poll operations -> read last estimate

It deliberately implements **no** export, purge, delete, legal hold, review-set, analytics,
or review-tag operation. That omission is the primary v1 safety control; do not add them
here without moving to the phase-2 Azure Function design described in the README.

Authentication is DELEGATED only, via ``InteractiveBrowserCredential``. The client can never
exceed the signed-in reviewer's own Purview eDiscovery role. Application (app-only)
credentials are intentionally not supported.

Requires:
    pip install azure-identity requests

Usage:
    python -m foiaiq_ediscovery --tenant-id <TENANT-ID> --client-id <APP-ID> \
        --request-number 00142 --short-subject budget-emails \
        --keywords '"budget" OR "appropriation"' \
        --range-start 2026-01-01 --range-end 2026-06-30 --dry-run
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests
from azure.identity import InteractiveBrowserCredential

GRAPH_BASE = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPES = ["https://graph.microsoft.com/eDiscovery.ReadWrite.All", "User.Read"]

PENDING_STATUSES = {"notStarted", "running"}

VALID_DATA_SOURCE_SCOPES = {
    "none",
    "allTenantMailboxes",
    "allTenantSites",
    "allCaseCustodians",
    "allCaseNoncustodialDataSources",
}

TENANT_WIDE_SCOPES = {"allTenantMailboxes", "allTenantSites"}

DEFAULT_TEMPLATE_PATH = Path(__file__).resolve().parent.parent / "scripts" / "foia-case-template.json"


class EDiscoveryError(RuntimeError):
    """Raised when Microsoft Graph returns an error. Carries the real status and message."""

    def __init__(self, method: str, url: str, status: int, body: str) -> None:
        super().__init__(f"{method} {url} failed with HTTP {status}: {body}")
        self.method = method
        self.url = url
        self.status = status
        self.body = body


@dataclass(frozen=True)
class EstimateResult:
    """Statistics read back from ``lastEstimateStatisticsOperation``."""

    status: str | None
    indexed_item_count: int | None
    indexed_items_size: int | None
    unindexed_item_count: int | None
    unindexed_items_size: int | None
    mailbox_count: int | None
    site_count: int | None
    raw: dict[str, Any]

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "EstimateResult":
        return cls(
            status=payload.get("status"),
            indexed_item_count=payload.get("indexedItemCount"),
            indexed_items_size=payload.get("indexedItemsSize"),
            unindexed_item_count=payload.get("unindexedItemCount"),
            unindexed_items_size=payload.get("unindexedItemsSize"),
            mailbox_count=payload.get("mailboxCount"),
            site_count=payload.get("siteCount"),
            raw=payload,
        )


class FOIAIQClient:
    """Delegated-auth client for the narrow FOIAIQ eDiscovery surface."""

    def __init__(self, tenant_id: str, client_id: str, timeout: int = 60) -> None:
        if not tenant_id or tenant_id.startswith("<"):
            raise ValueError("A real tenant ID is required.")
        if not client_id or client_id.startswith("<"):
            raise ValueError("A real client (app) ID is required.")

        self._timeout = timeout
        self._credential = InteractiveBrowserCredential(
            tenant_id=tenant_id,
            client_id=client_id,
        )
        self._session = requests.Session()

    # -- internals ----------------------------------------------------------------------

    def _token(self) -> str:
        return self._credential.get_token(*GRAPH_SCOPES).token

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
    ) -> requests.Response:
        url = f"{GRAPH_BASE}{path}"
        headers = {
            "Authorization": f"Bearer {self._token()}",
            "Accept": "application/json",
        }
        if json_body is not None:
            headers["Content-Type"] = "application/json"

        response = self._session.request(
            method,
            url,
            headers=headers,
            json=json_body,
            params=params,
            timeout=self._timeout,
        )

        if not response.ok:
            raise EDiscoveryError(method, url, response.status_code, response.text)

        return response

    @staticmethod
    def _json(response: requests.Response) -> dict[str, Any]:
        if not response.content:
            return {}
        return response.json()

    # -- allowed operations -------------------------------------------------------------

    def list_cases(self, top: int = 25, filter_: str | None = None) -> list[dict[str, Any]]:
        """GET /security/cases/ediscoveryCases"""
        params: dict[str, Any] = {"$top": top}
        if filter_:
            params["$filter"] = filter_
        payload = self._json(self._request("GET", "/security/cases/ediscoveryCases", params=params))
        return payload.get("value", [])

    def get_case(self, case_id: str) -> dict[str, Any]:
        """GET /security/cases/ediscoveryCases/{caseId}"""
        return self._json(self._request("GET", f"/security/cases/ediscoveryCases/{case_id}"))

    def create_case(self, display_name: str, description: str = "") -> dict[str, Any]:
        """POST /security/cases/ediscoveryCases"""
        body = {"displayName": display_name, "description": description}
        return self._json(self._request("POST", "/security/cases/ediscoveryCases", json_body=body))

    def create_search(
        self,
        case_id: str,
        display_name: str,
        content_query: str,
        data_source_scopes: str = "none",
        description: str = "",
    ) -> dict[str, Any]:
        """POST /security/cases/ediscoveryCases/{caseId}/searches"""
        if data_source_scopes not in VALID_DATA_SOURCE_SCOPES:
            raise ValueError(
                f"dataSourceScopes must be one of {sorted(VALID_DATA_SOURCE_SCOPES)}, "
                f"got {data_source_scopes!r}"
            )
        body = {
            "displayName": display_name,
            "description": description,
            "contentQuery": content_query,
            "dataSourceScopes": data_source_scopes,
        }
        return self._json(
            self._request(
                "POST",
                f"/security/cases/ediscoveryCases/{case_id}/searches",
                json_body=body,
            )
        )

    def estimate_statistics(
        self,
        case_id: str,
        search_id: str,
        statistics_options: str = "includeQueryStats,includeUnindexedStats",
    ) -> str | None:
        """POST .../searches/{searchId}/estimateStatistics — async, returns 202 + Location."""
        response = self._request(
            "POST",
            f"/security/cases/ediscoveryCases/{case_id}/searches/{search_id}/estimateStatistics",
            json_body={"statisticsOptions": statistics_options},
        )
        return response.headers.get("Location")

    def list_operations(self, case_id: str, top: int = 25) -> list[dict[str, Any]]:
        """GET /security/cases/ediscoveryCases/{caseId}/operations"""
        payload = self._json(
            self._request(
                "GET",
                f"/security/cases/ediscoveryCases/{case_id}/operations",
                params={"$top": top},
            )
        )
        return payload.get("value", [])

    def get_last_estimate(self, case_id: str, search_id: str) -> EstimateResult:
        """GET .../searches/{searchId}/lastEstimateStatisticsOperation"""
        payload = self._json(
            self._request(
                "GET",
                f"/security/cases/ediscoveryCases/{case_id}/searches/{search_id}"
                "/lastEstimateStatisticsOperation",
            )
        )
        return EstimateResult.from_payload(payload)

    # -- composed flow ------------------------------------------------------------------

    def wait_for_operations(
        self,
        case_id: str,
        poll_seconds: int = 15,
        timeout_minutes: int = 30,
        on_poll=None,
    ) -> None:
        """Poll case operations until none is notStarted or running."""
        deadline = time.monotonic() + timeout_minutes * 60

        while True:
            operations = self.list_operations(case_id)
            pending = [op for op in operations if op.get("status") in PENDING_STATUSES]
            if not pending:
                return

            if time.monotonic() > deadline:
                raise TimeoutError(
                    f"Operations still pending after {timeout_minutes} minutes: "
                    + ", ".join(f"{op.get('action')}={op.get('status')}" for op in pending)
                )

            if on_poll:
                on_poll(pending)
            time.sleep(poll_seconds)

    def run_foia_flow(
        self,
        case_display_name: str,
        case_description: str,
        search_display_name: str,
        content_query: str,
        data_source_scopes: str = "none",
        statistics_options: str = "includeQueryStats,includeUnindexedStats",
        poll_seconds: int = 15,
        timeout_minutes: int = 30,
    ) -> tuple[str, str, EstimateResult]:
        """Create case -> create search -> estimate -> poll -> read. Stops at read."""
        case = self.create_case(case_display_name, case_description)
        case_id = case["id"]
        print(f"  Case ID:   {case_id}")

        search = self.create_search(
            case_id,
            search_display_name,
            content_query,
            data_source_scopes,
            description=f"Search for {case_display_name}",
        )
        search_id = search["id"]
        print(f"  Search ID: {search_id}")

        location = self.estimate_statistics(case_id, search_id, statistics_options)
        print(f"  Estimate accepted. Operation: {location}")

        def _report(pending: list[dict[str, Any]]) -> None:
            statuses = ", ".join(f"{op.get('action')}={op.get('status')}" for op in pending)
            print(f"  Still running: {statuses}")

        self.wait_for_operations(case_id, poll_seconds, timeout_minutes, on_poll=_report)

        return case_id, search_id, self.get_last_estimate(case_id, search_id)


# -- template helpers -------------------------------------------------------------------


def load_template(path: Path = DEFAULT_TEMPLATE_PATH) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def build_names(
    template: dict[str, Any], request_number: str, short_subject: str, iteration: str = "01"
) -> tuple[str, str]:
    year = str(datetime.now(timezone.utc).year)
    case_name = (
        template["naming"]["casePattern"]
        .replace("{year}", year)
        .replace("{requestNumber}", request_number)
        .replace("{shortSubject}", short_subject)
    )
    search_name = (
        template["naming"]["searchPattern"]
        .replace("{caseName}", case_name)
        .replace("{iteration}", iteration)
    )
    return case_name, search_name


def build_query(template: dict[str, Any], keywords: str, range_start: str, range_end: str) -> str:
    return (
        template["queryDefaults"]["kqlTemplate"]
        .replace("{keywords}", keywords)
        .replace("{rangeStart}", range_start)
        .replace("{rangeEnd}", range_end)
    )


def build_description(
    template: dict[str, Any], request_number: str, range_start: str, range_end: str
) -> str:
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return (
        template["defaults"]["descriptionTemplate"]
        .replace("{requestNumber}", request_number)
        .replace("{receivedDate}", today)
        .replace("{dueDate}", "(set by intake)")
        .replace("{rangeStart}", range_start)
        .replace("{rangeEnd}", range_end)
    )


# -- CLI ---------------------------------------------------------------------------------


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a FOIA eDiscovery case, search, and statistics estimate."
    )
    parser.add_argument("--tenant-id", required=True, help="Entra tenant ID.")
    parser.add_argument("--client-id", required=True, help="App registration (client) ID.")
    parser.add_argument("--request-number", required=True, help="FOIA intake tracking number.")
    parser.add_argument("--short-subject", required=True, help="Short kebab-case subject.")
    parser.add_argument("--keywords", required=True, help="KQL keyword expression.")
    parser.add_argument("--range-start", required=True, help="Range start (YYYY-MM-DD).")
    parser.add_argument("--range-end", required=True, help="Range end (YYYY-MM-DD).")
    parser.add_argument(
        "--data-source-scopes",
        choices=sorted(VALID_DATA_SOURCE_SCOPES),
        default=None,
        help="Search scope. Defaults to the template value.",
    )
    parser.add_argument("--statistics-options", default=None)
    parser.add_argument("--poll-seconds", type=int, default=15)
    parser.add_argument("--timeout-minutes", type=int, default=30)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be created, then exit without writing anything.",
    )
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE_PATH)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    template = load_template(args.template)

    scopes = args.data_source_scopes or template["defaults"]["dataSourceScopes"]
    stats_options = args.statistics_options or template["defaults"]["statisticsOptions"]

    case_name, search_name = build_names(template, args.request_number, args.short_subject)
    content_query = build_query(template, args.keywords, args.range_start, args.range_end)
    description = build_description(template, args.request_number, args.range_start, args.range_end)

    print()
    print("About to create the following:")
    print(f"  Case name:     {case_name}")
    print(f"  Description:   {description}")
    print(f"  Search name:   {search_name}")
    print(f"  Content query: {content_query}")
    print(f"  Scope:         {scopes}")
    print(f"  Statistics:    {stats_options}")
    print()

    if scopes in TENANT_WIDE_SCOPES:
        print(f"WARNING: '{scopes}' searches the entire tenant. Confirm this is intended.")
        print()

    if args.dry_run:
        print("Dry run. Nothing was created.")
        return 0

    if input("Type CREATE to proceed: ").strip() != "CREATE":
        print("Aborted. Nothing was created.")
        return 1

    client = FOIAIQClient(args.tenant_id, args.client_id)

    try:
        case_id, search_id, estimate = client.run_foia_flow(
            case_display_name=case_name,
            case_description=description,
            search_display_name=search_name,
            content_query=content_query,
            data_source_scopes=scopes,
            statistics_options=stats_options,
            poll_seconds=args.poll_seconds,
            timeout_minutes=args.timeout_minutes,
        )
    except EDiscoveryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except TimeoutError as exc:
        print(f"TIMEOUT: {exc}", file=sys.stderr)
        return 3

    print()
    print("=" * 57)
    print(" Estimate complete")
    print("=" * 57)
    print(f"  Case:                {case_name} ({case_id})")
    print(f"  Search:              {search_name} ({search_id})")
    print(f"  Status:              {estimate.status}")
    print(f"  Indexed items:       {estimate.indexed_item_count}")
    print(f"  Indexed size:        {estimate.indexed_items_size} bytes")
    print(f"  Unindexed items:     {estimate.unindexed_item_count}")
    print(f"  Unindexed size:      {estimate.unindexed_items_size} bytes")
    print(f"  Mailboxes with hits: {estimate.mailbox_count}")
    print(f"  Sites with hits:     {estimate.site_count}")
    print()
    print("This client stops here by design. Export, purge, holds, review sets, and tagging")
    print("are out of scope and must be done by a reviewer in the Microsoft Purview portal.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
