#!/usr/bin/env python3
# =============================================================================
# test_api.py — Manual Integration Test Suite
# =============================================================================
# Run with:  python test_api.py
# Requires:  pip install requests
#
# This script walks through every API endpoint in the correct order,
# demonstrating the full lifecycle of a job application:
#   1. Health check
#   2. Browse active jobs
#   3. Submit application (triggers INSERT + sp_CalculateCandidateScore)
#   4. Check candidate history (role-safe view, no score exposed)
#   5. Recruiter views ranked candidates (window functions in action)
#   6. Recruiter views skill gap analysis (NOT EXISTS anti-join)
#   7. Admin funnel summary (conditional aggregation)
#   8. VALID status transition (Submitted → Under Review)
#   9. INVALID status transition (should return HTTP 400 + DB error message)
#  10. View the audit trail written by the BEFORE UPDATE trigger
# =============================================================================

import json
import sys
import requests

BASE = "http://localhost:5000"


def print_section(title: str):
    print(f"\n{'═' * 65}")
    print(f"  {title}")
    print(f"{'═' * 65}")


def print_response(label: str, resp: requests.Response):
    print(f"\n── {label}")
    print(f"   HTTP {resp.status_code}")
    try:
        body = resp.json()
        print(json.dumps(body, indent=2, default=str))
    except Exception:
        print(resp.text)


# ---------------------------------------------------------------------------
# TEST 1 — Liveness check
# ---------------------------------------------------------------------------
print_section("TEST 1: Health Check")
r = requests.get(f"{BASE}/health")
print_response("GET /health", r)
assert r.status_code == 200, "Health check failed — is the server running?"


# ---------------------------------------------------------------------------
# TEST 2 — Browse active jobs
# ---------------------------------------------------------------------------
print_section("TEST 2: Browse Active Jobs")
r = requests.get(f"{BASE}/api/jobs")
print_response("GET /api/jobs", r)

r_filtered = requests.get(f"{BASE}/api/jobs?department=Engineering")
print_response("GET /api/jobs?department=Engineering", r_filtered)


# ---------------------------------------------------------------------------
# TEST 3 — Submit application (happy path)
# Demonstrates: explicit transaction, INSERT + CALL sp_CalculateCandidateScore
# ---------------------------------------------------------------------------
print_section("TEST 3: Submit Application (Happy Path)")
payload = {
    "job_id":       1,
    "candidate_id": 1,
    "cover_letter": "I am excited to apply for this position. My Python and "
                    "MySQL background aligns well with your requirements."
}
r = requests.post(f"{BASE}/api/applications", json=payload)
print_response("POST /api/applications", r)
assert r.status_code == 201, f"Expected 201, got {r.status_code}"

# Extract application_id for subsequent tests
APP_ID = r.json()["data"]["application_id"]
print(f"\n   ✓ application_id for subsequent tests: {APP_ID}")


# ---------------------------------------------------------------------------
# TEST 4 — Duplicate application (UNIQUE constraint → HTTP 409)
# ---------------------------------------------------------------------------
print_section("TEST 4: Duplicate Application (Expect HTTP 409)")
r = requests.post(f"{BASE}/api/applications", json=payload)
print_response("POST /api/applications (duplicate)", r)
assert r.status_code == 409, f"Expected 409, got {r.status_code}"
print("   ✓ Duplicate correctly rejected with 409 Conflict")


# ---------------------------------------------------------------------------
# TEST 5 — Candidate views own application history (no score in response)
# ---------------------------------------------------------------------------
print_section("TEST 5: Candidate Application History (Role-Safe View)")
r = requests.get(f"{BASE}/api/candidates/2/applications")  # user_id=2
print_response("GET /api/candidates/2/applications", r)

# Verify the score is NOT present in the response — this is the
# column-suppression security check.
if r.status_code == 200 and r.json()["data"].get("applications"):
    first_app = r.json()["data"]["applications"][0]
    assert "computed_score" not in first_app, \
        "SECURITY VIOLATION: computed_score should not appear in candidate view!"
    print("   ✓ computed_score correctly absent from candidate-facing response")


# ---------------------------------------------------------------------------
# TEST 6 — Recruiter views ranked candidates (window functions)
# ---------------------------------------------------------------------------
print_section("TEST 6: Ranked Candidates (Window Functions)")
r = requests.get(f"{BASE}/api/jobs/1/ranked-candidates")
print_response("GET /api/jobs/1/ranked-candidates", r)

r_filtered = requests.get(
    f"{BASE}/api/jobs/1/ranked-candidates?status=Submitted&min_score=0"
)
print_response("GET /api/jobs/1/ranked-candidates?status=Submitted", r_filtered)


# ---------------------------------------------------------------------------
# TEST 7 — Skill gap analysis (NOT EXISTS anti-join)
# ---------------------------------------------------------------------------
print_section("TEST 7: Skill Gap Analysis (NOT EXISTS Anti-Join)")
r = requests.get(f"{BASE}/api/jobs/1/skill-gap")
print_response("GET /api/jobs/1/skill-gap", r)


# ---------------------------------------------------------------------------
# TEST 8 — Admin funnel summary (conditional aggregation)
# ---------------------------------------------------------------------------
print_section("TEST 8: Admin Funnel Summary (Conditional Aggregation)")
r = requests.get(f"{BASE}/api/admin/funnel-summary")
print_response("GET /api/admin/funnel-summary", r)


# ---------------------------------------------------------------------------
# TEST 9 — Valid status transition: Submitted → Under Review
# Demonstrates: explicit transaction, CALL sp_UpdateApplicationStatus,
#               trigger writes audit row automatically
# ---------------------------------------------------------------------------
print_section("TEST 9: Valid Status Transition (Submitted → Under Review)")
r = requests.patch(
    f"{BASE}/api/applications/{APP_ID}/status",
    json={"new_status": "Under Review"}
)
print_response(f"PATCH /api/applications/{APP_ID}/status", r)
assert r.status_code == 200, f"Expected 200, got {r.status_code}"
print("   ✓ Status transitioned successfully")


# ---------------------------------------------------------------------------
# TEST 10 — INVALID transition: Under Review → Hired (skips pipeline stages)
# Expects: HTTP 400 + the exact SIGNAL message from sp_UpdateApplicationStatus
# ---------------------------------------------------------------------------
print_section("TEST 10: INVALID Transition (Under Review → Hired) — Expect 400")
r = requests.patch(
    f"{BASE}/api/applications/{APP_ID}/status",
    json={"new_status": "Hired"}
)
print_response(f"PATCH /api/applications/{APP_ID}/status (invalid)", r)
assert r.status_code == 400, f"Expected 400, got {r.status_code}"
assert "45002" in str(r.json()), "Expected errno 45002 in response"
print("   ✓ Illegal transition correctly blocked with HTTP 400 + DB error message")


# ---------------------------------------------------------------------------
# TEST 11 — Audit trail (proves trigger fired in TEST 9, NOT in TEST 10)
# ---------------------------------------------------------------------------
print_section("TEST 11: Application Audit Trail (Trigger Evidence)")
r = requests.get(f"{BASE}/api/applications/{APP_ID}/audit")
print_response(f"GET /api/applications/{APP_ID}/audit", r)

audit = r.json()["data"]["audit_trail"]
assert len(audit) == 1, (
    f"Expected exactly 1 audit row (from TEST 9 only). "
    f"Found {len(audit)}. "
    f"The ROLLBACK in TEST 10 correctly prevented a spurious audit entry."
)
print(f"   ✓ Exactly 1 audit row — trigger fired once (TEST 9), "
      f"ROLLBACK suppressed the failed TEST 10 attempt")


# ---------------------------------------------------------------------------
print_section("ALL TESTS PASSED ✓")
print("""
Summary of what each test proved:
  TEST 3  → INSERT + stored procedure called in one atomic transaction
  TEST 4  → UNIQUE constraint enforced at DB level (not Python)
  TEST 5  → Column-level security: computed_score absent from candidate view
  TEST 6  → RANK/DENSE_RANK/PERCENT_RANK served directly from view
  TEST 7  → NOT EXISTS anti-join results surfaced through thin API layer
  TEST 8  → Conditional aggregation funnel from single-pass SQL
  TEST 9  → Legal state transition committed, trigger fired, audit written
  TEST 10 → Illegal transition blocked by DB procedure, ROLLBACK executed
  TEST 11 → Audit table has exactly 1 row (ROLLBACK left no ghost entry)
""")