-- =============================================================================
-- Hospital Management Database  |  performance_demo.sql
-- Shows what an index does, with numbers. The real tables are small, so this
-- builds a scratch table of 100,000 appointment-like rows, times the same
-- query before and after adding an index, then drops the scratch table.
-- Safe to re-run. Does not touch real data.
-- Run:  mysql -u root hospital_db < performance_demo.sql
-- =============================================================================
USE hospital_db;

DROP TABLE IF EXISTS perf_appointments;
CREATE TABLE perf_appointments (
  id             INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  patient_id     INT UNSIGNED NOT NULL,
  doctor_id      INT UNSIGNED NOT NULL,
  appointment_at DATETIME     NOT NULL,
  status         ENUM('SCHEDULED','COMPLETED','CANCELLED','NO_SHOW') NOT NULL
) ENGINE=InnoDB;

-- 100,000 rows from a cross join of five 0-9 digit sets (no recursion needed,
-- so it works the same on MySQL and MariaDB).
INSERT INTO perf_appointments (patient_id, doctor_id, appointment_at, status)
SELECT 1 + (n * 7919) % 600,
       1 + (n * 31)   % 24,
       TIMESTAMP('2024-01-01 09:00:00') + INTERVAL ((n * 37) % 1000) DAY + INTERVAL ((n % 16) * 30) MINUTE,
       ELT(1 + n % 4, 'SCHEDULED', 'COMPLETED', 'CANCELLED', 'NO_SHOW')
FROM (
  SELECT a.d + 10*b.d + 100*c.d + 1000*e.d + 10000*f.d AS n
  FROM (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
       (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
       (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
       (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e,
       (SELECT 0 d UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
) nums;

SELECT COUNT(*) AS scratch_rows FROM perf_appointments;

-- ---------------------------------------------------------------------------
-- BEFORE: no secondary index. The server has to scan every row.
-- ---------------------------------------------------------------------------
SELECT '--- BEFORE index ---' AS step;
EXPLAIN SELECT COUNT(*) FROM perf_appointments
 WHERE doctor_id = 7 AND appointment_at BETWEEN '2025-03-01' AND '2025-03-31 23:59:59';

SET @t0 = NOW(6);
SELECT COUNT(*) AS matching_rows FROM perf_appointments
 WHERE doctor_id = 7 AND appointment_at BETWEEN '2025-03-01' AND '2025-03-31 23:59:59';
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @t0, NOW(6)) / 1000, 2) AS ms_before;

-- ---------------------------------------------------------------------------
-- AFTER: composite index matching the filter (equality column first, range second).
-- ---------------------------------------------------------------------------
CREATE INDEX idx_perf_doctor_date ON perf_appointments (doctor_id, appointment_at);

SELECT '--- AFTER index ---' AS step;
EXPLAIN SELECT COUNT(*) FROM perf_appointments
 WHERE doctor_id = 7 AND appointment_at BETWEEN '2025-03-01' AND '2025-03-31 23:59:59';

SET @t1 = NOW(6);
SELECT COUNT(*) AS matching_rows FROM perf_appointments
 WHERE doctor_id = 7 AND appointment_at BETWEEN '2025-03-01' AND '2025-03-31 23:59:59';
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @t1, NOW(6)) / 1000, 2) AS ms_after;

DROP TABLE perf_appointments;
