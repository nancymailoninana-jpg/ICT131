
-- =====================================================

-- 1. Create students table
CREATE TABLE IF NOT EXISTS students (
    student_id INT PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

-- 2. Create applications table
CREATE TABLE IF NOT EXISTS applications (
    application_id INT PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

-- 3. Create decision audit table
CREATE TABLE IF NOT EXISTS decision_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(20),
    new_status VARCHAR(20),
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 4. Insert students
INSERT INTO students VALUES
(1, 'ST001', 'John Banda'),
(2, 'ST002', 'Mary Phiri'),
(3, 'ST003', 'Peter Zulu')
ON CONFLICT (student_id) DO NOTHING;

-- 5. Insert six PENDING applications
INSERT INTO applications VALUES
(101, 1, 20, 2000, 75, '2026-11-01', 'PENDING'),
(102, 1, 17, 2000, 80, '2026-11-02', 'PENDING'),
(103, 2, 25, 3000, 70, '2026-11-03', 'PENDING'),
(104, 2, 22, 3500, 85, '2026-11-04', 'PENDING'),
(105, 3, 26, 2500, 90, '2026-11-05', 'PENDING'),
(106, 3, 21, 2800, 69, '2026-11-06', 'PENDING')
ON CONFLICT (application_id) DO NOTHING;


-- (b) FUNCTION: SCHOLARSHIP ELIGIBILITY
-- =====================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Input values cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive';
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative';
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100';
    END IF;

    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );
END;
$$;


-- (c) PROCEDURE: ASSESS APPLICATION
-- =====================================================

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_application RECORD;
    v_eligible BOOLEAN;
BEGIN

    SELECT *
    INTO v_application
    FROM applications
    WHERE application_id = p_application_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application ID % does not exist',
        p_application_id;
    END IF;

    IF v_application.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed',
        p_application_id;
    END IF;

    v_eligible := fn_scholarship_eligible(
        v_application.age_at_application,
        v_application.monthly_income,
        v_application.average_mark
    );

    IF v_eligible THEN
        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;
    ELSE
        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;
    END IF;

END;
$$;


-- (d) TRIGGER: RECORD STATUS CHANGES
-- =====================================================

-- Trigger function
CREATE OR REPLACE FUNCTION fn_audit_status_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO decision_audit (
            application_id,
            old_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.application_id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;

-- Create trigger
DROP TRIGGER IF EXISTS trg_status_audit ON applications;

CREATE TRIGGER trg_status_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_audit_status_changes();


-- (e) VIEW: APPROVED APPLICANTS
-- =====================================================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM students s
JOIN applications a
ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';


-- (f) INDEX AND EXPLAIN PLAN
-- =====================================================

-- Create composite index
CREATE INDEX IF NOT EXISTS idx_applications_status_date
ON applications(status, submitted_on);

-- Query applications by status and date range
SELECT *
FROM applications
WHERE status = 'PENDING'
AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';

-- Display execution plan
EXPLAIN
SELECT *
FROM applications
WHERE status = 'PENDING'
AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';


-- (g) SCHEDULED JOB
-- =====================================================

-- Procedure to assess all pending applications
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    app_record RECORD;
BEGIN

    FOR app_record IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP

        CALL pr_assess_application(
            app_record.application_id
        );

    END LOOP;

END;
$$;


-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule the procedure every Monday at 08:00
SELECT cron.schedule(
    'weekly_scholarship_assessment',
    '0 8 * * 1',
    'CALL pr_assess_pending();'
);


-- =====================================================
-- TESTING THE SYSTEM
-- =====================================================

-- Assess one application manually
CALL pr_assess_application(101);

-- Assess all remaining pending applications
CALL pr_assess_pending();

-- View all applications and their decisions
SELECT * FROM applications;

-- View approved applicants
SELECT * FROM v_approved_applicants;

-- View audit records
SELECT * FROM decision_audit;

-- Check scheduled jobs
SELECT * FROM cron.job;