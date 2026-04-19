-- =============================================================================
-- SMART RECRUITMENT MANAGEMENT SYSTEM
-- Phase 1: Advanced Schema Design (DDL)
-- Database: MySQL 8.0+
-- Standard: Third Normal Form (3NF)
-- =============================================================================

-- Drop and recreate the database for a clean slate
DROP DATABASE IF EXISTS recruitment_db;
CREATE DATABASE recruitment_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE recruitment_db;

-- =============================================================================
-- TABLE 1: EducationLevels
-- Purpose : Lookup + scoring-weight table for academic qualifications.
--           Storing the numeric weight HERE (not in app code) means the
--           scoring stored procedure in Phase 2 only needs a JOIN — no
--           hard-coded constants outside the database.
-- 3NF Note: No transitive dependencies; every non-key column depends solely
--           on education_level_id.
-- =============================================================================
CREATE TABLE EducationLevels (
    education_level_id  TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    level_name          VARCHAR(60)         NOT NULL,
    -- Numeric weight used directly by sp_CalculateCandidateScore (Phase 2).
    -- Higher ordinal == higher qualification.
    score_weight        TINYINT UNSIGNED    NOT NULL,
    CONSTRAINT pk_EducationLevels   PRIMARY KEY (education_level_id),
    CONSTRAINT uq_edu_level_name    UNIQUE      (level_name),
    CONSTRAINT chk_edu_score_weight CHECK       (score_weight BETWEEN 1 AND 10)
);

-- Seed data — weights are intentional and referenced by scoring logic
INSERT INTO EducationLevels (level_name, score_weight) VALUES
    ('High School Diploma',   1),
    ('Associate Degree',      2),
    ('Bachelor\'s Degree',    4),
    ('Bachelor\'s (Honours)', 5),
    ('Postgraduate Diploma',  6),
    ('Master\'s Degree',      8),
    ('MD / Professional',     8),
    ('PhD / Doctorate',      10);


-- =============================================================================
-- TABLE 2: Users
-- Purpose : Central authentication and role table.
--           All three roles (candidate, recruiter, admin) share one credential
--           store; role-specific data lives in separate tables (Candidates).
-- 3NF Note: role is a scalar attribute of the user, not a transitive
--           dependency, so it belongs here rather than a roles table for this
--           scale of project.
-- =============================================================================
CREATE TABLE Users (
    user_id         INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    email           VARCHAR(254)        NOT NULL,  -- RFC 5321 max length
    password_hash   VARCHAR(255)        NOT NULL,  -- bcrypt / Argon2 hash
    full_name       VARCHAR(120)        NOT NULL,
    role            ENUM(
                        'candidate',
                        'recruiter',
                        'admin'
                    )                   NOT NULL DEFAULT 'candidate',
    is_active       TINYINT(1)          NOT NULL DEFAULT 1,
    created_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                 ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_Users         PRIMARY KEY (user_id),
    CONSTRAINT uq_users_email   UNIQUE      (email),
    CONSTRAINT chk_users_email  CHECK       (email LIKE '%_@_%._%')
);

-- Index on role supports efficient dashboard queries filtered by role
CREATE INDEX idx_users_role       ON Users (role);
CREATE INDEX idx_users_is_active  ON Users (is_active);


-- =============================================================================
-- TABLE 3: Candidates
-- Purpose : Extends Users with candidate-specific profile data.
--           1:1 relationship with Users (one user_id per candidate row).
-- 3NF Note: education_level_id is a FK, not a repeated string — satisfies
--           3NF by eliminating the transitive dependency
--           candidate → degree_name → score_weight.
-- =============================================================================
CREATE TABLE Candidates (
    candidate_id        INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    user_id             INT UNSIGNED        NOT NULL,
    education_level_id  TINYINT UNSIGNED    NOT NULL,
    -- Stored as DECIMAL to allow "3.5 years" and support exact comparisons
    years_of_experience DECIMAL(4,1)        NOT NULL DEFAULT 0.0,
    resume_url          VARCHAR(500)        NULL,     -- path / S3 key
    linkedin_url        VARCHAR(500)        NULL,
    summary             TEXT                NULL,
    created_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP
                                                     ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_Candidates                PRIMARY KEY (candidate_id),
    CONSTRAINT uq_candidates_user           UNIQUE      (user_id),
    CONSTRAINT fk_candidates_user           FOREIGN KEY (user_id)
        REFERENCES Users (user_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT fk_candidates_edu_level      FOREIGN KEY (education_level_id)
        REFERENCES EducationLevels (education_level_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,
    CONSTRAINT chk_candidates_experience    CHECK (years_of_experience >= 0)
);

CREATE INDEX idx_candidates_user_id         ON Candidates (user_id);
CREATE INDEX idx_candidates_edu_level       ON Candidates (education_level_id);
CREATE INDEX idx_candidates_experience      ON Candidates (years_of_experience);


-- =============================================================================
-- TABLE 4: Skills
-- Purpose : Master dictionary of skills (canonical names).
--           Normalising skills into their own table prevents the redundancy
--           and update anomalies that would occur if skill names were stored
--           as strings inside CandidateSkills / JobSkills.
-- 3NF Note: category is a direct attribute of a skill, not a dependency
--           through another non-key column.
-- =============================================================================
CREATE TABLE Skills (
    skill_id    SMALLINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    skill_name  VARCHAR(100)        NOT NULL,
    category    VARCHAR(60)         NOT NULL DEFAULT 'General',
    CONSTRAINT pk_Skills        PRIMARY KEY (skill_id),
    CONSTRAINT uq_skill_name    UNIQUE      (skill_name)
);

CREATE INDEX idx_skills_category ON Skills (category);


-- =============================================================================
-- TABLE 5: CandidateSkills
-- Purpose : Many-to-many junction between Candidates and Skills.
--           proficiency_level captures self-reported expertise; this is a
--           direct fact about the (candidate, skill) pair — no 3NF violation.
-- =============================================================================
CREATE TABLE CandidateSkills (
    candidate_id        INT UNSIGNED    NOT NULL,
    skill_id            SMALLINT UNSIGNED NOT NULL,
    proficiency_level   ENUM(
                            'Beginner',
                            'Intermediate',
                            'Advanced',
                            'Expert'
                        )               NOT NULL DEFAULT 'Intermediate',
    years_with_skill    DECIMAL(3,1)    NOT NULL DEFAULT 0.0,
    CONSTRAINT pk_CandidateSkills   PRIMARY KEY (candidate_id, skill_id),
    CONSTRAINT fk_cs_candidate      FOREIGN KEY (candidate_id)
        REFERENCES Candidates (candidate_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT fk_cs_skill          FOREIGN KEY (skill_id)
        REFERENCES Skills (skill_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT chk_cs_years         CHECK (years_with_skill >= 0)
);

CREATE INDEX idx_cs_skill_id ON CandidateSkills (skill_id);


-- =============================================================================
-- TABLE 6: Jobs
-- Purpose : Job postings created by recruiters.
--           min_education_level_id enforces a minimum qualification FK so
--           the scoring procedure can do a direct numeric comparison via the
--           EducationLevels.score_weight column.
-- 3NF Note: posted_by references Users; department is an atomic attribute of
--           this posting (not normalised further because departments are
--           free-text at this project scale).
-- =============================================================================
CREATE TABLE Jobs (
    job_id                  INT UNSIGNED        NOT NULL AUTO_INCREMENT,
    posted_by               INT UNSIGNED        NOT NULL,  -- FK → Users (recruiter)
    min_education_level_id  TINYINT UNSIGNED    NOT NULL,
    title                   VARCHAR(150)        NOT NULL,
    department              VARCHAR(100)        NOT NULL,
    location                VARCHAR(150)        NOT NULL,
    job_type                ENUM(
                                'Full-Time',
                                'Part-Time',
                                'Contract',
                                'Internship',
                                'Remote'
                            )                   NOT NULL DEFAULT 'Full-Time',
    description             TEXT                NOT NULL,
    min_experience_years    DECIMAL(4,1)        NOT NULL DEFAULT 0.0,
    salary_min              DECIMAL(12,2)       NULL,
    salary_max              DECIMAL(12,2)       NULL,
    is_active               TINYINT(1)          NOT NULL DEFAULT 1,
    posted_at               DATETIME            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deadline                DATE                NULL,
    CONSTRAINT pk_Jobs                  PRIMARY KEY (job_id),
    CONSTRAINT fk_jobs_posted_by        FOREIGN KEY (posted_by)
        REFERENCES Users (user_id)
        ON DELETE RESTRICT              -- Prevent orphaned postings
        ON UPDATE CASCADE,
    CONSTRAINT fk_jobs_min_edu         FOREIGN KEY (min_education_level_id)
        REFERENCES EducationLevels (education_level_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,
    CONSTRAINT chk_jobs_experience      CHECK (min_experience_years >= 0),
    CONSTRAINT chk_jobs_salary_range    CHECK (
        salary_min IS NULL OR
        salary_max IS NULL OR
        salary_max >= salary_min
    )
);

CREATE INDEX idx_jobs_posted_by     ON Jobs (posted_by);
CREATE INDEX idx_jobs_is_active     ON Jobs (is_active);
CREATE INDEX idx_jobs_posted_at     ON Jobs (posted_at DESC);
CREATE INDEX idx_jobs_min_edu       ON Jobs (min_education_level_id);
-- Composite index for the common "active jobs by department" query
CREATE INDEX idx_jobs_active_dept   ON Jobs (is_active, department);


-- =============================================================================
-- TABLE 7: JobSkills
-- Purpose : Many-to-many junction between Jobs and required Skills.
--           is_mandatory distinguishes "must-have" vs "nice-to-have" skills.
--           The scoring procedure uses this flag to apply differential weights.
-- =============================================================================
CREATE TABLE JobSkills (
    job_id          INT UNSIGNED        NOT NULL,
    skill_id        SMALLINT UNSIGNED   NOT NULL,
    is_mandatory    TINYINT(1)          NOT NULL DEFAULT 1,
    CONSTRAINT pk_JobSkills     PRIMARY KEY (job_id, skill_id),
    CONSTRAINT fk_js_job        FOREIGN KEY (job_id)
        REFERENCES Jobs (job_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT fk_js_skill      FOREIGN KEY (skill_id)
        REFERENCES Skills (skill_id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
);

CREATE INDEX idx_js_skill_id ON JobSkills (skill_id);


-- =============================================================================
-- TABLE 8: Applications
-- Purpose : Core transactional table recording each candidate's submission
--           for a job posting.
--
-- Status Machine (enforced by CHECK + sp_UpdateApplicationStatus in Phase 2):
--
--   Submitted ──► Under Review ──► Shortlisted ──► Interview Scheduled
--                      │                │
--                      └───────┬────────┘
--                              ▼
--                           Rejected
--                              │     ┌── Offer Extended
--              Shortlisted ────┴────►│
--                                    └── Hired
--
-- computed_score : Populated by sp_CalculateCandidateScore (Phase 2).
--                 Stored here (not computed on-the-fly) so the ranked view
--                 in Phase 3 is fast and score history is preserved.
-- =============================================================================
CREATE TABLE Applications (
    application_id  INT UNSIGNED    NOT NULL AUTO_INCREMENT,
    job_id          INT UNSIGNED    NOT NULL,
    candidate_id    INT UNSIGNED    NOT NULL,
    status          ENUM(
                        'Submitted',
                        'Under Review',
                        'Shortlisted',
                        'Interview Scheduled',
                        'Offer Extended',
                        'Hired',
                        'Rejected',
                        'Withdrawn'
                    )               NOT NULL DEFAULT 'Submitted',
    cover_letter    TEXT            NULL,
    computed_score  DECIMAL(6,2)    NULL DEFAULT NULL, -- set by stored procedure
    applied_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- last_status_change is updated by a TRIGGER (defined in Phase 2)
    last_status_change DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    recruiter_notes TEXT            NULL,
    CONSTRAINT pk_Applications          PRIMARY KEY (application_id),
    -- A candidate may apply to the same job exactly once
    CONSTRAINT uq_application_pair      UNIQUE (job_id, candidate_id),
    CONSTRAINT fk_app_job               FOREIGN KEY (job_id)
        REFERENCES Jobs (job_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,
    CONSTRAINT fk_app_candidate         FOREIGN KEY (candidate_id)
        REFERENCES Candidates (candidate_id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE,
    CONSTRAINT chk_app_score            CHECK (
        computed_score IS NULL OR computed_score >= 0
    )
);

CREATE INDEX idx_app_job_id             ON Applications (job_id);
CREATE INDEX idx_app_candidate_id       ON Applications (candidate_id);
CREATE INDEX idx_app_status             ON Applications (status);
CREATE INDEX idx_app_applied_at         ON Applications (applied_at DESC);
-- Composite covering index: the ranked-candidates view filters by job then
-- sorts by score — this index satisfies both operations without a filesort
CREATE INDEX idx_app_job_score          ON Applications (job_id, computed_score DESC);


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these after executing the DDL to confirm all objects were created.
-- =============================================================================

-- List all tables in the schema
SELECT
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS,
    CREATE_TIME
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'recruitment_db'
ORDER BY CREATE_TIME;

-- Verify all foreign key relationships
SELECT
    CONSTRAINT_NAME,
    TABLE_NAME          AS child_table,
    COLUMN_NAME         AS child_column,
    REFERENCED_TABLE_NAME  AS parent_table,
    REFERENCED_COLUMN_NAME AS parent_column
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'recruitment_db'
  AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY TABLE_NAME;

-- Verify all indexes
SELECT
    TABLE_NAME,
    INDEX_NAME,
    NON_UNIQUE,
    COLUMN_NAME,
    SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'recruitment_db'
ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;
