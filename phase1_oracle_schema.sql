-- =============================================================================
-- SMART RECRUITMENT MANAGEMENT SYSTEM — ORACLE MIGRATION
-- Phase 1: Schema Design (DDL) — Oracle 12c+
-- =============================================================================
-- KEY TRANSLATION DECISIONS:
--
--   AUTO_INCREMENT   → GENERATED ALWAYS AS IDENTITY (Oracle 12c+)
--                      Oracle sequences are created implicitly.
--
--   ENUM(...)        → VARCHAR2(n) + CHECK (...IN (...))
--                      Oracle has no native ENUM type. The CHECK constraint
--                      provides identical enforcement at the engine level.
--
--   TINYINT(1)       → NUMBER(1,0)
--                      Oracle SQL has no BOOLEAN type (PL/SQL does, but DDL
--                      columns must use NUMBER(1,0) with CHECK(col IN (0,1))).
--
--   DATETIME         → TIMESTAMP
--                      TIMESTAMP preserves fractional seconds and allows
--                      TIMESTAMP WITH TIME ZONE for multi-region deployments.
--
--   TEXT             → CLOB
--                      Oracle's Character Large OBject — unbounded text.
--                      For columns under 4000 chars, VARCHAR2(4000) is faster.
--
--   DEFAULT CURRENT_TIMESTAMP → DEFAULT SYSTIMESTAMP
--                      SYSTIMESTAMP returns TIMESTAMP WITH TIME ZONE;
--                      use SYSDATE if you only need DATE precision.
--
--   INDEX (standalone) → CREATE INDEX ... (identical syntax, run after table)
--
--   SCHEMA ISOLATION:  In Oracle, a "schema" == a "user". All objects below
--                      belong to whichever user you connect as.
--                      Run: CREATE USER recruitment IDENTIFIED BY <pwd>;
--                           GRANT DBA TO recruitment;
--                      Then connect as that user before running this script.
--
--   STATEMENT TERMINATOR: Each DDL statement ends with a semicolon.
--                      Each PL/SQL block ends with a forward slash (/) on
--                      its own line. SQL*Plus / SQLcl execute on seeing /.
-- =============================================================================


-- =============================================================================
-- HOUSEKEEPING — Drop objects if they exist (safe re-run)
-- Oracle has no DROP TABLE IF EXISTS before 23c, so we use the
-- BEGIN/EXCEPTION/END pattern to swallow the "table not found" error.
-- =============================================================================
BEGIN
    FOR t IN (
        SELECT table_name FROM user_tables
        WHERE  table_name IN (
            'APPLICATION_STATUS_AUDIT',
            'APPLICATIONS',
            'JOB_SKILLS',
            'JOBS',
            'CANDIDATE_SKILLS',
            'SKILLS',
            'CANDIDATES',
            'USERS',
            'EDUCATION_LEVELS'
        )
    ) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
    END LOOP;
END;
/


-- =============================================================================
-- TABLE 1: EDUCATION_LEVELS
-- Translation notes:
--   TINYINT UNSIGNED → NUMBER(3,0)  (Oracle has no unsigned modifier)
--   score_weight CHECK range stays identical
-- =============================================================================
CREATE TABLE education_levels (
    education_level_id  NUMBER(3,0)     GENERATED ALWAYS AS IDENTITY
                                        CONSTRAINT pk_education_levels PRIMARY KEY,
    level_name          VARCHAR2(60)    NOT NULL,
    score_weight        NUMBER(2,0)     NOT NULL,
    --
    CONSTRAINT uq_edu_level_name    UNIQUE      (level_name),
    CONSTRAINT chk_edu_score_weight CHECK       (score_weight BETWEEN 1 AND 10)
);

-- Oracle INSERT with GENERATED ALWAYS AS IDENTITY columns must
-- omit the identity column from the column list entirely.
INSERT INTO education_levels (level_name, score_weight) VALUES ('High School Diploma',   1);
INSERT INTO education_levels (level_name, score_weight) VALUES ('Associate Degree',      2);
INSERT INTO education_levels (level_name, score_weight) VALUES ('Bachelor''s Degree',    4);
INSERT INTO education_levels (level_name, score_weight) VALUES ('Bachelor''s (Honours)', 5);
INSERT INTO education_levels (level_name, score_weight) VALUES ('Postgraduate Diploma',  6);
INSERT INTO education_levels (level_name, score_weight) VALUES ('Master''s Degree',      8);
INSERT INTO education_levels (level_name, score_weight) VALUES ('MD / Professional',     8);
INSERT INTO education_levels (level_name, score_weight) VALUES ('PhD / Doctorate',      10);
COMMIT;


-- =============================================================================
-- TABLE 2: USERS
-- Translation notes:
--   VARCHAR(254)  → VARCHAR2(254)   (Oracle's variable-length string type)
--   ENUM(role)    → VARCHAR2(10) + CHECK (role IN (...))
--   TINYINT(1)    → NUMBER(1,0)  + CHECK (is_active IN (0,1))
--   ON UPDATE CURRENT_TIMESTAMP is NOT supported in Oracle DDL.
--     → Handled by the trg_users_updated_at trigger defined below.
-- =============================================================================
CREATE TABLE users (
    user_id         NUMBER          GENERATED ALWAYS AS IDENTITY
                                    CONSTRAINT pk_users PRIMARY KEY,
    email           VARCHAR2(254)   NOT NULL,
    password_hash   VARCHAR2(255)   NOT NULL,
    full_name       VARCHAR2(120)   NOT NULL,
    -- ENUM replacement: VARCHAR2 + CHECK constraint
    role            VARCHAR2(10)    DEFAULT 'candidate' NOT NULL,
    is_active       NUMBER(1,0)     DEFAULT 1 NOT NULL,
    created_at      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    --
    CONSTRAINT uq_users_email   UNIQUE  (email),
    CONSTRAINT chk_users_role   CHECK   (role IN ('candidate', 'recruiter', 'admin')),
    CONSTRAINT chk_users_email  CHECK   (email LIKE '%_@_%._%'),
    CONSTRAINT chk_users_active CHECK   (is_active IN (0, 1))
);

-- Oracle has no ON UPDATE CURRENT_TIMESTAMP column property.
-- A BEFORE UPDATE trigger replicates this behaviour.
CREATE OR REPLACE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE INDEX idx_users_role       ON users (role);
CREATE INDEX idx_users_is_active  ON users (is_active);


-- =============================================================================
-- TABLE 3: CANDIDATES
-- Translation notes:
--   DECIMAL(4,1)  → NUMBER(4,1)    (Oracle NUMBER is the universal numeric)
--   VARCHAR(500)  → VARCHAR2(500)
--   updated_at auto-stamp → trigger (same pattern as users)
-- =============================================================================
CREATE TABLE candidates (
    candidate_id        NUMBER          GENERATED ALWAYS AS IDENTITY
                                        CONSTRAINT pk_candidates PRIMARY KEY,
    user_id             NUMBER          NOT NULL,
    education_level_id  NUMBER(3,0)     NOT NULL,
    years_of_experience NUMBER(4,1)     DEFAULT 0 NOT NULL,
    resume_url          VARCHAR2(500),
    linkedin_url        VARCHAR2(500),
    summary             CLOB,                       -- TEXT → CLOB
    created_at          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    --
    CONSTRAINT uq_candidates_user       UNIQUE (user_id),
    CONSTRAINT fk_candidates_user       FOREIGN KEY (user_id)
        REFERENCES users (user_id) ON DELETE CASCADE,
    CONSTRAINT fk_candidates_edu        FOREIGN KEY (education_level_id)
        REFERENCES education_levels (education_level_id),
    CONSTRAINT chk_candidates_exp       CHECK (years_of_experience >= 0)
);

CREATE OR REPLACE TRIGGER trg_candidates_updated_at
BEFORE UPDATE ON candidates
FOR EACH ROW
BEGIN
    :NEW.updated_at := SYSTIMESTAMP;
END;
/

CREATE INDEX idx_candidates_user_id   ON candidates (user_id);
CREATE INDEX idx_candidates_edu_level ON candidates (education_level_id);
CREATE INDEX idx_candidates_exp       ON candidates (years_of_experience);


-- =============================================================================
-- TABLE 4: SKILLS
-- Translation notes:
--   SMALLINT UNSIGNED → NUMBER(5,0)
-- =============================================================================
CREATE TABLE skills (
    skill_id    NUMBER(5,0)     GENERATED ALWAYS AS IDENTITY
                                CONSTRAINT pk_skills PRIMARY KEY,
    skill_name  VARCHAR2(100)   NOT NULL,
    category    VARCHAR2(60)    DEFAULT 'General' NOT NULL,
    --
    CONSTRAINT uq_skill_name UNIQUE (skill_name)
);

CREATE INDEX idx_skills_category ON skills (category);


-- =============================================================================
-- TABLE 5: CANDIDATE_SKILLS
-- Translation notes:
--   ENUM(proficiency_level) → VARCHAR2 + CHECK
--   Composite PK syntax is identical
-- =============================================================================
CREATE TABLE candidate_skills (
    candidate_id        NUMBER          NOT NULL,
    skill_id            NUMBER(5,0)     NOT NULL,
    -- ENUM replacement
    proficiency_level   VARCHAR2(12)    DEFAULT 'Intermediate' NOT NULL,
    years_with_skill    NUMBER(3,1)     DEFAULT 0 NOT NULL,
    --
    CONSTRAINT pk_candidate_skills  PRIMARY KEY (candidate_id, skill_id),
    CONSTRAINT fk_cs_candidate      FOREIGN KEY (candidate_id)
        REFERENCES candidates (candidate_id) ON DELETE CASCADE,
    CONSTRAINT fk_cs_skill          FOREIGN KEY (skill_id)
        REFERENCES skills (skill_id) ON DELETE CASCADE,
    CONSTRAINT chk_cs_proficiency   CHECK (proficiency_level IN
        ('Beginner','Intermediate','Advanced','Expert')),
    CONSTRAINT chk_cs_years         CHECK (years_with_skill >= 0)
);

CREATE INDEX idx_cs_skill_id ON candidate_skills (skill_id);


-- =============================================================================
-- TABLE 6: JOBS
-- Translation notes:
--   ENUM(job_type)   → VARCHAR2(10) + CHECK
--   TINYINT(1)       → NUMBER(1,0)  + CHECK
--   DATE column stays DATE (Oracle DATE includes time component)
--   TEXT description → CLOB
-- =============================================================================
CREATE TABLE jobs (
    job_id                  NUMBER          GENERATED ALWAYS AS IDENTITY
                                            CONSTRAINT pk_jobs PRIMARY KEY,
    posted_by               NUMBER          NOT NULL,
    min_education_level_id  NUMBER(3,0)     NOT NULL,
    title                   VARCHAR2(150)   NOT NULL,
    department              VARCHAR2(100)   NOT NULL,
    location                VARCHAR2(150)   NOT NULL,
    -- ENUM replacement
    job_type                VARCHAR2(10)    DEFAULT 'Full-Time' NOT NULL,
    description             CLOB            NOT NULL,
    min_experience_years    NUMBER(4,1)     DEFAULT 0 NOT NULL,
    salary_min              NUMBER(12,2),
    salary_max              NUMBER(12,2),
    is_active               NUMBER(1,0)     DEFAULT 1 NOT NULL,
    -- TIMESTAMP for full precision; use DEFAULT SYSTIMESTAMP
    posted_at               TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    -- Oracle DATE type stores date+time; for date-only use TRUNC on retrieval
    deadline                DATE,
    --
    CONSTRAINT fk_jobs_posted_by    FOREIGN KEY (posted_by)
        REFERENCES users (user_id),
    CONSTRAINT fk_jobs_min_edu      FOREIGN KEY (min_education_level_id)
        REFERENCES education_levels (education_level_id),
    CONSTRAINT chk_jobs_job_type    CHECK (job_type IN
        ('Full-Time','Part-Time','Contract','Internship','Remote')),
    CONSTRAINT chk_jobs_experience  CHECK (min_experience_years >= 0),
    CONSTRAINT chk_jobs_is_active   CHECK (is_active IN (0,1)),
    CONSTRAINT chk_jobs_salary      CHECK (
        salary_min IS NULL OR salary_max IS NULL OR salary_max >= salary_min
    )
);

CREATE INDEX idx_jobs_posted_by   ON jobs (posted_by);
CREATE INDEX idx_jobs_is_active   ON jobs (is_active);
-- Oracle DESC index for ORDER BY posted_at DESC queries
CREATE INDEX idx_jobs_posted_at   ON jobs (posted_at DESC);
CREATE INDEX idx_jobs_min_edu     ON jobs (min_education_level_id);
-- Composite index for active-jobs-by-department query pattern
CREATE INDEX idx_jobs_active_dept ON jobs (is_active, department);


-- =============================================================================
-- TABLE 7: JOB_SKILLS
-- =============================================================================
CREATE TABLE job_skills (
    job_id          NUMBER          NOT NULL,
    skill_id        NUMBER(5,0)     NOT NULL,
    is_mandatory    NUMBER(1,0)     DEFAULT 1 NOT NULL,
    --
    CONSTRAINT pk_job_skills    PRIMARY KEY (job_id, skill_id),
    CONSTRAINT fk_js_job        FOREIGN KEY (job_id)
        REFERENCES jobs (job_id) ON DELETE CASCADE,
    CONSTRAINT fk_js_skill      FOREIGN KEY (skill_id)
        REFERENCES skills (skill_id) ON DELETE CASCADE,
    CONSTRAINT chk_js_mandatory CHECK (is_mandatory IN (0,1))
);

CREATE INDEX idx_js_skill_id ON job_skills (skill_id);


-- =============================================================================
-- TABLE 8: APPLICATIONS
-- Translation notes:
--   ENUM(status) → VARCHAR2(20) + CHECK
--   The UNIQUE constraint on (job_id, candidate_id) is identical
--   DEFAULT NULL on computed_score is Oracle default — no keyword needed
-- =============================================================================
CREATE TABLE applications (
    application_id      NUMBER          GENERATED ALWAYS AS IDENTITY
                                        CONSTRAINT pk_applications PRIMARY KEY,
    job_id              NUMBER          NOT NULL,
    candidate_id        NUMBER          NOT NULL,
    -- ENUM replacement — all valid status values enforced by CHECK
    status              VARCHAR2(20)    DEFAULT 'Submitted' NOT NULL,
    cover_letter        CLOB,
    computed_score      NUMBER(6,2),
    applied_at          TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    last_status_change  TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    recruiter_notes     CLOB,
    --
    CONSTRAINT uq_application_pair  UNIQUE (job_id, candidate_id),
    CONSTRAINT fk_app_job           FOREIGN KEY (job_id)
        REFERENCES jobs (job_id),
    CONSTRAINT fk_app_candidate     FOREIGN KEY (candidate_id)
        REFERENCES candidates (candidate_id),
    CONSTRAINT chk_app_status       CHECK (status IN (
        'Submitted', 'Under Review', 'Shortlisted',
        'Interview Scheduled', 'Offer Extended',
        'Hired', 'Rejected', 'Withdrawn'
    )),
    CONSTRAINT chk_app_score        CHECK (computed_score IS NULL OR computed_score >= 0)
);

CREATE INDEX idx_app_job_id       ON applications (job_id);
CREATE INDEX idx_app_candidate_id ON applications (candidate_id);
CREATE INDEX idx_app_status       ON applications (status);
CREATE INDEX idx_app_applied_at   ON applications (applied_at DESC);
-- Composite covering index for the ranked-candidates view
CREATE INDEX idx_app_job_score    ON applications (job_id, computed_score DESC);


-- =============================================================================
-- TABLE 9: APPLICATION_STATUS_AUDIT
-- =============================================================================
CREATE TABLE application_status_audit (
    audit_id        NUMBER          GENERATED ALWAYS AS IDENTITY
                                    CONSTRAINT pk_app_status_audit PRIMARY KEY,
    application_id  NUMBER          NOT NULL,
    old_status      VARCHAR2(20)    NOT NULL,
    new_status      VARCHAR2(20)    NOT NULL,
    -- Oracle equivalent of MySQL's CURRENT_USER() function
    changed_by      VARCHAR2(100)   DEFAULT SYS_CONTEXT('USERENV','SESSION_USER') NOT NULL,
    changed_at      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    --
    CONSTRAINT fk_audit_application FOREIGN KEY (application_id)
        REFERENCES applications (application_id) ON DELETE CASCADE
);

CREATE INDEX idx_audit_app_id  ON application_status_audit (application_id);
CREATE INDEX idx_audit_changed ON application_status_audit (changed_at DESC);


-- =============================================================================
-- VERIFICATION — Oracle Data Dictionary equivalents of information_schema
-- =============================================================================

-- List all tables just created
SELECT table_name, num_rows
FROM   user_tables
WHERE  table_name IN (
    'EDUCATION_LEVELS','USERS','CANDIDATES','SKILLS',
    'CANDIDATE_SKILLS','JOBS','JOB_SKILLS','APPLICATIONS',
    'APPLICATION_STATUS_AUDIT'
)
ORDER BY table_name;

-- List all foreign key constraints
SELECT a.constraint_name,
       a.table_name        AS child_table,
       a.column_name       AS child_column,
       c.r_constraint_name AS parent_constraint,
       c_pk.table_name     AS parent_table
FROM   user_cons_columns a
JOIN   user_constraints  c    ON  a.constraint_name = c.constraint_name
                              AND c.constraint_type  = 'R'
JOIN   user_constraints  c_pk ON  c.r_constraint_name = c_pk.constraint_name
ORDER BY a.table_name;

-- List all indexes
SELECT index_name, table_name, uniqueness, status
FROM   user_indexes
WHERE  table_name IN (
    'USERS','CANDIDATES','JOBS','APPLICATIONS',
    'CANDIDATE_SKILLS','JOB_SKILLS','APPLICATION_STATUS_AUDIT'
)
ORDER BY table_name, index_name;
