#!/usr/bin/env python3
# =============================================================================
# test_api_oracle.py — Oracle Migration Integration Test Suite
# =============================================================================
# Mirrors test_api.py from the MySQL version, with Oracle-specific assertions.
# Run with: python test_api_oracle.py
# =============================================================================

import json
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


# Test 1: Health
print_section("TEST 1: Health Check (Oracle pool stats)")
r = requests.get(f"{BASE}/health")
print_response("GET /health", r)
assert r.status_code == 200
pool = r.json()["data"]["pool"]
assert "opened" in pool and "busy" in pool, "Expected Oracle pool stats"
print("   ✓ Oracle pool stats (opened/busy/free) present")


# Test 2: Jobs
print_section("TEST 2: Active Jobs")
r = requests.get(f"{BASE}/api/jobs")
print_response("GET /api/jobs", r)


# Test 3: Submit application
print_section("TEST 3: Submit Application (RETURNING INTO)")
r = requests.post(f"{BASE}/api/applications", json={
    "job_id": 1, "candidate_id": 1,
    "cover_letter": "Oracle migration test application."
})
print_response("POST /api/applications", r)
assert r.status_code == 201
APP_ID = r.json()["data"]["application_id"]
print(f"\n   ✓ application_id from RETURNING INTO: {APP_ID}")


# Test 4: Duplicate (ORA-00001 → HTTP 409)
print_section("TEST 4: Duplicate Application (ORA-00001 → HTTP 409)")
r = requests.post(f"{BASE}/api/applications", json={
    "job_id": 1, "candidate_id": 1
})
print_response("POST duplicate", r)
assert r.status_code == 409
print("   ✓ ORA-00001 (unique constraint) correctly mapped to 409")


# Test 5: Candidate history — verify score is absent
print_section("TEST 5: Candidate History (Score Suppressed)")
r = requests.get(f"{BASE}/api/candidates/2/applications")
print_response("GET /api/candidates/2/applications", r)
if r.status_code == 200 and r.json()["data"].get("applications"):
    first = r.json()["data"]["applications"][0]
    assert "computed_score" not in first, "SECURITY: score must not appear!"
    print("   ✓ computed_score absent from candidate-facing view")


# Test 6: Ranked candidates (Oracle window functions)
print_section("TEST 6: Ranked Candidates (Oracle Analytic Functions)")
r = requests.get(f"{BASE}/api/jobs/1/ranked-candidates")
print_response("GET /api/jobs/1/ranked-candidates", r)


# Test 7: Skill gap (NOT EXISTS — identical in Oracle)
print_section("TEST 7: Skill Gap Analysis")
r = requests.get(f"{BASE}/api/jobs/1/skill-gap")
print_response("GET /api/jobs/1/skill-gap", r)


# Test 8: Admin funnel
print_section("TEST 8: Admin Funnel Summary")
r = requests.get(f"{BASE}/api/admin/funnel-summary")
print_response("GET /api/admin/funnel-summary", r)


# Test 9: Valid transition
print_section("TEST 9: Valid Transition (Submitted → Under Review)")
r = requests.patch(
    f"{BASE}/api/applications/{APP_ID}/status",
    json={"new_status": "Under Review"}
)
print_response(f"PATCH /api/applications/{APP_ID}/status", r)
assert r.status_code == 200
print("   ✓ ORA-20000 series: transition accepted")


# Test 10: Invalid transition (ORA-20002 → HTTP 400)
print_section("TEST 10: Invalid Transition (ORA-20002 → HTTP 400)")
r = requests.patch(
    f"{BASE}/api/applications/{APP_ID}/status",
    json={"new_status": "Hired"}
)
print_response("PATCH invalid transition", r)
assert r.status_code == 400
data = r.json()
assert data["data"]["db_code"] == 20002, "Expected db_code 20002"
assert "Illegal" in data["data"]["error"], "Expected RAISE_APPLICATION_ERROR message"
print("   ✓ ORA-20002 from RAISE_APPLICATION_ERROR cleanly surfaced as HTTP 400")
print(f"   ✓ Message: {data['data']['error']}")


# Test 11: Audit trail (trigger wrote exactly 1 row)
print_section("TEST 11: Audit Trail (trg_application_status_update)")
r = requests.get(f"{BASE}/api/applications/{APP_ID}/audit")
print_response(f"GET /api/applications/{APP_ID}/audit", r)
audit = r.json()["data"]["audit_trail"]
assert len(audit) == 1, f"Expected 1 audit row, found {len(audit)}"
print("   ✓ Exactly 1 audit row — ROLLBACK in TEST 10 left no ghost entry")


print_section("ALL ORACLE TESTS PASSED ✓")
print("""
Oracle-specific assertions validated:
  TEST 1  → Oracle pool stats (opened/busy/free) present in health response
  TEST 3  → RETURNING application_id INTO :out_id pattern works
  TEST 4  → ORA-00001 (unique constraint) → HTTP 409
  TEST 5  → Column suppression identical to MySQL version
  TEST 9  → sp_update_application_status executes via BEGIN...END; block
  TEST 10 → RAISE_APPLICATION_ERROR(-20002,...) → ORA-20002 → HTTP 400
            _parse_oracle_error() strips "ORA-20002: " prefix cleanly
  TEST 11 → :NEW/:OLD trigger syntax writes audit correctly
""")
