# =============================================================================
# app.py — Smart Recruitment Management System: Flask API Layer
# =============================================================================
#
# ARCHITECTURAL PHILOSOPHY — THE "THIN LAYER" CONTRACT:
#
#   This file's ONLY responsibilities are:
#     1. Receive an HTTP request and extract/validate its parameters.
#     2. Open a database connection from the pool.
#     3. Execute a pre-built SQL object (stored procedure or view).
#     4. Handle database errors and translate them to HTTP responses.
#     5. Return a JSON response.
#
#   This file NEVER:
#     - Calculates scores           → sp_CalculateCandidateScore does this
#     - Validates state transitions → sp_UpdateApplicationStatus does this
#     - Ranks candidates            → vw_RankedCandidates does this
#     - Filters skill gaps          → vw_SkillGapAnalysis does this
#
#   Every complex operation is one function call or one SELECT away.
#   The database is the engine; Flask is the steering wheel.
#
# TRANSACTION PATTERN used throughout this file:
#
#   with get_db_connection() as conn:
#       try:
#           conn.start_transaction()      ← explicit BEGIN
#           cursor.execute(...)
#           conn.commit()                 ← explicit COMMIT
#       except MySQLError as e:
#           conn.rollback()               ← explicit ROLLBACK on any error
#           return error_response(...)
#
# PARAMETERISED QUERIES:
#   Every SQL statement uses %s placeholders — NEVER string concatenation.
#   mysql-connector-python escapes all values before sending to MySQL,
#   making SQL injection structurally impossible in this codebase.
#
# =============================================================================

from flask import Flask, request
from mysql.connector import Error as MySQLError

from database import get_db_connection, get_pool_status
from utils import success_response, error_response

app = Flask(__name__)


# =============================================================================
# ── SECTION 1: INFRASTRUCTURE ────────────────────────────────────────────────
# =============================================================================

@app.route("/health", methods=["GET"])
def health_check():
    """
    GET /health
    Liveness probe — confirms the API is running and can reach the database.
    Load balancers and container orchestrators (Docker, k8s) call this.
    """
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)
            # Lightest possible DB round-trip — no table scan, pure server call
            cursor.execute("SELECT 1 AS db_reachable")
            cursor.fetchone()
        return success_response({
            "status": "healthy",
            "pool":   get_pool_status()
        })
    except MySQLError as e:
        return error_response(f"Database unreachable: {e.msg}", 503)


# =============================================================================
# ── SECTION 2: CANDIDATE ROUTES (DQL — read-only) ────────────────────────────
# =============================================================================

@app.route("/api/candidates/<int:user_id>/applications", methods=["GET"])
def get_candidate_application_history(user_id: int):
    """
    GET /api/candidates/<user_id>/applications

    Returns a candidate's full application history from the role-safe view.

    SECURITY PATTERN — Simulated Row-Level Security:
      vw_CandidateApplicationHistory contains ALL candidates' data.
      The view already suppresses sensitive columns (computed_score,
      recruiter_notes) through column omission — that's the first defence.
      The second defence is this WHERE clause: we filter to ONLY the rows
      belonging to the requesting user, enforced here by the session context.

      In a production system, user_id would come from a decoded JWT token,
      not the URL. It is in the URL here for testability clarity.

    SQL DELEGATION:
      All JOIN complexity (Users → Candidates → Applications → Jobs) is
      encapsulated in the view. Python only adds the identity filter.
    """
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            # -------------------------------------------------------------------
            # PARAMETERISED QUERY — %s placeholder, never f-string or format().
            # mysql-connector escapes the value; SQL injection is impossible.
            # -------------------------------------------------------------------
            query = """
                SELECT
                    application_id,
                    job_id,
                    job_title,
                    department,
                    location,
                    job_type,
                    application_status,
                    status_description,
                    applied_at,
                    last_status_change,
                    days_since_applied,
                    days_since_last_update,
                    deadline_status,
                    recruiter_name,
                    recruiter_email
                FROM vw_CandidateApplicationHistory
                WHERE candidate_user_id = %s
                ORDER BY applied_at DESC
            """
            # (%s,) — the tuple form is required by mysql-connector even for
            # a single parameter. A bare scalar would be iterated as characters.
            cursor.execute(query, (user_id,))
            applications = cursor.fetchall()

        if not applications:
            return success_response(
                {"message": "No applications found for this candidate.",
                 "applications": []},
                200
            )

        return success_response({
            "candidate_user_id": user_id,
            "total_applications": len(applications),
            "applications": applications
        })

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


# =============================================================================
# ── SECTION 3: RECRUITER ROUTES ───────────────────────────────────────────────
# =============================================================================

@app.route("/api/jobs/<int:job_id>/ranked-candidates", methods=["GET"])
def get_ranked_candidates(job_id: int):
    """
    GET /api/jobs/<job_id>/ranked-candidates
    Optional query params:
      ?status=Shortlisted    — filter by application status
      ?min_score=50          — filter by minimum computed score
      ?limit=20              — max rows returned (default: all)

    Returns the recruiter's ranked candidate list for a specific job posting.

    SQL DELEGATION:
      RANK(), DENSE_RANK(), ROW_NUMBER(), PERCENT_RANK(), window AVG/MAX,
      and all JOIN logic live entirely in vw_RankedCandidates (Phase 3).
      Python's job here is parameter extraction and optional filter assembly.

    NOTE ON DYNAMIC FILTERS:
      We build the WHERE clause incrementally using a params list.
      This pattern keeps queries parameterised even when filters are optional.
    """
    # ── Extract optional query string filters ─────────────────────────────
    status_filter    = request.args.get("status",    None)
    min_score_filter = request.args.get("min_score", None)
    limit_filter     = request.args.get("limit",     None)

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            # ── Build parameterised WHERE clause dynamically ───────────────
            # Start with the mandatory job_id filter; the view handles the
            # WHERE status <> 'Withdrawn' exclusion internally.
            conditions = ["job_id = %s"]
            params     = [job_id]

            if status_filter:
                conditions.append("application_status = %s")
                params.append(status_filter)

            if min_score_filter:
                try:
                    params.append(float(min_score_filter))
                    conditions.append("computed_score >= %s")
                except ValueError:
                    return error_response(
                        "min_score must be a numeric value.", 400
                    )

            where_clause = " AND ".join(conditions)
            query = f"""
                SELECT
                    job_title,
                    department,
                    application_id,
                    candidate_id,
                    candidate_name,
                    candidate_email,
                    candidate_education,
                    candidate_experience,
                    application_status,
                    computed_score,
                    score_rank,
                    score_dense_rank,
                    row_num,
                    percentile_rank,
                    job_avg_score,
                    job_top_score,
                    total_applicants_for_job,
                    applied_at,
                    last_status_change
                FROM vw_RankedCandidates
                WHERE {where_clause}
                ORDER BY score_rank ASC
            """

            # Optional LIMIT — appended as a literal integer (never user string)
            # because LIMIT does not support %s placeholders in MySQL.
            if limit_filter:
                try:
                    limit_int = int(limit_filter)
                    if limit_int < 1:
                        raise ValueError
                    query += f" LIMIT {limit_int}"
                except ValueError:
                    return error_response("limit must be a positive integer.", 400)

            cursor.execute(query, tuple(params))
            candidates = cursor.fetchall()

        if not candidates:
            return success_response(
                {"message": f"No candidates found for job_id {job_id}.",
                 "candidates": []},
                200
            )

        return success_response({
            "job_id":            job_id,
            "total_returned":    len(candidates),
            "candidates":        candidates
        })

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


@app.route("/api/jobs/<int:job_id>/skill-gap", methods=["GET"])
def get_skill_gap_analysis(job_id: int):
    """
    GET /api/jobs/<job_id>/skill-gap
    Optional query params:
      ?candidate_id=5   — narrow to a single candidate

    Returns the NOT EXISTS anti-join results from vw_SkillGapAnalysis.
    Shows which mandatory skills each active applicant is missing.

    SQL DELEGATION:
      The NOT EXISTS subquery, all JOINs, and the gap percentage calculation
      are in the view. Python only filters by job_id and optionally candidate.
    """
    candidate_filter = request.args.get("candidate_id", None)

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            conditions = ["job_id = %s"]
            params     = [job_id]

            if candidate_filter:
                try:
                    conditions.append("candidate_id = %s")
                    params.append(int(candidate_filter))
                except ValueError:
                    return error_response("candidate_id must be an integer.", 400)

            where_clause = " AND ".join(conditions)
            query = f"""
                SELECT
                    job_title,
                    department,
                    application_id,
                    candidate_id,
                    candidate_name,
                    application_status,
                    computed_score,
                    missing_skill_name,
                    missing_skill_category,
                    gap_type,
                    total_mandatory_gaps,
                    total_mandatory_required,
                    mandatory_gap_pct
                FROM vw_SkillGapAnalysis
                WHERE {where_clause}
                ORDER BY total_mandatory_gaps DESC, candidate_name ASC
            """

            cursor.execute(query, tuple(params))
            gaps = cursor.fetchall()

        return success_response({
            "job_id":         job_id,
            "total_gap_rows": len(gaps),
            "skill_gaps":     gaps
        })

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


# =============================================================================
# ── SECTION 4: ADMIN ROUTES (DQL — read-only) ─────────────────────────────────
# =============================================================================

@app.route("/api/admin/funnel-summary", methods=["GET"])
def get_job_funnel_summary():
    """
    GET /api/admin/funnel-summary
    Optional query params:
      ?department=Engineering   — filter by department
      ?active_only=true         — only show is_active = 1 jobs

    Returns the full recruitment pipeline health report from
    vw_JobFunnelSummary — conditional aggregation, conversion rates,
    all computed by the view in a single SQL pass.
    """
    department_filter = request.args.get("department", None)
    active_only       = request.args.get("active_only", "false").lower() == "true"

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            conditions = []
            params     = []

            if department_filter:
                conditions.append("department = %s")
                params.append(department_filter)

            if active_only:
                conditions.append("is_active = 1")

            where_clause = (
                "WHERE " + " AND ".join(conditions)
                if conditions else ""
            )

            query = f"""
                SELECT
                    job_id,
                    job_title,
                    department,
                    location,
                    job_type,
                    is_active,
                    posted_by,
                    posted_at,
                    deadline,
                    total_applications,
                    cnt_submitted,
                    cnt_under_review,
                    cnt_shortlisted,
                    cnt_interview_scheduled,
                    cnt_offer_extended,
                    cnt_hired,
                    cnt_rejected,
                    cnt_withdrawn,
                    avg_computed_score,
                    max_computed_score,
                    min_computed_score,
                    shortlist_conversion_pct,
                    offer_conversion_pct,
                    total_skills_required,
                    mandatory_skills_count
                FROM vw_JobFunnelSummary
                {where_clause}
                ORDER BY posted_at DESC
            """

            cursor.execute(query, tuple(params))
            summary = cursor.fetchall()

        return success_response({
            "total_jobs": len(summary),
            "funnel":     summary
        })

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


# =============================================================================
# ── SECTION 5: DML ROUTES WITH EXPLICIT TRANSACTION CONTROL ──────────────────
# =============================================================================
#
# These two routes are the most important in the file for demonstrating
# the project's core principle: complex logic stays in the database.
#
# TRANSACTION ANATOMY:
#
#   conn.start_transaction()
#       │
#       ├── INSERT / CALL  ← database does the work
#       │       │
#       │    success?──► conn.commit()   → changes are durable
#       │       │
#       └── MySQLError?──► conn.rollback() → all changes undone atomically
#
# The custom SQLSTATE '45000' errors raised by our stored procedures
# arrive as MySQLError with errno 45001, 45002, 45003.
# We surface these to the client with HTTP 400 (Bad Request) and
# the exact message the stored procedure composed.
# =============================================================================

@app.route("/api/applications", methods=["POST"])
def submit_application():
    """
    POST /api/applications
    Body (JSON): { "job_id": int, "candidate_id": int, "cover_letter": str }

    Two-phase transactional operation:
      Phase A — INSERT into Applications (status defaults to 'Submitted')
      Phase B — CALL sp_CalculateCandidateScore(new_application_id)

    Both phases share one transaction. If the scoring procedure fails
    (e.g., candidate or job not found), the INSERT is rolled back too —
    we never have an unscored application record left behind.

    SQL DELEGATION:
      - Duplicate application prevention: UNIQUE constraint (job_id, candidate_id)
        on the Applications table raises an error at the DB level.
      - Score calculation: 100% inside sp_CalculateCandidateScore.
      - Audit trail: trg_ApplicationStatusUpdate fires automatically on
        any future status change — nothing to do here.
    """
    body = request.get_json(silent=True)
    if not body:
        return error_response("Request body must be valid JSON.", 400)

    job_id       = body.get("job_id")
    candidate_id = body.get("candidate_id")
    cover_letter = body.get("cover_letter", None)

    # ── Basic presence validation (not business logic — just HTTP hygiene) ─
    if not job_id or not candidate_id:
        return error_response("job_id and candidate_id are required.", 400)

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            # ================================================================
            # BEGIN TRANSACTION
            # autocommit=False (set in pool config) means this is implicit,
            # but start_transaction() makes the intent explicit and readable.
            # ================================================================
            conn.start_transaction()

            try:
                # ── Phase A: Insert the application ──────────────────────────
                # Status defaults to 'Submitted' (DB DEFAULT).
                # The UNIQUE constraint (job_id, candidate_id) prevents
                # duplicate applications at the database level.
                insert_query = """
                    INSERT INTO Applications
                        (job_id, candidate_id, cover_letter)
                    VALUES
                        (%s,     %s,           %s)
                """
                cursor.execute(insert_query, (job_id, candidate_id, cover_letter))

                # Retrieve the auto-generated PK for the scoring call.
                new_application_id = cursor.lastrowid

                # ── Phase B: Score the application ───────────────────────────
                # CALL delegates ALL scoring logic to sp_CalculateCandidateScore.
                # Python has zero knowledge of the scoring formula.
                # The procedure also returns a result set (the breakdown row)
                # which we fetch to include in our API response.
                cursor.execute(
                    "CALL sp_CalculateCandidateScore(%s)",
                    (new_application_id,)
                )
                score_breakdown = cursor.fetchone()

                # mysql-connector requires consuming all result sets produced
                # by a stored procedure before committing or running new queries.
                # nextset() advances past any remaining result sets.
                while cursor.nextset():
                    pass

                # ============================================================
                # COMMIT — both INSERT and score UPDATE are now durable.
                # ============================================================
                conn.commit()

                return success_response({
                    "message":        "Application submitted and scored successfully.",
                    "application_id": new_application_id,
                    "score_breakdown": score_breakdown
                }, 201)

            except MySQLError as db_err:
                # ============================================================
                # ROLLBACK — neither the INSERT nor the score UPDATE persist.
                # The database returns to its exact pre-request state.
                # ============================================================
                conn.rollback()

                # ── Translate known MySQL error codes to clear HTTP responses ─
                # errno 1062 = Duplicate entry (UNIQUE constraint violation)
                if db_err.errno == 1062:
                    return error_response(
                        "This candidate has already applied to this job.",
                        409   # HTTP 409 Conflict
                    )

                # errno 45003 = our custom "Application not found" signal
                # (shouldn't happen on INSERT but included for completeness)
                if db_err.errno == 45003:
                    return error_response(db_err.msg, 400, db_err.errno)

                # Generic DB error — log full details server-side, return safe msg
                app.logger.error(
                    f"[submit_application] DB error {db_err.errno}: {db_err.msg}"
                )
                return error_response(
                    f"Database error during application submission: {db_err.msg}",
                    500, db_err.errno
                )

    except MySQLError as pool_err:
        # Pool-level failure (can't get a connection at all)
        return error_response(f"Could not connect to database: {pool_err.msg}", 503)


@app.route("/api/applications/<int:application_id>/status", methods=["PATCH"])
def update_application_status(application_id: int):
    """
    PATCH /api/applications/<application_id>/status
    Body (JSON): { "new_status": "Shortlisted" }

    Calls sp_UpdateApplicationStatus which:
      1. Validates the application exists        (SIGNAL 45001 if not)
      2. Checks the transition is legal          (SIGNAL 45002 if not)
      3. Performs the UPDATE
      4. The BEFORE UPDATE trigger automatically:
           a. Stamps last_status_change = NOW()
           b. Writes an audit row to ApplicationStatusAudit

    Python does NONE of this logic — it calls the procedure and either
    returns the result or translates the SIGNAL error to an HTTP response.

    TRANSACTION CONTROL:
      Although sp_UpdateApplicationStatus is a single UPDATE internally,
      we still wrap it in an explicit transaction. This future-proofs the
      route: if we later need to update a secondary table in the same
      request (e.g., send a notification record), the transaction boundary
      is already in place.

    HTTP SEMANTICS:
      PATCH (not PUT) — we are partially updating one field of the resource.
    """
    body = request.get_json(silent=True)
    if not body:
        return error_response("Request body must be valid JSON.", 400)

    new_status = body.get("new_status", "").strip()
    if not new_status:
        return error_response("new_status is required.", 400)

    # ── Client-side pre-validation of the ENUM set ────────────────────────
    # This is NOT business logic — it's input sanitation.
    # The real transition validity check happens inside the stored procedure.
    VALID_STATUSES = {
        "Submitted", "Under Review", "Shortlisted",
        "Interview Scheduled", "Offer Extended",
        "Hired", "Rejected", "Withdrawn"
    }
    if new_status not in VALID_STATUSES:
        return error_response(
            f"'{new_status}' is not a recognised status value. "
            f"Valid values: {sorted(VALID_STATUSES)}",
            400
        )

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            # ================================================================
            # BEGIN TRANSACTION
            # ================================================================
            conn.start_transaction()

            try:
                # ── Delegate entirely to the stored procedure ─────────────────
                # sp_UpdateApplicationStatus will:
                #   - Raise SQLSTATE 45000 / errno 45001 if app not found
                #   - Raise SQLSTATE 45000 / errno 45002 if transition illegal
                #   - Execute the UPDATE (which fires the trigger)
                cursor.execute(
                    "CALL sp_UpdateApplicationStatus(%s, %s)",
                    (application_id, new_status)
                )

                while cursor.nextset():
                    pass

                # ── Fetch the updated row to return in the response ───────────
                # One additional SELECT to confirm and return the new state.
                cursor.execute(
                    """
                    SELECT
                        application_id,
                        status,
                        computed_score,
                        last_status_change
                    FROM Applications
                    WHERE application_id = %s
                    """,
                    (application_id,)
                )
                updated_row = cursor.fetchone()

                # ============================================================
                # COMMIT
                # ============================================================
                conn.commit()

                return success_response({
                    "message":     f"Status updated to '{new_status}' successfully.",
                    "application": updated_row
                })

            except MySQLError as db_err:
                # ============================================================
                # ROLLBACK
                # ============================================================
                conn.rollback()

                # ── errno 45001: Application not found ────────────────────────
                if db_err.errno == 45001:
                    return error_response(db_err.msg, 404, db_err.errno)

                # ── errno 45002: Illegal status transition ─────────────────────
                # The procedure's CONCAT message already contains both the
                # current and target status, e.g.:
                # "Error 45002: Illegal status transition from 'Submitted' to 'Hired'."
                # We surface this directly — it's already user-readable.
                if db_err.errno == 45002:
                    return error_response(db_err.msg, 400, db_err.errno)

                app.logger.error(
                    f"[update_status] DB error {db_err.errno}: {db_err.msg}"
                )
                return error_response(
                    f"Database error during status update: {db_err.msg}",
                    500, db_err.errno
                )

    except MySQLError as pool_err:
        return error_response(f"Could not connect to database: {pool_err.msg}", 503)


# =============================================================================
# ── SECTION 6: SUPPORTING READ ROUTES ────────────────────────────────────────
# =============================================================================

@app.route("/api/jobs", methods=["GET"])
def get_active_jobs():
    """
    GET /api/jobs
    Optional query params:
      ?department=Engineering
      ?job_type=Remote

    Returns all active job postings. Filters are optional.
    """
    department_filter = request.args.get("department", None)
    job_type_filter   = request.args.get("job_type",   None)

    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            conditions = ["j.is_active = 1"]
            params     = []

            if department_filter:
                conditions.append("j.department = %s")
                params.append(department_filter)

            if job_type_filter:
                conditions.append("j.job_type = %s")
                params.append(job_type_filter)

            where_clause = " AND ".join(conditions)

            query = f"""
                SELECT
                    j.job_id,
                    j.title,
                    j.department,
                    j.location,
                    j.job_type,
                    j.description,
                    j.min_experience_years,
                    j.salary_min,
                    j.salary_max,
                    j.posted_at,
                    j.deadline,
                    el.level_name           AS min_education_required,
                    u.full_name             AS recruiter_name,
                    COUNT(js.skill_id)      AS required_skills_count
                FROM      Jobs           j
                JOIN      EducationLevels el ON el.education_level_id = j.min_education_level_id
                JOIN      Users           u  ON u.user_id             = j.posted_by
                LEFT JOIN JobSkills       js ON js.job_id             = j.job_id
                WHERE {where_clause}
                GROUP BY
                    j.job_id, j.title, j.department, j.location,
                    j.job_type, j.description, j.min_experience_years,
                    j.salary_min, j.salary_max, j.posted_at, j.deadline,
                    el.level_name, u.full_name
                ORDER BY j.posted_at DESC
            """

            cursor.execute(query, tuple(params))
            jobs = cursor.fetchall()

        return success_response({"total_jobs": len(jobs), "jobs": jobs})

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


@app.route("/api/applications/<int:application_id>/audit", methods=["GET"])
def get_application_audit_trail(application_id: int):
    """
    GET /api/applications/<application_id>/audit

    Returns the full status change history from ApplicationStatusAudit —
    the table written by trg_ApplicationStatusUpdate (Phase 2).
    Demonstrates that the trigger's audit log is queryable via the API.
    """
    try:
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)

            cursor.execute(
                """
                SELECT
                    audit_id,
                    old_status,
                    new_status,
                    changed_at,
                    changed_by
                FROM ApplicationStatusAudit
                WHERE application_id = %s
                ORDER BY changed_at ASC
                """,
                (application_id,)
            )
            audit_log = cursor.fetchall()

        return success_response({
            "application_id": application_id,
            "total_events":   len(audit_log),
            "audit_trail":    audit_log
        })

    except MySQLError as e:
        return error_response(f"Database error: {e.msg}", 500, e.errno)


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=5000,
        debug=True   # Set to False in production
    )