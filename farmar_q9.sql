-- =====================================================================
-- Farmer cooperative maize deliveries (MySQL 8.0+)
-- Rates: grade A = K5/kg, B = K4/kg, C = K3/kg
-- Run with:  mysql -u root -p < maize_coop_db.sql
-- =====================================================================
DROP DATABASE IF EXISTS maize_coop_db;
CREATE DATABASE maize_coop_db;
USE maize_coop_db;

-- =====================================================================
-- (a) TABLES
-- unit_rate and total_value default to 0 only so the procedure can omit
-- them; the trigger always overwrites them, and the CHECKs would reject a
-- 0 if it ever survived.
-- =====================================================================
CREATE TABLE farmers (
    farmer_id     INT AUTO_INCREMENT PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE deliveries (
    delivery_id  INT AUTO_INCREMENT PRIMARY KEY,
    farmer_id    INT           NOT NULL,
    grade        CHAR(1)       NOT NULL,
    weight_kg    DECIMAL(10,2) NOT NULL,
    unit_rate    DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    total_value  DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT fk_deliv_farmer FOREIGN KEY (farmer_id) REFERENCES farmers (farmer_id),
    CONSTRAINT chk_deliv_grade  CHECK (grade IN ('A','B','C')),
    CONSTRAINT chk_deliv_weight CHECK (weight_kg > 0),
    CONSTRAINT chk_deliv_rate   CHECK (unit_rate > 0),
    CONSTRAINT chk_deliv_total  CHECK (total_value > 0)
) ENGINE=InnoDB;

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  DECIMAL(14,2) NOT NULL DEFAULT 0.00,
    total_value   DECIMAL(14,2) NOT NULL DEFAULT 0.00
) ENGINE=InnoDB;

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Moses Banda'),
    ('F002', 'Grace Phiri'),
    ('F003', 'Peter Mwale');

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    IF p_grade IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Grade is required';
    END IF;

    CASE UPPER(p_grade)
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unsupported grade (use A, B or C)';
    END CASE;
END$$

-- =====================================================================
-- (d) TRIGGERS - the single place where price is decided
-- MySQL has no "BEFORE INSERT OR UPDATE" trigger, so the same rule is
-- written as two triggers, one per event. Whatever unit_rate / total_value
-- the caller supplied is overwritten.
-- =====================================================================
CREATE TRIGGER trg_deliveries_before_insert
BEFORE INSERT ON deliveries
FOR EACH ROW
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be greater than zero';
    END IF;

    SET NEW.unit_rate   = fn_maize_rate(NEW.grade);     -- rejects NULL / bad grade
    SET NEW.grade       = UPPER(NEW.grade);
    SET NEW.total_value = ROUND(NEW.weight_kg * NEW.unit_rate, 2);
END$$

CREATE TRIGGER trg_deliveries_before_update
BEFORE UPDATE ON deliveries
FOR EACH ROW
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be greater than zero';
    END IF;

    SET NEW.unit_rate   = fn_maize_rate(NEW.grade);
    SET NEW.grade       = UPPER(NEW.grade);
    SET NEW.total_value = ROUND(NEW.weight_kg * NEW.unit_rate, 2);
END$$

-- =====================================================================
-- (c) PROCEDURE - supplies only the basic fields; the trigger prices it
-- =====================================================================
CREATE PROCEDURE pr_receive_delivery(
    IN p_farmer_id INT,
    IN p_grade     CHAR(1),
    IN p_weight    DECIMAL(10,2),
    IN p_date      DATE
)
BEGIN
    DECLARE v_rate DECIMAL(10,2);

    IF p_farmer_id IS NULL OR p_grade IS NULL
       OR p_weight IS NULL OR p_date IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'All parameters are required';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown farmer';
    END IF;

    IF p_weight <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Weight must be greater than zero';
    END IF;

    IF p_date > CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivery date cannot be in the future';
    END IF;

    SET v_rate = fn_maize_rate(p_grade);   -- early, clear error for a bad grade

    -- unit_rate and total_value are deliberately omitted: the trigger sets them
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE (idempotent)
-- =====================================================================
CREATE PROCEDURE pr_refresh_purchases(IN p_day DATE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Day is required';
    END IF;

    START TRANSACTION;

    DELETE FROM daily_purchases WHERE purchase_date = p_day;   -- replace, never add

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
      FROM deliveries
     WHERE delivered_on = p_day;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW - unpaid condition is in the JOIN, so farmers with nothing
-- unpaid still appear, with 0
-- =====================================================================
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
  FROM farmers f
  LEFT JOIN deliveries d
         ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
 GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- =====================================================================
-- (f) INDEX
-- Query: WHERE farmer_id = ? AND delivered_on BETWEEN ? AND ?
-- Equality column first, range column second: the index jumps to one
-- farmer and reads only the requested date slice, already in date order.
-- It also replaces the single-column FK index on farmer_id.
-- =====================================================================
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- =====================================================================
-- (a) SEED DELIVERIES - loaded AFTER the triggers exist
-- =====================================================================
-- Four through the procedure (is_paid = FALSE, trigger prices them)
CALL pr_receive_delivery(1, 'A', 100.00, CURDATE() - INTERVAL 5 DAY);   -- id 1
CALL pr_receive_delivery(1, 'B', 250.50, CURDATE() - INTERVAL 4 DAY);   -- id 2
CALL pr_receive_delivery(2, 'C',  80.00, CURDATE() - INTERVAL 4 DAY);   -- id 3
CALL pr_receive_delivery(2, 'A',  40.00, CURDATE() - INTERVAL 3 DAY);   -- id 4

-- Two direct inserts with deliberately WRONG rate/total (and a lowercase
-- grade): the trigger must overwrite them with the correct values.
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'B', 120.00, 99.00, 1.00, CURDATE() - INTERVAL 3 DAY, TRUE);   -- id 5
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'a',  30.00, 0.01, 0.01, CURDATE() - INTERVAL 3 DAY, TRUE);   -- id 6

-- Mark two procedure-loaded deliveries as paid -> both states present
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3);

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
-- Rows 5 and 6 must show rates 4.00 and 5.00, totals 480.00 and 150.00
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value,
       delivered_on, is_paid
  FROM deliveries;

-- (b)  expected 5.00, 4.00, 3.00
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
-- SELECT fn_maize_rate(NULL);      -- error: Grade is required
-- SELECT fn_maize_rate('D');       -- error: Unsupported grade

-- (c) invalid deliveries (run one at a time; each errors, nothing inserted)
-- CALL pr_receive_delivery(99, 'A', 10, CURDATE());   -- unknown farmer
-- CALL pr_receive_delivery(1, 'D', 10, CURDATE());    -- bad grade
-- CALL pr_receive_delivery(1, 'A', 0,  CURDATE());    -- zero weight
-- CALL pr_receive_delivery(1, 'A', -5, CURDATE());    -- negative weight
-- CALL pr_receive_delivery(1, NULL, 10, CURDATE());   -- NULL grade
-- CALL pr_receive_delivery(1, 'A', 10, CURDATE() + INTERVAL 1 DAY);  -- future date

-- (d) direct SQL follows the same pricing rule:
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--   VALUES (1, 'A', -3, CURDATE());                   -- error: weight
-- UPDATE deliveries SET weight_kg = 110 WHERE delivery_id = 1;   -- total becomes 550.00
-- UPDATE deliveries SET total_value = 1 WHERE delivery_id = 2;   -- silently corrected back
-- UPDATE deliveries SET grade = 'C' WHERE delivery_id = 2;       -- rate 3.00, total recalculated

-- (e)  expected: F001 1002.00, F002 200.00, F003 0.00
SELECT * FROM v_farmer_amount_due;

-- (f)
ANALYZE TABLE deliveries;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
  FROM deliveries
 WHERE farmer_id = 1
   AND delivered_on BETWEEN CURDATE() - INTERVAL 6 DAY AND CURDATE();

-- (g) rerun: totals are replaced, not added
--     3 days ago: 190.00 kg, K830.00 | 4 days ago: 330.50 kg, K1242.00
CALL pr_refresh_purchases(CURDATE() - INTERVAL 3 DAY);
CALL pr_refresh_purchases(CURDATE() - INTERVAL 3 DAY);
CALL pr_refresh_purchases(CURDATE() - INTERVAL 4 DAY);
SELECT * FROM daily_purchases ORDER BY purchase_date;

-- Scheduled job: every day at 01:30 for the previous day
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_purchases_daily
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 90 MINUTE)
DO CALL pr_refresh_purchases(CURRENT_DATE - INTERVAL 1 DAY);

SHOW EVENTS FROM maize_coop_db;