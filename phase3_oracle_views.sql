-- =============================================================================
-- SMART RECRUITMENT MANAGEMENT SYSTEM — ORACLE MIGRATION
-- Phase 3: Views, Window Functions & Reporting (DQL) — Oracle 12c+
-- =============================================================================
-- KEY TRANSLATION DECISIONS:
--
--   DATEDIFF(CURRENT_DATE, date_col)
--     → TRUNC(SYSDATE) - TRUNC(CAST(date_col AS DATE))
--       Oracle date subtraction returns a NUMBER of days (a decimal).
--       TRUNC() strips the time component for clean day counts.
--       CAST(timestamp AS DATE) converts TIMESTAMP → DATE first.
--
--   CURRENT_DATE        → SYSDATE (or TRUNC(SYSDATE) for date-only)
--   CURRENT_TIMESTAMP   → SYSTIMESTAMP
--
--   NULLIF(expr, 0)     → Identical in Oracle ✓
--   COALESCE(...)       → NVL(...) for single fallback, or COALESCE for multi
--   ROUND(val, n)       → Identical in Oracle ✓
--
--   CONCAT(a, b, c)     → a || b || c  (Oracle || is the concat operator)
--                          CONCAT() only accepts two arguments in Oracle.
--
--   CREATE OR REPLACE VIEW → Identical in Oracle ✓
--
--   Window functions (RANK, DENSE_RANK, ROW_NUMBER, PERCENT_RANK, AVG OVER,
--   MAX OVER, COUNT OVER) → ALL identical in Oracle (Oracle invented them) ✓
--
--   NULLS LAST in ORDER BY → Identical in Oracle ✓
--                             (Oracle's default is NULLS LAST for DESC,
--                              but explicit is better for documentation)
-- =============================================================================


-- =============================================================================
-- VIEW 1: vw_ranked_candidates
-- Consumer   : Recruiter dashboard
-- Oracle note: Window functions (RANK, DENSE_RANK, etc.) are identical —
--              Oracle invented analytic functions in Oracle 8i.
--              Only date arithmetic and string functions differ.
-- =============================================================================
CREATE OR REPLACE VIEW vw_ranked_candidates AS
SELECT
    -- ── Job context ────────────────────────────────────────────────────────
    j.job_id,
    j.title                                 AS job_title,
    j.department,
    j.location,
    j.min_experience_years                  AS job_min_experience,
    edu_job.level_name                      AS job_min_education_required,

    -- ── Application identity ───────────────────────────────────────────────
    a.application_id,
    a.status                                AS application_status,
    a.applied_at,
    a.last_status_change,
    a.recruiter_notes,

    -- ── Candidate profile ──────────────────────────────────────────────────
    c.candidate_id,
    u.full_name                             AS candidate_name,
    u.email                                 AS candidate_email,
    edu_cand.level_name                     AS candidate_education,
    c.years_of_experience                   AS candidate_experience,
    c.linkedin_url,

    -- ── Score ─────────────────────────────────────────────────────────────
    ROUND(a.computed_score, 2)              AS computed_score,

    -- ── Window Function 1: RANK() — identical Oracle syntax ───────────────
    RANK()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC NULLS LAST
        )                                   AS score_rank,

    -- ── Window Function 2: DENSE_RANK() ───────────────────────────────────
    DENSE_RANK()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC NULLS LAST
        )                                   AS score_dense_rank,

    -- ── Window Function 3: ROW_NUMBER() ───────────────────────────────────
    ROW_NUMBER()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC NULLS LAST,
                     a.application_id  ASC
        )                                   AS row_num,

    -- ── Window Function 4: PERCENT_RANK() ─────────────────────────────────
    ROUND(
        PERCENT_RANK()
            OVER (
                PARTITION BY a.job_id
                ORDER BY a.computed_score ASC NULLS FIRST
            ),
        4
    )                                       AS percentile_rank,

    -- ── Window Aggregate: job-level average ───────────────────────────────
    ROUND(
        AVG(a.computed_score)
            OVER (PARTITION BY a.job_id),
        2
    )                                       AS job_avg_score,

    ROUND(
        MAX(a.computed_score)
            OVER (PARTITION BY a.job_id),
        2
    )                                       AS job_top_score,

    COUNT(a.application_id)
        OVER (PARTITION BY a.job_id)        AS total_applicants_for_job

FROM       applications     a
JOIN       jobs             j       ON  j.job_id             = a.job_id
JOIN       candidates       c       ON  c.candidate_id       = a.candidate_id
JOIN       users            u       ON  u.user_id            = c.user_id
JOIN       education_levels edu_cand ON edu_cand.education_level_id
                                                             = c.education_level_id
JOIN       education_levels edu_job  ON edu_job.education_level_id
                                                             = j.min_education_level_id
WHERE      a.status <> 'Withdrawn';


-- =============================================================================
-- VIEW 2: vw_job_funnel_summary
-- Consumer   : Admin reporting dashboard
-- Oracle notes:
--   Conditional aggregation SUM(CASE WHEN...) → identical ✓
--   NULLIF()                                  → identical ✓
--   Correlated subqueries                     → identical ✓
-- =============================================================================
CREATE OR REPLACE VIEW vw_job_funnel_summary AS
SELECT
    j.job_id,
    j.title                                             AS job_title,
    j.department,
    j.location,
    j.job_type,
    j.is_active,
    j.posted_at,
    j.deadline,
    u.full_name                                         AS posted_by,
    el.level_name                                       AS min_education_required,
    j.min_experience_years,

    -- ── Funnel stage counts ────────────────────────────────────────────────
    COUNT(a.application_id)                             AS total_applications,
    SUM(CASE WHEN a.status = 'Submitted'           THEN 1 ELSE 0 END) AS cnt_submitted,
    SUM(CASE WHEN a.status = 'Under Review'        THEN 1 ELSE 0 END) AS cnt_under_review,
    SUM(CASE WHEN a.status = 'Shortlisted'         THEN 1 ELSE 0 END) AS cnt_shortlisted,
    SUM(CASE WHEN a.status = 'Interview Scheduled' THEN 1 ELSE 0 END) AS cnt_interview_scheduled,
    SUM(CASE WHEN a.status = 'Offer Extended'      THEN 1 ELSE 0 END) AS cnt_offer_extended,
    SUM(CASE WHEN a.status = 'Hired'               THEN 1 ELSE 0 END) AS cnt_hired,
    SUM(CASE WHEN a.status = 'Rejected'            THEN 1 ELSE 0 END) AS cnt_rejected,
    SUM(CASE WHEN a.status = 'Withdrawn'           THEN 1 ELSE 0 END) AS cnt_withdrawn,

    -- ── Score analytics ────────────────────────────────────────────────────
    -- NVL(expr, 0) is Oracle's two-argument null-replacement function.
    -- Equivalent to MySQL's COALESCE(expr, 0) for a single fallback.
    NVL(ROUND(AVG(a.computed_score), 2), 0)             AS avg_computed_score,
    NVL(ROUND(MAX(a.computed_score), 2), 0)             AS max_computed_score,
    NVL(ROUND(MIN(a.computed_score), 2), 0)             AS min_computed_score,

    -- ── Conversion metrics ─────────────────────────────────────────────────
    ROUND(
        SUM(CASE WHEN a.status IN (
                'Shortlisted','Interview Scheduled',
                'Offer Extended','Hired')
            THEN 1 ELSE 0 END) * 100.0
        / NULLIF(COUNT(a.application_id), 0),
        2
    )                                                   AS shortlist_conversion_pct,

    ROUND(
        SUM(CASE WHEN a.status IN ('Offer Extended','Hired')
            THEN 1 ELSE 0 END) * 100.0
        / NULLIF(COUNT(a.application_id), 0),
        2
    )                                                   AS offer_conversion_pct,

    -- ── Skill demand subqueries (correlated — identical to MySQL) ─────────
    (SELECT COUNT(*)
     FROM   job_skills js
     WHERE  js.job_id = j.job_id)                      AS total_skills_required,

    (SELECT COUNT(*)
     FROM   job_skills js
     WHERE  js.job_id      = j.job_id
       AND  js.is_mandatory = 1)                        AS mandatory_skills_count

FROM       jobs             j
LEFT JOIN  applications     a   ON  a.job_id   = j.job_id
JOIN       users            u   ON  u.user_id  = j.posted_by
JOIN       education_levels el  ON  el.education_level_id = j.min_education_level_id

GROUP BY
    j.job_id, j.title, j.department, j.location, j.job_type,
    j.is_active, j.posted_at, j.deadline, u.full_name,
    el.level_name, j.min_experience_years

HAVING COUNT(a.application_id) > 0

ORDER BY j.posted_at DESC;


-- =============================================================================
-- VIEW 3: vw_candidate_application_history
-- Consumer   : Candidate self-service portal (no score, no recruiter notes)
-- Oracle notes:
--   DATEDIFF(CURRENT_DATE, col)
--     → TRUNC(SYSDATE) - TRUNC(CAST(col AS DATE))
--       Oracle date subtraction produces a NUMBER of days (may be fractional).
--       TRUNC on both sides ensures whole-day arithmetic.
--       CAST(timestamp_col AS DATE) is required when the column is TIMESTAMP.
--
--   CASE expressions → identical ✓
-- =============================================================================
CREATE OR REPLACE VIEW vw_candidate_application_history AS
SELECT
    -- ── Identity (used for server-side row filtering in Python) ────────────
    u.user_id                               AS candidate_user_id,
    u.full_name                             AS candidate_name,
    u.email                                 AS candidate_email,

    -- ── Application ───────────────────────────────────────────────────────
    a.application_id,
    a.status                                AS application_status,
    a.applied_at,
    a.last_status_change,

    -- ── Human-readable status description ─────────────────────────────────
    CASE a.status
        WHEN 'Submitted'           THEN 'Your application has been received.'
        WHEN 'Under Review'        THEN 'A recruiter is reviewing your application.'
        WHEN 'Shortlisted'         THEN 'Congratulations! You have been shortlisted.'
        WHEN 'Interview Scheduled' THEN 'An interview has been arranged. Check your email.'
        WHEN 'Offer Extended'      THEN 'An offer has been extended to you!'
        WHEN 'Hired'               THEN 'You have been hired for this position.'
        WHEN 'Rejected'            THEN 'Unfortunately, your application was not successful.'
        WHEN 'Withdrawn'           THEN 'You withdrew this application.'
        ELSE                            'Status unknown. Please contact support.'
    END                                     AS status_description,

    -- ── Date arithmetic — KEY ORACLE TRANSLATION ──────────────────────────
    -- MySQL:  DATEDIFF(CURRENT_DATE, applied_at)
    -- Oracle: TRUNC(SYSDATE) - TRUNC(CAST(applied_at AS DATE))
    --
    -- Explanation:
    --   applied_at is TIMESTAMP. DATE subtraction requires two DATEs.
    --   CAST(... AS DATE) converts TIMESTAMP to DATE (drops fractional seconds).
    --   TRUNC() strips the time-of-day component so we count whole days only.
    --   The result is a NUMBER (can be fractional without TRUNC on both sides).
    --   We wrap in FLOOR() to ensure a clean integer day count.
    FLOOR(TRUNC(SYSDATE) - TRUNC(CAST(a.applied_at AS DATE)))
                                            AS days_since_applied,

    FLOOR(TRUNC(SYSDATE) - TRUNC(CAST(a.last_status_change AS DATE)))
                                            AS days_since_last_update,

    -- ── Job context ────────────────────────────────────────────────────────
    j.job_id,
    j.title                                 AS job_title,
    j.department,
    j.location,
    j.job_type,
    j.deadline                              AS job_deadline,

    CASE
        WHEN j.deadline IS NULL             THEN 'No deadline set'
        -- Oracle DATE comparison: TRUNC(j.deadline) >= TRUNC(SYSDATE)
        WHEN TRUNC(j.deadline) >= TRUNC(SYSDATE) THEN 'Open'
        ELSE                                     'Deadline passed'
    END                                     AS deadline_status,

    -- ── Recruiter contact ─────────────────────────────────────────────────
    ru.full_name                            AS recruiter_name,
    ru.email                                AS recruiter_email

    -- NOTE: computed_score is ABSENT — role-based column suppression
    -- NOTE: recruiter_notes is ABSENT

FROM       applications a
JOIN       candidates   c   ON  c.candidate_id = a.candidate_id
JOIN       users        u   ON  u.user_id      = c.user_id
JOIN       jobs         j   ON  j.job_id       = a.job_id
JOIN       users        ru  ON  ru.user_id     = j.posted_by

ORDER BY a.applied_at DESC;


-- =============================================================================
-- VIEW 4: vw_skill_gap_analysis
-- Consumer   : Recruiter / Hiring Manager
-- Oracle note:
--   NOT EXISTS subquery → identical Oracle syntax ✓
--   The LEFT JOIN / IS NULL pattern is also shown in comments ✓
--   NULLIF()            → identical ✓
-- =============================================================================
CREATE OR REPLACE VIEW vw_skill_gap_analysis AS
SELECT
    j.job_id,
    j.title                                 AS job_title,
    j.department,
    c.candidate_id,
    u.full_name                             AS candidate_name,
    u.email                                 AS candidate_email,
    a.application_id,
    a.status                                AS application_status,
    ROUND(a.computed_score, 2)              AS computed_score,
    s.skill_id                              AS missing_skill_id,
    s.skill_name                            AS missing_skill_name,
    s.category                              AS missing_skill_category,
    'Mandatory'                             AS gap_type,

    -- ── Window: total mandatory gaps for this candidate+job pair ──────────
    COUNT(s.skill_id)
        OVER (PARTITION BY a.application_id)
                                            AS total_mandatory_gaps,

    -- ── Correlated subquery: total required for this job ──────────────────
    (SELECT COUNT(*)
     FROM   job_skills js2
     WHERE  js2.job_id      = j.job_id
       AND  js2.is_mandatory = 1)           AS total_mandatory_required,

    -- ── Gap percentage ─────────────────────────────────────────────────────
    ROUND(
        COUNT(s.skill_id) OVER (PARTITION BY a.application_id)
        * 100.0
        / NULLIF(
            (SELECT COUNT(*)
             FROM   job_skills js3
             WHERE  js3.job_id      = j.job_id
               AND  js3.is_mandatory = 1),
            0
        ),
        2
    )                                       AS mandatory_gap_pct

FROM       applications  a
JOIN       jobs          j   ON  j.job_id       = a.job_id
JOIN       candidates    c   ON  c.candidate_id = a.candidate_id
JOIN       users         u   ON  u.user_id      = c.user_id
JOIN       job_skills    js  ON  js.job_id       = j.job_id
                             AND js.is_mandatory  = 1
JOIN       skills        s   ON  s.skill_id     = js.skill_id

-- ── NOT EXISTS anti-join (identical Oracle syntax) ────────────────────────
WHERE NOT EXISTS (
    SELECT 1
    FROM   candidate_skills cs
    WHERE  cs.candidate_id = c.candidate_id
      AND  cs.skill_id     = js.skill_id
)
AND a.status NOT IN ('Withdrawn', 'Rejected', 'Hired')

ORDER BY j.job_id, a.computed_score DESC, c.candidate_id, s.skill_name;

-- =============================================================================
-- LEFT JOIN / IS NULL equivalent for Oracle (identical to MySQL version):
-- =============================================================================
/*
SELECT ...
FROM       applications  a
JOIN       jobs          j   ON j.job_id        = a.job_id
JOIN       candidates    c   ON c.candidate_id  = a.candidate_id
JOIN       job_skills    js  ON js.job_id        = j.job_id
                            AND js.is_mandatory  = 1
JOIN       skills        s   ON s.skill_id      = js.skill_id
LEFT JOIN  candidate_skills cs ON cs.candidate_id = c.candidate_id
                               AND cs.skill_id    = js.skill_id
WHERE  cs.candidate_id IS NULL
  AND  a.status NOT IN ('Withdrawn', 'Rejected', 'Hired');
*/


-- =============================================================================
-- VERIFICATION — Oracle data dictionary
-- =============================================================================
SELECT view_name, read_only
FROM   user_views
WHERE  view_name IN (
    'VW_RANKED_CANDIDATES',
    'VW_JOB_FUNNEL_SUMMARY',
    'VW_CANDIDATE_APPLICATION_HISTORY',
    'VW_SKILL_GAP_ANALYSIS'
)
ORDER BY view_name;
