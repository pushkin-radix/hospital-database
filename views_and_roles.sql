-- =============================================================================
-- Hospital Management Database  |  views_and_roles.sql
-- Role-based access: each group of staff sees only what its job needs.
--
--   role_doctor     -> own appointments + own patients (incl. diagnosis), can complete own visits
--   role_billing    -> invoices and balances, NO clinical data (no diagnosis/notes)
--   role_reception  -> patient contact details + schedule, NO clinical data, can book slots
--   role_admin      -> everything in hospital_db
--
-- Non-admin roles get NO privileges on base tables. They read through views
-- and write through stored procedures.
--
-- Requires: procedures.sql already loaded (GRANT EXECUTE needs the procedures to exist).
-- Demo passwords below are placeholders. Change them before using this anywhere real.
-- =============================================================================
USE hospital_db;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Doctors: only appointments belonging to the logged-in doctor.
-- USER() is the client login (e.g. 'dr_demo1@localhost'), even inside a view.
CREATE OR REPLACE VIEW v_doctor_my_appointments AS
SELECT a.appointment_id,
       a.appointment_at,
       a.status,
       a.patient_id,
       CONCAT(p.first_name, ' ', p.last_name) AS patient_name,
       TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) AS patient_age,
       a.reason,
       a.diagnosis,
       a.notes
  FROM appointments a
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
  JOIN patients p ON p.patient_id = a.patient_id
 WHERE d.db_username = SUBSTRING_INDEX(USER(), '@', 1);

-- Doctors: patients they have an appointment with.
CREATE OR REPLACE VIEW v_doctor_my_patients AS
SELECT p.patient_id,
       CONCAT(p.first_name, ' ', p.last_name) AS patient_name,
       p.gender,
       p.blood_group,
       TIMESTAMPDIFF(YEAR, p.date_of_birth, CURDATE()) AS age,
       p.phone,
       COUNT(*)              AS visits,
       MAX(a.appointment_at) AS last_visit
  FROM appointments a
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
  JOIN patients p ON p.patient_id = a.patient_id
 WHERE d.db_username = SUBSTRING_INDEX(USER(), '@', 1)
 GROUP BY p.patient_id, p.first_name, p.last_name, p.gender, p.blood_group, p.date_of_birth, p.phone;

-- Billing: money only. No diagnosis, notes or reason for visit.
CREATE OR REPLACE VIEW v_billing_invoices AS
SELECT i.invoice_id,
       i.issued_on,
       p.patient_id,
       CONCAT(p.first_name, ' ', p.last_name) AS patient_name,
       dep.name                               AS department,
       i.consultation_fee,
       i.medicine_total,
       i.total_amount,
       IFNULL(pay.paid, 0)                    AS paid_amount,
       i.total_amount - IFNULL(pay.paid, 0)   AS balance,
       i.status
  FROM invoices i
  JOIN appointments a   ON a.appointment_id = i.appointment_id
  JOIN patients p       ON p.patient_id     = a.patient_id
  JOIN doctors d        ON d.doctor_id      = a.doctor_id
  JOIN departments dep  ON dep.department_id = d.department_id
  LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payments GROUP BY invoice_id) pay
         ON pay.invoice_id = i.invoice_id;

CREATE OR REPLACE VIEW v_billing_outstanding AS
SELECT invoice_id, issued_on, patient_id, patient_name, department, total_amount, paid_amount, balance, status
  FROM v_billing_invoices
 WHERE status <> 'PAID';

-- Reception: who is coming when. No diagnosis, notes or blood group.
CREATE OR REPLACE VIEW v_reception_schedule AS
SELECT a.appointment_id,
       a.appointment_at,
       a.status,
       CONCAT(p.first_name, ' ', p.last_name) AS patient_name,
       p.phone                                AS patient_phone,
       CONCAT('Dr. ', d.first_name, ' ', d.last_name) AS doctor_name,
       dep.name                               AS department,
       a.reason
  FROM appointments a
  JOIN patients p      ON p.patient_id = a.patient_id
  JOIN doctors d       ON d.doctor_id  = a.doctor_id
  JOIN departments dep ON dep.department_id = d.department_id;

CREATE OR REPLACE VIEW v_reception_patients AS
SELECT patient_id, first_name, last_name, date_of_birth, gender, phone, email, city, registered_on
  FROM patients;

-- Directory of active doctors (reception needs ids to book; billing and doctors may also look up colleagues)
CREATE OR REPLACE VIEW v_doctor_directory AS
SELECT d.doctor_id,
       CONCAT('Dr. ', d.first_name, ' ', d.last_name) AS doctor_name,
       d.specialization,
       dep.name AS department,
       d.consultation_fee
  FROM doctors d
  JOIN departments dep ON dep.department_id = d.department_id
 WHERE d.is_active = 1;

-- Admin reporting: workload per department
CREATE OR REPLACE VIEW v_department_workload AS
SELECT dep.department_id,
       dep.name AS department,
       COUNT(DISTINCT d.doctor_id)                                  AS doctors,
       COUNT(a.appointment_id)                                      AS appointments,
       SUM(a.status = 'COMPLETED')                                  AS completed,
       SUM(a.status = 'CANCELLED')                                  AS cancelled,
       SUM(a.status = 'NO_SHOW')                                    AS no_shows
  FROM departments dep
  LEFT JOIN doctors d      ON d.department_id = dep.department_id
  LEFT JOIN appointments a ON a.doctor_id = d.doctor_id
 GROUP BY dep.department_id, dep.name;

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS role_doctor, role_billing, role_reception, role_admin;

-- Doctor
GRANT SELECT  ON hospital_db.v_doctor_my_appointments TO role_doctor;
GRANT SELECT  ON hospital_db.v_doctor_my_patients     TO role_doctor;
GRANT SELECT  ON hospital_db.v_doctor_directory       TO role_doctor;
GRANT EXECUTE ON PROCEDURE hospital_db.sp_complete_appointment TO role_doctor;

-- Billing
GRANT SELECT  ON hospital_db.v_billing_invoices    TO role_billing;
GRANT SELECT  ON hospital_db.v_billing_outstanding TO role_billing;
GRANT EXECUTE ON PROCEDURE hospital_db.sp_generate_invoice TO role_billing;
GRANT EXECUTE ON PROCEDURE hospital_db.sp_record_payment   TO role_billing;
GRANT EXECUTE ON PROCEDURE hospital_db.sp_department_revenue TO role_billing;

-- Reception
GRANT SELECT  ON hospital_db.v_reception_schedule TO role_reception;
GRANT SELECT  ON hospital_db.v_reception_patients TO role_reception;
GRANT SELECT  ON hospital_db.v_doctor_directory   TO role_reception;
GRANT EXECUTE ON PROCEDURE hospital_db.sp_book_appointment TO role_reception;

-- Admin: full control of this database only (not other databases, not user management)
GRANT ALL PRIVILEGES ON hospital_db.* TO role_admin;

-- ---------------------------------------------------------------------------
-- Demo users (placeholders; names match doctors.db_username in sample_data.sql)
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'dr_demo1'@'localhost'     IDENTIFIED BY 'ChangeMe#Doc1';
CREATE USER IF NOT EXISTS 'dr_demo2'@'localhost'     IDENTIFIED BY 'ChangeMe#Doc2';
CREATE USER IF NOT EXISTS 'dr_demo3'@'localhost'     IDENTIFIED BY 'ChangeMe#Doc3';
CREATE USER IF NOT EXISTS 'billing_demo'@'localhost' IDENTIFIED BY 'ChangeMe#Bill';
CREATE USER IF NOT EXISTS 'reception_demo'@'localhost' IDENTIFIED BY 'ChangeMe#Recep';
CREATE USER IF NOT EXISTS 'admin_demo'@'localhost'   IDENTIFIED BY 'ChangeMe#Admin';

GRANT role_doctor    TO 'dr_demo1'@'localhost', 'dr_demo2'@'localhost', 'dr_demo3'@'localhost';
GRANT role_billing   TO 'billing_demo'@'localhost';
GRANT role_reception TO 'reception_demo'@'localhost';
GRANT role_admin     TO 'admin_demo'@'localhost';

-- Roles must be activated in a session with:  SET ROLE role_doctor;
-- To activate automatically at login, use ONE of:
--   MySQL 8:   SET DEFAULT ROLE role_doctor TO 'dr_demo1'@'localhost';
--   MariaDB:   SET DEFAULT ROLE role_doctor FOR 'dr_demo1'@'localhost';
