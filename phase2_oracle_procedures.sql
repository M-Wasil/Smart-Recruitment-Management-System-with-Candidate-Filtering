-- =============================================================================
-- SMART RECRUITMENT MANAGEMENT SYSTEM — ORACLE MIGRATION
-- Phase 2: PL/SQL Stored Procedures & Triggers
-- =============================================================================
-- KEY TRANSLATION DECISIONS:
--
--   SIGNAL SQLSTATE '45000'  → RAISE_APPLICATION_ERROR(-20001, 'message')
--                               Oracle reserves error numbers -20000 to -20999
--                               for application-defined errors.
--                               We map our custom errnos:
--                                 45001 → -20001  (application not found)
--                                 45002 → -20002  (illegal transition)
--                                 45003 → -20003  (scoring: app not found)
--
--   DELIMITER // ... //      → Not needed. Oracle uses BEGIN...END; and a
--                               standalone / on its own line to execute a
--                               PL/SQL block in SQL*Plus / SQLcl.
--
--   DECLARE v_x INT          → v_x  NUMBER;  (inside DECLARE section)
--
--   IF ... ELSEIF ...        → IF ... ELSIF ...  (note: no 'E' before 'IF')
--
--   LEAVE procedure_label    → No direct equivalent needed — use RETURN
--                               for early exit from a procedure.
--
--   LAST_INSERT_ID()         → RETURNING col INTO :bind_var
--                               (used in the Python layer, not in procedures)
--
--   cursor.nextset()         → Not needed — Oracle procedures use OUT params
--                               or REF CURSORs instead of multiple result sets.
--
--   NEW.col / OLD.col        → :NEW.col / :OLD.col  (colon prefix required)
--
--   CURRENT_TIMESTAMP        → SYSTIMESTAMP
--
--   CURRENT_USER()           → SYS_CONTEXT('USERENV', 'SESSION_USER')
-- =============================================================================


-- =============================================================================
-- SECTION A: TRIGGER — trg_application_status_update
-- =============================================================================
-- Type   : BEFORE UPDATE on applications
-- Purpose: (1) Stamp last_status_change when status changes
--          (2) Write an immutable row to application_status_audit
--
-- Oracle Trigger Syntax differences vs MySQL:
--   :NEW.col  — references the new value (writable in BEFORE trigger)
--   :OLD.col  — references the old value (read-only)
--   No DELIMITER needed; the / on its own line terminates the block.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_application_status_update
BEFORE UPDATE ON applications
FOR EACH ROW
BEGIN
    -- Only act when the status column is actually changing
    IF :OLD.status <> :NEW.status THEN

        -- ── Responsibility 1: Stamp the transition time ───────────────────
        -- SYSTIMESTAMP is the Oracle equivalent of MySQL's CURRENT_TIMESTAMP.
        -- Writing to :NEW.last_status_change here modifies the row being
        -- written — identical BEFORE trigger semantics to MySQL.
        :NEW.last_status_change := SYSTIMESTAMP;

        -- ── Responsibility 2: Write the immutable audit record ────────────
        -- SYS_CONTEXT('USERENV','SESSION_USER') is Oracle's CURRENT_USER().
        INSERT INTO application_status_audit
            (application_id, old_status, new_status, changed_by)
        VALUES
            (:OLD.application_id,
             :OLD.status,
             :NEW.status,
             SYS_CONTEXT('USERENV', 'SESSION_USER'));

    END IF;
END;
/


-- =============================================================================
-- SECTION B: PROCEDURE — sp_update_application_status
-- =============================================================================
-- Parameters:
--   p_application_id  NUMBER   — the application to update
--   p_new_status      VARCHAR2 — the desired target status
--
-- Error codes (Oracle -20000 range, maps from our MySQL custom errnos):
--   -20001 : Application not found
--   -20002 : Illegal or unsupported status transition
-- =============================================================================
CREATE OR REPLACE PROCEDURE sp_update_application_status (
    p_application_id  IN  NUMBER,
    p_new_status      IN  VARCHAR2
)
AS
    -- ── PL/SQL variable declarations (in the AS/IS section, before BEGIN) ──
    v_current_status    VARCHAR2(20);
    v_transition_valid  NUMBER(1,0) := 0;
BEGIN
    -- ── Step 1: Fetch current status ──────────────────────────────────────
    -- SELECT INTO raises NO_DATA_FOUND if the row doesn't exist.
    -- We catch it below and convert to our application error.
    BEGIN
        SELECT status
        INTO   v_current_status
        FROM   applications
        WHERE  application_id = p_application_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Oracle equivalent of MySQL SIGNAL SQLSTATE '45000' / errno 45001
            RAISE_APPLICATION_ERROR(
                -20001,
                'sp_update_application_status: Application ID '
                || p_application_id || ' not found.'
            );
    END;

    -- ── Step 2: Idempotency — same-state is a silent no-op ────────────────
    -- RETURN in Oracle PL/SQL exits the procedure immediately (= MySQL LEAVE)
    IF v_current_status = p_new_status THEN
        RETURN;
    END IF;

    -- ── Step 3: Validate the transition ───────────────────────────────────
    -- Oracle uses ELSIF (not ELSEIF).
    -- The logic mirrors the MySQL version exactly.
    IF p_new_status = 'Withdrawn'
       AND v_current_status NOT IN ('Hired', 'Rejected', 'Withdrawn') THEN
        v_transition_valid := 1;

    ELSIF v_current_status = 'Submitted'
      AND p_new_status     = 'Under Review' THEN
        v_transition_valid := 1;

    ELSIF v_current_status = 'Under Review'
      AND p_new_status     = 'Shortlisted' THEN
        v_transition_valid := 1;

    ELSIF v_current_status = 'Shortlisted'
      AND p_new_status     = 'Interview Scheduled' THEN
        v_transition_valid := 1;

    ELSIF v_current_status = 'Interview Scheduled'
      AND p_new_status     = 'Offer Extended' THEN
        v_transition_valid := 1;

    ELSIF v_current_status = 'Offer Extended'
      AND p_new_status     = 'Hired' THEN
        v_transition_valid := 1;

    ELSIF v_current_status IN (
              'Submitted', 'Under Review', 'Shortlisted',
              'Interview Scheduled', 'Offer Extended'
          )
      AND p_new_status = 'Rejected' THEN
        v_transition_valid := 1;
    END IF;

    -- ── Step 4: Block illegal transitions ─────────────────────────────────
    IF v_transition_valid = 0 THEN
        -- Oracle equivalent of MySQL SIGNAL SQLSTATE '45000' / errno 45002
        RAISE_APPLICATION_ERROR(
            -20002,
            'Illegal status transition from ''' || v_current_status
            || ''' to ''' || p_new_status || '''.'
        );
    END IF;

    -- ── Step 5: Perform the UPDATE (fires trg_application_status_update) ──
    UPDATE applications
    SET    status = p_new_status
    WHERE  application_id = p_application_id;

    -- Note: In Oracle, the calling code (Python) manages COMMIT/ROLLBACK.
    -- Procedures should NOT commit internally unless specifically designed
    -- as autonomous transactions — this keeps them composable.

END sp_update_application_status;
/


-- =============================================================================
-- SECTION C: PROCEDURE — sp_calculate_candidate_score
-- =============================================================================
-- Parameters:
--   p_application_id  NUMBER  — the application to score
--
-- Returns: a single result row via a SYS_REFCURSOR OUT parameter.
-- The Python layer fetches this cursor — no multiple result sets needed
-- (Oracle uses REF CURSORs; MySQL used multiple result sets + nextset()).
--
-- Error codes:
--   -20003 : Application not found
-- =============================================================================
CREATE OR REPLACE PROCEDURE sp_calculate_candidate_score (
    p_application_id  IN  NUMBER,
    p_result_cursor   OUT SYS_REFCURSOR     -- replaces MySQL's SELECT result set
)
AS
    -- ── Identity variables ─────────────────────────────────────────────────
    v_candidate_id          NUMBER;
    v_job_id                NUMBER;

    -- ── Education sub-score ────────────────────────────────────────────────
    v_candidate_edu_weight  NUMBER(2,0);
    v_job_min_edu_weight    NUMBER(2,0);
    v_edu_score             NUMBER(6,2) := 0;

    -- ── Experience sub-score ──────────────────────────────────────────────
    v_candidate_exp         NUMBER(4,1);
    v_job_min_exp           NUMBER(4,1);
    v_exp_score             NUMBER(6,2) := 0;

    -- ── Skill sub-score ───────────────────────────────────────────────────
    v_mandatory_matches     NUMBER := 0;
    v_optional_matches      NUMBER := 0;
    v_total_mandatory_req   NUMBER := 0;
    v_total_optional_req    NUMBER := 0;
    v_skill_raw             NUMBER(8,2) := 0;
    v_skill_max_raw         NUMBER(8,2) := 0;
    v_skill_score           NUMBER(6,2) := 0;

    -- ── Final ─────────────────────────────────────────────────────────────
    v_final_score           NUMBER(6,2) := 0;

BEGIN
    -- ── Step 1: Resolve IDs ───────────────────────────────────────────────
    BEGIN
        SELECT a.candidate_id, a.job_id
        INTO   v_candidate_id, v_job_id
        FROM   applications a
        WHERE  a.application_id = p_application_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(
                -20003,
                'sp_calculate_candidate_score: Application ID '
                || p_application_id || ' not found.'
            );
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- ① EDUCATION SCORE (max 20 pts)
    -- ══════════════════════════════════════════════════════════════════════
    SELECT el.score_weight
    INTO   v_candidate_edu_weight
    FROM   candidates c
    JOIN   education_levels el ON el.education_level_id = c.education_level_id
    WHERE  c.candidate_id = v_candidate_id;

    SELECT el.score_weight
    INTO   v_job_min_edu_weight
    FROM   jobs j
    JOIN   education_levels el ON el.education_level_id = j.min_education_level_id
    WHERE  j.job_id = v_job_id;

    v_edu_score := v_candidate_edu_weight * 2;

    IF v_candidate_edu_weight > v_job_min_edu_weight THEN
        v_edu_score := v_edu_score + 2;
    END IF;

    -- LEAST() function is identical in Oracle
    v_edu_score := LEAST(v_edu_score, 20);

    -- ══════════════════════════════════════════════════════════════════════
    -- ② EXPERIENCE SCORE (max 30 pts)
    -- ══════════════════════════════════════════════════════════════════════
    SELECT c.years_of_experience, j.min_experience_years
    INTO   v_candidate_exp, v_job_min_exp
    FROM   candidates c
    JOIN   applications a ON a.candidate_id = c.candidate_id
    JOIN   jobs         j ON j.job_id       = a.job_id
    WHERE  a.application_id = p_application_id;

    IF v_job_min_exp = 0 THEN
        v_exp_score := 20;
    ELSIF v_candidate_exp < v_job_min_exp THEN
        -- GREATEST / FLOOR are identical in Oracle
        v_exp_score := GREATEST(
            0,
            FLOOR((v_candidate_exp / v_job_min_exp) * 20)
        );
    ELSIF v_candidate_exp = v_job_min_exp THEN
        v_exp_score := 20;
    ELSIF (v_candidate_exp - v_job_min_exp) < 2 THEN
        v_exp_score := 25;
    ELSE
        v_exp_score := 30;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- ③ SKILL MATCH SCORE (max 50 pts)
    -- ══════════════════════════════════════════════════════════════════════
    SELECT COUNT(*)
    INTO   v_mandatory_matches
    FROM   job_skills       js
    JOIN   candidate_skills cs ON cs.skill_id     = js.skill_id
                               AND cs.candidate_id = v_candidate_id
    WHERE  js.job_id       = v_job_id
      AND  js.is_mandatory = 1;

    SELECT COUNT(*)
    INTO   v_optional_matches
    FROM   job_skills       js
    JOIN   candidate_skills cs ON cs.skill_id     = js.skill_id
                               AND cs.candidate_id = v_candidate_id
    WHERE  js.job_id       = v_job_id
      AND  js.is_mandatory = 0;

    SELECT
        SUM(CASE WHEN is_mandatory = 1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN is_mandatory = 0 THEN 1 ELSE 0 END)
    INTO
        v_total_mandatory_req,
        v_total_optional_req
    FROM job_skills
    WHERE job_id = v_job_id;

    -- NVL is Oracle's equivalent of MySQL COALESCE for a single fallback value
    v_total_mandatory_req := NVL(v_total_mandatory_req, 0);
    v_total_optional_req  := NVL(v_total_optional_req,  0);

    v_skill_raw     := (v_mandatory_matches * 2) + (v_optional_matches * 1);
    v_skill_max_raw := (v_total_mandatory_req * 2) + (v_total_optional_req * 1);

    IF v_skill_max_raw = 0 THEN
        v_skill_score := 50;
    ELSE
        v_skill_score := LEAST(
            50,
            -- ROUND in Oracle: ROUND(value, decimal_places) — identical
            ROUND((v_skill_raw / v_skill_max_raw) * 50, 2)
        );
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- FINAL SCORE
    -- ══════════════════════════════════════════════════════════════════════
    v_final_score := LEAST(100, ROUND(v_edu_score + v_exp_score + v_skill_score, 2));

    -- Persist the score
    UPDATE applications
    SET    computed_score = v_final_score
    WHERE  application_id = p_application_id;

    -- ── Return breakdown via REF CURSOR (replaces MySQL multiple result set) ─
    -- The Python caller does: cursor.var(oracledb.CURSOR) then fetchall()
    OPEN p_result_cursor FOR
        SELECT
            p_application_id                AS application_id,
            v_candidate_id                  AS candidate_id,
            v_job_id                        AS job_id,
            ROUND(v_edu_score,   2)         AS education_score,
            ROUND(v_exp_score,   2)         AS experience_score,
            ROUND(v_skill_score, 2)         AS skill_match_score,
            v_mandatory_matches             AS mandatory_skills_matched,
            v_total_mandatory_req           AS mandatory_skills_required,
            v_optional_matches              AS optional_skills_matched,
            v_total_optional_req            AS optional_skills_required,
            v_final_score                   AS final_computed_score
        FROM dual;
        -- FROM DUAL: Oracle's single-row dummy table — required when a SELECT
        -- has no real FROM clause (MySQL allows SELECT without FROM).

END sp_calculate_candidate_score;
/


-- =============================================================================
-- SECTION D: VERIFICATION
-- =============================================================================

-- Confirm all PL/SQL objects compiled without errors
SELECT object_name, object_type, status, last_ddl_time
FROM   user_objects
WHERE  object_type IN ('PROCEDURE', 'TRIGGER')
  AND  object_name IN (
    'SP_UPDATE_APPLICATION_STATUS',
    'SP_CALCULATE_CANDIDATE_SCORE',
    'TRG_APPLICATION_STATUS_UPDATE',
    'TRG_USERS_UPDATED_AT',
    'TRG_CANDIDATES_UPDATED_AT'
  )
ORDER BY object_type, object_name;

-- Show any compilation errors (should return no rows if status = VALID)
SELECT name, type, line, position, text AS error_message
FROM   user_errors
WHERE  name IN (
    'SP_UPDATE_APPLICATION_STATUS',
    'SP_CALCULATE_CANDIDATE_SCORE',
    'TRG_APPLICATION_STATUS_UPDATE'
)
ORDER BY name, line;
