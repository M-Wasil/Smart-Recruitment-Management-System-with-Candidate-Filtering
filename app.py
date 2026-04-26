# =============================================================================
# app.py — Smart Recruitment Management System: Flask + Oracle Backend
# =============================================================================
#
# CRITICAL MIGRATION CHANGES vs MySQL version:
#
# ┌─────────────────────────────┬──────────────────────────────────────────────┐
# │ MySQL (mysql-connector)     │ Oracle (oracledb)                            │
# ├─────────────────────────────┼──────────────────────────────────────────────┤
# │ %s  placeholder             │ :param_name  named bind variable             │
# │ cursor(dictionary=True)     │ cursor.rowfactory = _dict_row_factory(cursor)│
# │ cursor.lastrowid            │ RETURNING col INTO :out_var +                │
# │                             │ cursor.var(oracledb.NUMBER)                  │
# │ cursor.nextset()            │ Not needed — Oracle uses REF CURSOR OUT param│
# │ conn.start_transaction()    │ Not needed — Oracle is always manual-commit  │
# │ mysql.connector.Error       │ oracledb.Error  (same pattern, different ns) │
# │ db_err.errno == 1062        │ db_err.args[0].code == 1  (ORA-00001)        │
# │ db_err.errno == 45002       │ db_err.args[0].code == 20002 (ORA-20002)     │
# │ CALL procedure(%s, %s)      │ conn.cursor().callproc('name', [args])       │
# │                             │ OR: cursor.execute('BEGIN name(:a,:b); END;')│
# └─────────────────────────────┴──────────────────────────────────────────────┘
#
# BIND VARIABLE NAMING CONVENTION:
#   Oracle supports both positional (:1, :2) and named (:job_id, :candidate_id).
#   We use NAMED bind variables throughout for readability and to avoid
#   order-dependency bugs. Named binds are passed as a dict to cursor.execute().
#
# ORACLE ERROR CODE EXTRACTION:
#   oracledb.Error stores the error as:
#     err.args[0]        → DatabaseError object
#     err.args[0].code   → Oracle error number (e.g., 20002 for ORA-20002)
#     err.args[0].message → Full error string including ORA-NNNNN prefix
#   We strip "ORA-20002: " prefix from RAISE_APPLICATION_ERROR messages
#   to return clean user-facing text.
#
# =============================================================================

import re
from flask import Flask, request

import oracledb
from database import get_db_connection, get_pool_status, _dict_row_factory
from utils import success_response, error_response

app = Flask(__name__)


# ---------------------------------------------------------------------------
# Helper: extract Oracle error code and clean message
# ---------------------------------------------------------------------------
def _parse_oracle_error(err: oracledb.Error) -> tuple[int, str]:
    """
    Extracts the numeric error code and a clean message from an oracledb.Error.

    For application errors raised with RAISE_APPLICATION_ERROR(-20NNN, 'msg'):
      The full Oracle message looks like:
        "ORA-20002: Illegal status transition from 'Submitted' to 'Hired'.\n
         ORA-06512: at \"RECRUITMENT.SP_UPDATE_APPLICATION_STATUS\", line 68"
      We extract just ORA-20002 and strip it to return the clean app message.

    Returns:
        (oracle_code: int, clean_message: str)
    """
    db_error = err.args[0]
    code     = db_error.code       # e.g. 20002, 1 (unique), 2291 (FK)
    message  = db_error.message    # full ORA-NNNNN: ... string

    # Strip the "ORA-20NNN: " prefix for application-level errors,
    # leaving only the message text written in RAISE_APPLICATION_ERROR.
    # Also strip the stack trace lines (everything after \nORA-06512).
    clean = re.split(r'\nORA-06512', message)[0]   # remove stack trace
    clean = re.sub(r'^ORA-\d+:\s*', '', clean).strip()

    return code, clean


# =============================================================================
# ── SECTION 1: INFRASTRUCTURE ────────────────────────────────────────────────
# =============================================================================

@app.route("/health", methods=["GET"])
def health_check():
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                # Oracle's equivalent of MySQL's SELECT 1 — uses DUAL
                cur.execute("SELECT 1 FROM dual")
                cur.fetchone()
        return success_response({"status": "healthy", "pool": get_pool_status()})
    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database unreachable: {msg}", 503, code)


# =============================================================================
# ── SECTION 2: CANDIDATE ROUTES ───────────────────────────────────────────────
# =============================================================================

@app.route("/api/candidates/<int:user_id>/applications", methods=["GET"])
def get_candidate_application_history(user_id: int):
    """
    GET /api/candidates/<user_id>/applications

    BIND VARIABLE TRANSLATION:
      MySQL:  WHERE candidate_user_id = %s   params=(user_id,)
      Oracle: WHERE candidate_user_id = :user_id   params={"user_id": user_id}

    ROWFACTORY PATTERN:
      After cursor.execute(), we assign cursor.rowfactory so that
      cursor.fetchall() returns a list of dicts instead of a list of tuples.
      The rowfactory must be assigned AFTER execute (not before) because
      cursor.description (column names) is only populated after execution.
    """
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:

                # ── Named bind variable — :user_id — passed as dict ──────────
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
                        (SELECT COUNT(*) FROM job_skills js WHERE js.job_id = j.job_id) AS required_skills_count
                    FROM      jobs            j
                    JOIN      education_levels el ON el.education_level_id = j.min_education_level_id
                    JOIN      users           u  ON u.user_id             = j.posted_by
                    WHERE {where_clause}
                    ORDER BY j.posted_at DESC
                """
                cur.execute(query, {"user_id": user_id})
                # Assign rowfactory AFTER execute (description is now populated)
                cur.rowfactory = _dict_row_factory(cur)
                applications   = cur.fetchall()

        if not applications:
            return success_response(
                {"message": "No applications found.", "applications": []}, 200
            )

        return success_response({
            "candidate_user_id": user_id,
            "total_applications": len(applications),
            "applications": applications
        })

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)


# =============================================================================
# ── SECTION 3: RECRUITER ROUTES ───────────────────────────────────────────────
# =============================================================================

@app.route("/api/jobs/<int:job_id>/ranked-candidates", methods=["GET"])
def get_ranked_candidates(job_id: int):
    """
    GET /api/jobs/<job_id>/ranked-candidates
    Optional: ?status=Shortlisted  ?min_score=50  ?limit=20

    DYNAMIC PARAMETERISED QUERY PATTERN:
      We accumulate both the WHERE fragments (strings) and a params dict
      simultaneously. Named bind variables prevent any ordering issues.
    """
    status_filter    = request.args.get("status",    None)
    min_score_filter = request.args.get("min_score", None)
    limit_filter     = request.args.get("limit",     None)

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:

                conditions = ["job_id = :job_id"]
                params     = {"job_id": job_id}

                if status_filter:
                    conditions.append("application_status = :status")
                    params["status"] = status_filter

                if min_score_filter:
                    try:
                        params["min_score"] = float(min_score_filter)
                        conditions.append("computed_score >= :min_score")
                    except ValueError:
                        return error_response("min_score must be numeric.", 400)

                where_clause = " AND ".join(conditions)

                # Oracle ROWNUM / FETCH FIRST for limiting rows
                # Oracle 12c+: FETCH FIRST n ROWS ONLY (SQL standard)
                # Older Oracle: WHERE ROWNUM <= n  (must wrap in subquery)
                fetch_clause = ""
                if limit_filter:
                    try:
                        limit_int = int(limit_filter)
                        if limit_int < 1:
                            raise ValueError
                        # FETCH FIRST is Oracle 12c+ SQL standard syntax
                        fetch_clause = f"FETCH FIRST {limit_int} ROWS ONLY"
                    except ValueError:
                        return error_response("limit must be a positive integer.", 400)

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
                    FROM vw_ranked_candidates
                    WHERE {where_clause}
                    ORDER BY score_rank ASC
                    {fetch_clause}
                """

                cur.execute(query, params)
                cur.rowfactory = _dict_row_factory(cur)
                candidates     = cur.fetchall()

        return success_response({
            "job_id":         job_id,
            "total_returned": len(candidates),
            "candidates":     candidates
        })

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)


@app.route("/api/jobs/<int:job_id>/skill-gap", methods=["GET"])
def get_skill_gap_analysis(job_id: int):
    """GET /api/jobs/<job_id>/skill-gap"""
    candidate_filter = request.args.get("candidate_id", None)

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:

                conditions = ["job_id = :job_id"]
                params     = {"job_id": job_id}

                if candidate_filter:
                    try:
                        params["candidate_id"] = int(candidate_filter)
                        conditions.append("candidate_id = :candidate_id")
                    except ValueError:
                        return error_response("candidate_id must be an integer.", 400)

                where_clause = " AND ".join(conditions)
                query = f"""
                    SELECT
                        job_title, department, application_id,
                        candidate_id, candidate_name, application_status,
                        computed_score, missing_skill_name,
                        missing_skill_category, gap_type,
                        total_mandatory_gaps, total_mandatory_required,
                        mandatory_gap_pct
                    FROM vw_skill_gap_analysis
                    WHERE {where_clause}
                    ORDER BY total_mandatory_gaps DESC, candidate_name ASC
                """
                cur.execute(query, params)
                cur.rowfactory = _dict_row_factory(cur)
                gaps = cur.fetchall()

        return success_response({
            "job_id": job_id,
            "total_gap_rows": len(gaps),
            "skill_gaps": gaps
        })

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)


# =============================================================================
# ── SECTION 4: ADMIN ROUTES ───────────────────────────────────────────────────
# =============================================================================

@app.route("/api/admin/funnel-summary", methods=["GET"])
def get_job_funnel_summary():
    department_filter = request.args.get("department", None)
    active_only       = request.args.get("active_only", "false").lower() == "true"

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:

                conditions = []
                params     = {}

                if department_filter:
                    conditions.append("department = :department")
                    params["department"] = department_filter

                if active_only:
                    conditions.append("is_active = 1")

                where_clause = (
                    "WHERE " + " AND ".join(conditions) if conditions else ""
                )

                query = f"""
                    SELECT
                        job_id, job_title, department, location,
                        job_type, is_active, posted_by, posted_at, deadline,
                        total_applications, cnt_submitted, cnt_under_review,
                        cnt_shortlisted, cnt_interview_scheduled,
                        cnt_offer_extended, cnt_hired, cnt_rejected,
                        cnt_withdrawn, avg_computed_score,
                        max_computed_score, min_computed_score,
                        shortlist_conversion_pct, offer_conversion_pct,
                        total_skills_required, mandatory_skills_count
                    FROM vw_job_funnel_summary
                    {where_clause}
                    ORDER BY posted_at DESC
                """
                cur.execute(query, params)
                cur.rowfactory = _dict_row_factory(cur)
                summary = cur.fetchall()

        return success_response({"total_jobs": len(summary), "funnel": summary})

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)


# =============================================================================
# ── SECTION 5: DML WITH EXPLICIT TRANSACTION CONTROL ─────────────────────────
# =============================================================================

@app.route("/api/applications", methods=["POST"])
def submit_application():
    """
    POST /api/applications
    Body: { "job_id": int, "candidate_id": int, "cover_letter": str }

    CRITICAL ORACLE DIFFERENCES vs MySQL version:

    1. RETURNING ... INTO :out_var  (replaces cursor.lastrowid)
       ─────────────────────────────────────────────────────────
       MySQL:  cursor.execute(INSERT); new_id = cursor.lastrowid
       Oracle: Define an output variable BEFORE executing:
                 out_id = cursor.var(oracledb.NUMBER)
               Then include RETURNING in the INSERT:
                 INSERT INTO ... VALUES (...) RETURNING application_id INTO :out_id
               Then read:
                 new_id = int(out_id.getvalue())

    2. Calling a procedure with a REF CURSOR OUT parameter
       ─────────────────────────────────────────────────────
       MySQL:  cursor.execute("CALL sp_name(%s)", (id,))
               breakdown = cursor.fetchone()
               while cursor.nextset(): pass   ← consume multiple result sets

       Oracle: out_cursor = cursor.var(oracledb.CURSOR)
               cursor.execute(
                   "BEGIN sp_calculate_candidate_score(:p_id, :p_cur); END;",
                   {"p_id": new_id, "p_cur": out_cursor}
               )
               ref_cur   = out_cursor.getvalue()
               ref_cur.rowfactory = _dict_row_factory(ref_cur)
               breakdown = ref_cur.fetchone()
               ref_cur.close()
               ← No nextset() needed — Oracle uses REF CURSOR, not result sets

    3. Transaction management
       ─────────────────────────────────────────────────
       MySQL:  conn.start_transaction()  ← explicit begin
       Oracle: Nothing needed — Oracle connections always start in a
               transaction. The first DML statement begins a transaction
               implicitly. Commit or rollback ends it.
    """
    body = request.get_json(silent=True)
    if not body:
        return error_response("Request body must be valid JSON.", 400)

    job_id       = body.get("job_id")
    candidate_id = body.get("candidate_id")
    cover_letter = body.get("cover_letter", None)

    if not job_id or not candidate_id:
        return error_response("job_id and candidate_id are required.", 400)

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                try:
                    # ── Phase A: INSERT with RETURNING ────────────────────────
                    # Define the output variable for RETURNING ... INTO
                    out_id = cur.var(oracledb.NUMBER)

                    # Named bind variables for all inputs AND the output var.
                    # The RETURNING clause writes the generated PK into :out_id.
                    cur.execute(
                        """
                        INSERT INTO applications
                            (job_id, candidate_id, cover_letter)
                        VALUES
                            (:job_id, :candidate_id, :cover_letter)
                        RETURNING application_id INTO :out_id
                        """,
                        {
                            "job_id":       job_id,
                            "candidate_id": candidate_id,
                            "cover_letter": cover_letter,
                            "out_id":       out_id,          # output bind var
                        }
                    )

                    # Retrieve the generated application_id from the output var
                    new_application_id = int(out_id.getvalue()[0])

                    # ── Phase B: Score via stored procedure ───────────────────
                    # Oracle procedure call using anonymous PL/SQL block.
                    # Preferred over callproc() when the procedure has REF CURSOR
                    # OUT parameters, as callproc() doesn't handle them cleanly.
                    out_cursor = cur.var(oracledb.CURSOR)

                    cur.execute(
                        """
                        BEGIN
                            sp_calculate_candidate_score(:p_app_id, :p_cursor);
                        END;
                        """,
                        {
                            "p_app_id":  new_application_id,
                            "p_cursor":  out_cursor,          # REF CURSOR output
                        }
                    )

                    # Materialise the REF CURSOR result set
                    ref_cur = out_cursor.getvalue()
                    ref_cur.rowfactory = _dict_row_factory(ref_cur)
                    score_breakdown    = ref_cur.fetchone()
                    ref_cur.close()

                    # ── COMMIT — both INSERT and score UPDATE are durable ──────
                    conn.commit()

                    return success_response({
                        "message":         "Application submitted and scored.",
                        "application_id":  new_application_id,
                        "score_breakdown": score_breakdown
                    }, 201)

                except oracledb.Error as db_err:
                    # ── ROLLBACK — INSERT vanishes with the failed score call ──
                    conn.rollback()

                    code, msg = _parse_oracle_error(db_err)

                    # ORA-00001 = unique constraint violation
                    # (maps to MySQL errno 1062)
                    if code == 1:
                        return error_response(
                            "This candidate has already applied to this job.",
                            409
                        )

                    # ORA-20003 = our custom "application not found" from procedure
                    if code == 20003:
                        return error_response(msg, 400, code)

                    app.logger.error(
                        f"[submit_application] ORA-{code:05d}: {msg}"
                    )
                    return error_response(
                        f"Database error during submission: {msg}", 500, code
                    )

    except oracledb.Error as pool_err:
        _, msg = _parse_oracle_error(pool_err)
        return error_response(f"Could not connect to database: {msg}", 503)


@app.route("/api/applications/<int:application_id>/status", methods=["PATCH"])
def update_application_status(application_id: int):
    """
    PATCH /api/applications/<application_id>/status
    Body: { "new_status": "Shortlisted" }

    ORACLE PROCEDURE CALL PATTERN:
      MySQL:  cursor.execute("CALL sp_update_application_status(%s, %s)", (...))
      Oracle: cursor.execute(
                  "BEGIN sp_update_application_status(:p_id, :p_status); END;",
                  {"p_id": ..., "p_status": ...}
              )

    ERROR CODE MAPPING:
      ORA-20001 → HTTP 404  (application not found)
      ORA-20002 → HTTP 400  (illegal transition — includes both statuses in msg)
    """
    body = request.get_json(silent=True)
    if not body:
        return error_response("Request body must be valid JSON.", 400)

    new_status = body.get("new_status", "").strip()
    if not new_status:
        return error_response("new_status is required.", 400)

    VALID_STATUSES = {
        "Submitted", "Under Review", "Shortlisted",
        "Interview Scheduled", "Offer Extended",
        "Hired", "Rejected", "Withdrawn"
    }
    if new_status not in VALID_STATUSES:
        return error_response(
            f"'{new_status}' is not a recognised status. "
            f"Valid: {sorted(VALID_STATUSES)}",
            400
        )

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                try:
                    # ── Call the PL/SQL state machine procedure ────────────────
                    # Anonymous PL/SQL block syntax: BEGIN proc(:a, :b); END;
                    cur.execute(
                        """
                        BEGIN
                            sp_update_application_status(:p_app_id, :p_status);
                        END;
                        """,
                        {
                            "p_app_id":  application_id,
                            "p_status":  new_status,
                        }
                    )

                    # ── Fetch the updated row to return ───────────────────────
                    cur.execute(
                        """
                        SELECT application_id,
                               status,
                               computed_score,
                               last_status_change
                        FROM   applications
                        WHERE  application_id = :app_id
                        """,
                        {"app_id": application_id}
                    )
                    cur.rowfactory = _dict_row_factory(cur)
                    updated_row    = cur.fetchone()

                    # ── COMMIT ────────────────────────────────────────────────
                    conn.commit()

                    return success_response({
                        "message":     f"Status updated to '{new_status}'.",
                        "application": updated_row
                    })

                except oracledb.Error as db_err:
                    conn.rollback()
                    code, msg = _parse_oracle_error(db_err)

                    # ORA-20001: Application not found
                    if code == 20001:
                        return error_response(msg, 404, code)

                    # ORA-20002: Illegal status transition
                    # msg already contains both the current and target status:
                    # "Illegal status transition from 'Under Review' to 'Hired'."
                    if code == 20002:
                        return error_response(msg, 400, code)

                    app.logger.error(f"[update_status] ORA-{code:05d}: {msg}")
                    return error_response(
                        f"Database error during status update: {msg}", 500, code
                    )

    except oracledb.Error as pool_err:
        _, msg = _parse_oracle_error(pool_err)
        return error_response(f"Could not connect to database: {msg}", 503)


# =============================================================================
# ── SECTION 6: SUPPORTING READ ROUTES ────────────────────────────────────────
# =============================================================================

@app.route("/api/jobs", methods=["GET"])
def get_active_jobs():
    department_filter = request.args.get("department", None)
    job_type_filter   = request.args.get("job_type",   None)

    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:

                conditions = ["j.is_active = 1"]
                params     = {}

                if department_filter:
                    conditions.append("j.department = :department")
                    params["department"] = department_filter

                if job_type_filter:
                    conditions.append("j.job_type = :job_type")
                    params["job_type"] = job_type_filter

                where_clause = " AND ".join(conditions)

                cur.execute(
                    f"""
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
                        (SELECT COUNT(*) FROM job_skills js WHERE js.job_id = j.job_id) AS required_skills_count
                    FROM      jobs            j
                    JOIN      education_levels el ON el.education_level_id = j.min_education_level_id
                    JOIN      users           u  ON u.user_id             = j.posted_by
                    WHERE {where_clause}
                    ORDER BY j.posted_at DESC
                    """,
                    params
                )
                cur.rowfactory = _dict_row_factory(cur)
                jobs = cur.fetchall()

        return success_response({"total_jobs": len(jobs), "jobs": jobs})

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)

@app.route("/api/applications/<int:application_id>/audit", methods=["GET"])
def get_application_audit_trail(application_id: int):
    """Returns status change history written by trg_application_status_update."""
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT audit_id, old_status, new_status,
                           changed_at, changed_by
                    FROM   application_status_audit
                    WHERE  application_id = :app_id
                    ORDER BY changed_at ASC
                    """,
                    {"app_id": application_id}
                )
                cur.rowfactory = _dict_row_factory(cur)
                audit_log      = cur.fetchall()

        return success_response({
            "application_id": application_id,
            "total_events":   len(audit_log),
            "audit_trail":    audit_log
        })

    except oracledb.Error as e:
        code, msg = _parse_oracle_error(e)
        return error_response(f"Database error: {msg}", 500, code)


# =============================================================================
# ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
