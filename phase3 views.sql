-- =============================================================================
-- SMART RECRUITMENT MANAGEMENT SYSTEM
-- Phase 3: Advanced Querying, Window Functions & Reporting Views (DQL)
-- Database: MySQL 8.0+
-- =============================================================================
-- ARCHITECTURAL PRINCIPLE:
--   Every view here acts as a named, reusable query contract between the
--   database and the Flask backend. The Python layer calls:
--       SELECT * FROM vw_RankedCandidates WHERE job_id = ?
--   and receives a fully-shaped result set — no JOIN logic in Python.
--
-- VIEW INVENTORY:
--   1. vw_RankedCandidates          — Recruiter dashboard, window functions
--   2. vw_JobFunnelSummary          — Admin pipeline aggregate report
--   3. vw_CandidateApplicationHistory — Candidate self-service portal
--   4. vw_SkillGapAnalysis          — Recruiter missing-skills analysis
-- =============================================================================

USE recruitment_db;


-- =============================================================================
-- VIEW 1: vw_RankedCandidates
-- Consumer   : Recruiter dashboard
-- Purpose    : For every active job, rank all applicants by computed_score
--              using two complementary window functions so the recruiter UI
--              can display both dense rankings (1,1,2,3) for "position on the
--              list" and true rank gaps (1,1,3,4) for "absolute standing."
--
-- Window Function Explanation (for your report):
--   PARTITION BY job_id
--     Resets the rank counter for each job independently.
--     Without this, all candidates across all jobs would be ranked together.
--
--   ORDER BY computed_score DESC NULLS LAST
--     Candidates with no score yet (NULL) sink to the bottom rather than
--     incorrectly ranking first (NULL > any value in some SQL engines).
--
--   RANK()        → Skips numbers after ties.  Scores: 90,90,70 → Ranks: 1,1,3
--   DENSE_RANK()  → Never skips.               Scores: 90,90,70 → Ranks: 1,1,2
--   ROW_NUMBER()  → Always unique (tie-broken by application_id for stability).
--                   Useful for the UI to paginate results deterministically.
--
-- Security: This view is intentionally NOT exposed to candidates.
--           It includes computed_score and recruiter_notes.
-- =============================================================================

CREATE OR REPLACE VIEW vw_RankedCandidates AS
SELECT
    -- ── Job context ────────────────────────────────────────────────────────
    j.job_id,
    j.title                             AS job_title,
    j.department,
    j.location,
    j.min_experience_years              AS job_min_experience,
    edu_job.level_name                  AS job_min_education_required,

    -- ── Application identity ───────────────────────────────────────────────
    a.application_id,
    a.status                            AS application_status,
    a.applied_at,
    a.last_status_change,
    a.recruiter_notes,

    -- ── Candidate profile ──────────────────────────────────────────────────
    c.candidate_id,
    u.full_name                         AS candidate_name,
    u.email                             AS candidate_email,
    edu_cand.level_name                 AS candidate_education,
    c.years_of_experience               AS candidate_experience,
    c.linkedin_url,

    -- ── Score breakdown ────────────────────────────────────────────────────
    -- computed_score is the stored result from sp_CalculateCandidateScore.
    -- We present it rounded for display but keep full precision in the ORDER BY.
    ROUND(a.computed_score, 2)          AS computed_score,

    -- ── Window Function 1: RANK() ──────────────────────────────────────────
    -- Reflects "true competition" — tied candidates share a rank, and the
    -- next rank skips accordingly. Use this for "Position X out of N."
    RANK()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC
        )                               AS score_rank,

    -- ── Window Function 2: DENSE_RANK() ───────────────────────────────────
    -- No gaps in sequence. Use this for category labels like
    -- "Tier 1 / Tier 2 / Tier 3" candidates.
    DENSE_RANK()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC
        )                               AS score_dense_rank,

    -- ── Window Function 3: ROW_NUMBER() ───────────────────────────────────
    -- Guarantees a unique, stable row number within each job partition.
    -- Tie-broken by application_id (FIFO — earlier applicants rank higher
    -- when scores are equal). Essential for paginated API responses.
    ROW_NUMBER()
        OVER (
            PARTITION BY a.job_id
            ORDER BY a.computed_score DESC, a.application_id ASC
        )                               AS row_num,

    -- ── Window Function 4: Percentile within the job ──────────────────────
    -- PERCENT_RANK = (rank-1) / (total rows - 1)
    -- A value of 1.0 = top scorer; 0.0 = bottom scorer.
    -- Useful for: "This candidate is in the top X% for this role."
    ROUND(
        PERCENT_RANK()
            OVER (
                PARTITION BY a.job_id
                ORDER BY a.computed_score ASC   -- ASC so top scorer = 1.0
            ),
        4
    )                                   AS percentile_rank,

    -- ── Window aggregate: average score for this job ───────────────────────
    -- This is a window aggregate (not GROUP BY), so each row retains its
    -- own data AND sees the job-level average simultaneously.
    -- Allows the UI to show "Your score: 74.67 | Job average: 68.21"
    ROUND(
        AVG(a.computed_score)
            OVER (PARTITION BY a.job_id),
        2
    )                                   AS job_avg_score,

    -- ── Window aggregate: highest score for this job ───────────────────────
    ROUND(
        MAX(a.computed_score)
            OVER (PARTITION BY a.job_id),
        2
    )                                   AS job_top_score,

    -- ── Total applicant count for this job (window COUNT) ─────────────────
    COUNT(a.application_id)
        OVER (PARTITION BY a.job_id)    AS total_applicants_for_job

FROM       Applications      a
JOIN       Jobs              j    ON j.job_id             = a.job_id
JOIN       Candidates        c    ON c.candidate_id       = a.candidate_id
JOIN       Users             u    ON u.user_id            = c.user_id
JOIN       EducationLevels   edu_cand
                                  ON edu_cand.education_level_id
                                                          = c.education_level_id
JOIN       EducationLevels   edu_job
                                  ON edu_job.education_level_id
                                                          = j.min_education_level_id
-- Exclude withdrawn applications from the recruiter's ranked list.
-- They are still visible in the candidate's own history view (View 3).
WHERE      a.status <> 'Withdrawn';


-- =============================================================================
-- VIEW 2: vw_JobFunnelSummary
-- Consumer   : Admin reporting dashboard
-- Purpose    : Recruitment pipeline health at a glance.
--              Uses conditional aggregation (SUM + CASE) to pivot status
--              counts into columns — a classic SQL reporting pattern that
--              avoids multiple self-joins or application-level pivoting.
--
-- Key SQL Techniques:
--   CONDITIONAL AGGREGATION: SUM(CASE WHEN status = 'X' THEN 1 ELSE 0 END)
--     This is more efficient than COUNT with a WHERE clause because it scans
--     the Applications table exactly once, computing all status columns in a
--     single pass. A separate COUNT per status would require N table scans.
--
--   HAVING: Filters groups AFTER aggregation.
--     We use it here to exclude jobs with zero non-withdrawn applications
--     so the admin doesn't see empty rows for recently closed postings.
-- =============================================================================

CREATE OR REPLACE VIEW vw_JobFunnelSummary AS
SELECT
    -- ── Job identification ─────────────────────────────────────────────────
    j.job_id,
    j.title                                         AS job_title,
    j.department,
    j.location,
    j.job_type,
    j.is_active,
    j.posted_at,
    j.deadline,
    u.full_name                                     AS posted_by,
    edu.level_name                                  AS min_education_required,
    j.min_experience_years,

    -- ── Funnel stage counts (conditional aggregation) ──────────────────────
    -- Each column is a single-pass pivot over the status ENUM.
    COUNT(a.application_id)                         AS total_applications,

    SUM(CASE WHEN a.status = 'Submitted'
             THEN 1 ELSE 0 END)                     AS cnt_submitted,

    SUM(CASE WHEN a.status = 'Under Review'
             THEN 1 ELSE 0 END)                     AS cnt_under_review,

    SUM(CASE WHEN a.status = 'Shortlisted'
             THEN 1 ELSE 0 END)                     AS cnt_shortlisted,

    SUM(CASE WHEN a.status = 'Interview Scheduled'
             THEN 1 ELSE 0 END)                     AS cnt_interview_scheduled,

    SUM(CASE WHEN a.status = 'Offer Extended'
             THEN 1 ELSE 0 END)                     AS cnt_offer_extended,

    SUM(CASE WHEN a.status = 'Hired'
             THEN 1 ELSE 0 END)                     AS cnt_hired,

    SUM(CASE WHEN a.status = 'Rejected'
             THEN 1 ELSE 0 END)                     AS cnt_rejected,

    SUM(CASE WHEN a.status = 'Withdrawn'
             THEN 1 ELSE 0 END)                     AS cnt_withdrawn,

    -- ── Score analytics ────────────────────────────────────────────────────
    -- ROUND + COALESCE: if no applications are scored yet, return 0 not NULL.
    COALESCE(ROUND(AVG(a.computed_score),  2), 0)   AS avg_computed_score,
    COALESCE(ROUND(MAX(a.computed_score),  2), 0)   AS max_computed_score,
    COALESCE(ROUND(MIN(a.computed_score),  2), 0)   AS min_computed_score,

    -- ── Derived funnel conversion metrics ─────────────────────────────────
    -- "What % of applicants made it to shortlist or beyond?"
    -- Wrapped in NULLIF to avoid division-by-zero when total_applications = 0.
    ROUND(
        SUM(
            CASE WHEN a.status IN (
                'Shortlisted', 'Interview Scheduled',
                'Offer Extended', 'Hired'
            ) THEN 1 ELSE 0 END
        ) * 100.0
        / NULLIF(COUNT(a.application_id), 0),
        2
    )                                               AS shortlist_conversion_pct,

    -- "What % reached the offer stage?"
    ROUND(
        SUM(CASE WHEN a.status IN ('Offer Extended', 'Hired')
                 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(COUNT(a.application_id), 0),
        2
    )                                               AS offer_conversion_pct,

    -- ── Skill demand summary for this job ──────────────────────────────────
    -- How many skills are required, and how many are mandatory?
    -- Subquery approach: correlated subqueries are acceptable here because
    -- this is a reporting view, not a real-time OLTP query.
    (SELECT COUNT(*)
     FROM   JobSkills js
     WHERE  js.job_id = j.job_id)                  AS total_skills_required,

    (SELECT COUNT(*)
     FROM   JobSkills js
     WHERE  js.job_id      = j.job_id
       AND  js.is_mandatory = 1)                    AS mandatory_skills_count

FROM       Jobs             j
LEFT JOIN  Applications     a    ON  a.job_id  = j.job_id
JOIN       Users            u    ON  u.user_id = j.posted_by
JOIN       EducationLevels  edu  ON  edu.education_level_id
                                                   = j.min_education_level_id
GROUP BY
    j.job_id,
    j.title,
    j.department,
    j.location,
    j.job_type,
    j.is_active,
    j.posted_at,
    j.deadline,
    u.full_name,
    edu.level_name,
    j.min_experience_years

-- HAVING: Only show jobs that have received at least one application.
-- Remove this clause in the admin UI if you want to show all jobs
-- including ones with zero applications.
HAVING     COUNT(a.application_id) > 0

ORDER BY   j.posted_at DESC;


-- =============================================================================
-- VIEW 3: vw_CandidateApplicationHistory
-- Consumer   : Candidate self-service portal
-- Purpose    : A candidate's complete application history across all jobs.
--
-- Security Design (Role-Based Column Suppression):
--   computed_score   → OMITTED entirely. Scores are internal to recruiters.
--   recruiter_notes  → OMITTED. Internal comments not for candidate eyes.
--   other candidates → Naturally isolated; the WHERE clause in the Flask
--                      query will filter by user_id from the JWT session.
--                      The view provides the shape; the backend adds the filter.
--
-- Note on Row-Level Security:
--   True row-level security (RLS) is a PostgreSQL feature. In MySQL we
--   simulate it through the application layer: the Flask route will always
--   append WHERE candidate_user_id = <session_user_id> when querying this
--   view. The view itself does not hard-code a user filter because it must
--   serve ALL candidates (admin needs it too); the session filter happens
--   at query time. This is the standard MySQL pattern for RLS simulation.
-- =============================================================================

CREATE OR REPLACE VIEW vw_CandidateApplicationHistory AS
SELECT
    -- ── Candidate identity (used for server-side row filtering) ────────────
    u.user_id                           AS candidate_user_id,
    u.full_name                         AS candidate_name,
    u.email                             AS candidate_email,

    -- ── Application details (safe for candidate consumption) ──────────────
    a.application_id,
    a.status                            AS application_status,
    a.applied_at,
    a.last_status_change,

    -- ── Friendly status message (computed column, no PROCEDURE needed) ─────
    -- Gives the candidate a human-readable description of their current stage.
    CASE a.status
        WHEN 'Submitted'            THEN 'Your application has been received.'
        WHEN 'Under Review'         THEN 'A recruiter is reviewing your application.'
        WHEN 'Shortlisted'          THEN 'Congratulations! You have been shortlisted.'
        WHEN 'Interview Scheduled'  THEN 'An interview has been arranged. Check your email.'
        WHEN 'Offer Extended'       THEN 'An offer has been extended to you!'
        WHEN 'Hired'                THEN 'You have been hired for this position.'
        WHEN 'Rejected'             THEN 'Unfortunately, your application was not successful.'
        WHEN 'Withdrawn'            THEN 'You withdrew this application.'
        ELSE                             'Status unknown. Please contact support.'
    END                                 AS status_description,

    -- ── Days since application (useful for "follow-up after X days" logic) ─
    DATEDIFF(CURRENT_DATE, DATE(a.applied_at))
                                        AS days_since_applied,

    -- ── Days since last status change ─────────────────────────────────────
    DATEDIFF(CURRENT_DATE, DATE(a.last_status_change))
                                        AS days_since_last_update,

    -- ── Job details ────────────────────────────────────────────────────────
    j.job_id,
    j.title                             AS job_title,
    j.department,
    j.location,
    j.job_type,
    j.deadline                          AS job_deadline,

    -- ── Is the deadline still in the future? ──────────────────────────────
    CASE
        WHEN j.deadline IS NULL          THEN 'No deadline set'
        WHEN j.deadline >= CURRENT_DATE  THEN 'Open'
        ELSE                                  'Deadline passed'
    END                                 AS deadline_status,

    -- ── Recruiter name (who to contact) ───────────────────────────────────
    ru.full_name                        AS recruiter_name,
    ru.email                            AS recruiter_email

    -- NOTE: computed_score is deliberately ABSENT from this SELECT list.
    -- NOTE: recruiter_notes is deliberately ABSENT from this SELECT list.

FROM       Applications  a
JOIN       Candidates    c    ON c.candidate_id = a.candidate_id
JOIN       Users         u    ON u.user_id      = c.user_id
JOIN       Jobs          j    ON j.job_id       = a.job_id
JOIN       Users         ru   ON ru.user_id     = j.posted_by

ORDER BY   a.applied_at DESC;


-- =============================================================================
-- VIEW 4: vw_SkillGapAnalysis
-- Consumer   : Recruiter / Hiring Manager
-- Purpose    : For every active application, show WHICH mandatory skills
--              the candidate is MISSING — not just a count, but the actual
--              skill names. This is the most relational-algebra-intensive
--              view in the system.
--
-- Core Technique: NOT EXISTS (Anti-Join Pattern)
--   An anti-join finds rows in set A that have NO matching row in set B.
--   Here:
--     Set A = mandatory skills required by the job (JobSkills WHERE is_mandatory=1)
--     Set B = skills the candidate actually possesses (CandidateSkills)
--
--   The NOT EXISTS subquery asks:
--     "Does a row exist in CandidateSkills for this (candidate, skill) pair?"
--   If NOT → this skill is a gap.
--
--   Alternative approach (LEFT JOIN / IS NULL) is shown as a commented
--   block below so you can compare both patterns in your report.
--
-- Why NOT EXISTS instead of LEFT JOIN?
--   NOT EXISTS short-circuits on the first match found (more efficient for
--   large CandidateSkills tables). LEFT JOIN must complete the full join
--   before filtering. For this schema size both are equivalent, but
--   NOT EXISTS demonstrates stronger relational algebra understanding.
-- =============================================================================

CREATE OR REPLACE VIEW vw_SkillGapAnalysis AS
SELECT
    -- ── Job context ────────────────────────────────────────────────────────
    j.job_id,
    j.title                             AS job_title,
    j.department,

    -- ── Candidate context ──────────────────────────────────────────────────
    c.candidate_id,
    u.full_name                         AS candidate_name,
    u.email                             AS candidate_email,
    a.application_id,
    a.status                            AS application_status,
    ROUND(a.computed_score, 2)          AS computed_score,

    -- ── The missing skill ─────────────────────────────────────────────────
    s.skill_id                          AS missing_skill_id,
    s.skill_name                        AS missing_skill_name,
    s.category                          AS missing_skill_category,

    -- ── Gap severity label ────────────────────────────────────────────────
    -- Every row here is already a mandatory gap (is_mandatory = 1 in the
    -- WHERE clause). This column is for future extension (e.g., optional gaps).
    'Mandatory'                         AS gap_type,

    -- ── Window: total mandatory gaps for this candidate+job pair ──────────
    -- Lets the recruiter sort by "who has the most gaps" without a sub-query.
    COUNT(s.skill_id)
        OVER (
            PARTITION BY a.application_id
        )                               AS total_mandatory_gaps,

    -- ── Window: total mandatory skills required for this job ──────────────
    -- With this, the UI can display "Missing 2 of 5 required skills."
    (
        SELECT COUNT(*)
        FROM   JobSkills js2
        WHERE  js2.job_id      = j.job_id
          AND  js2.is_mandatory = 1
    )                                   AS total_mandatory_required,

    -- ── Derived: gap percentage ───────────────────────────────────────────
    ROUND(
        COUNT(s.skill_id)
            OVER (PARTITION BY a.application_id)
        * 100.0
        / NULLIF(
            (SELECT COUNT(*)
             FROM   JobSkills js3
             WHERE  js3.job_id      = j.job_id
               AND  js3.is_mandatory = 1),
            0
        ),
        2
    )                                   AS mandatory_gap_pct

FROM       Applications  a
JOIN       Jobs          j    ON j.job_id       = a.job_id
JOIN       Candidates    c    ON c.candidate_id = a.candidate_id
JOIN       Users         u    ON u.user_id      = c.user_id
-- ── Core: iterate over every mandatory skill the job requires ─────────────
JOIN       JobSkills     js   ON js.job_id       = j.job_id
                              AND js.is_mandatory = 1
JOIN       Skills        s    ON s.skill_id      = js.skill_id

-- ── Anti-join: keep only skills the candidate does NOT have ───────────────
-- For each mandatory job skill (js), check whether a matching row exists
-- in CandidateSkills for this specific candidate.
-- NOT EXISTS = "this candidate has no row for this skill" = it is a gap.
WHERE NOT EXISTS (
    SELECT 1
    FROM   CandidateSkills cs
    WHERE  cs.candidate_id = c.candidate_id    -- same candidate
      AND  cs.skill_id     = js.skill_id       -- same skill
)
-- Only show active applications (gaps for withdrawn/rejected are noise)
AND a.status NOT IN ('Withdrawn', 'Rejected', 'Hired')

ORDER BY
    j.job_id,
    a.computed_score DESC,         -- worst-scoring (most gaps) shown last
    c.candidate_id,
    s.skill_name;

-- =============================================================================
-- LEFT JOIN / IS NULL equivalent (for your report comparison):
-- This produces an identical result to the NOT EXISTS above.
-- Uncomment to test.
-- =============================================================================
/*
SELECT ...
FROM       Applications  a
JOIN       Jobs          j    ON j.job_id       = a.job_id
JOIN       Candidates    c    ON c.candidate_id = a.candidate_id
JOIN       JobSkills     js   ON js.job_id       = j.job_id
                              AND js.is_mandatory = 1
JOIN       Skills        s    ON s.skill_id      = js.skill_id
LEFT JOIN  CandidateSkills cs ON cs.candidate_id = c.candidate_id
                              AND cs.skill_id    = js.skill_id
WHERE  cs.candidate_id IS NULL            -- IS NULL = no match found = gap
  AND  a.status NOT IN ('Withdrawn', 'Rejected', 'Hired');
*/


-- =============================================================================
-- SECTION E: VERIFICATION QUERIES
-- =============================================================================

-- ── E1. Confirm all 4 views were created ─────────────────────────────────
SELECT
    TABLE_NAME          AS view_name,
    VIEW_DEFINITION     AS definition_preview
FROM   information_schema.VIEWS
WHERE  TABLE_SCHEMA = 'recruitment_db'
ORDER  BY TABLE_NAME;

-- ── E2. Query the recruiter ranking view for a specific job ───────────────
-- Flask equivalent: SELECT * FROM vw_RankedCandidates WHERE job_id = ?
SELECT
    job_title,
    candidate_name,
    application_status,
    computed_score,
    score_rank,
    score_dense_rank,
    percentile_rank,
    job_avg_score,
    total_applicants_for_job
FROM   vw_RankedCandidates
WHERE  job_id = 1
ORDER  BY score_rank;

-- ── E3. Query the admin funnel summary ────────────────────────────────────
SELECT
    job_title,
    department,
    total_applications,
    cnt_submitted,
    cnt_under_review,
    cnt_shortlisted,
    cnt_hired,
    cnt_rejected,
    avg_computed_score,
    shortlist_conversion_pct
FROM   vw_JobFunnelSummary;

-- ── E4. Query candidate history (backend will append WHERE clause) ────────
-- Flask equivalent: SELECT * FROM vw_CandidateApplicationHistory
--                   WHERE candidate_user_id = <session_user_id>
SELECT
    candidate_name,
    job_title,
    department,
    application_status,
    status_description,
    days_since_applied,
    deadline_status
FROM   vw_CandidateApplicationHistory
WHERE  candidate_user_id = 2;   -- replace with session user_id

-- ── E5. Query the skill gap analysis for a specific job ───────────────────
SELECT
    candidate_name,
    computed_score,
    missing_skill_name,
    missing_skill_category,
    total_mandatory_gaps,
    total_mandatory_required,
    mandatory_gap_pct
FROM   vw_SkillGapAnalysis
WHERE  job_id = 1
ORDER  BY total_mandatory_gaps DESC, candidate_name;
