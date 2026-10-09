-- =============================================================================
-- Hospital Management Database  |  procedures.sql
-- Stored procedures are the ONLY way non-admin roles change data, so business
-- rules (slot hours, ownership, no overpayment) are enforced in one place.
-- Procedures run with SQL SECURITY DEFINER, so a role needs EXECUTE only,
-- not direct table privileges.
-- =============================================================================
USE hospital_db;

DROP PROCEDURE IF EXISTS sp_book_appointment;
DROP PROCEDURE IF EXISTS sp_complete_appointment;
DROP PROCEDURE IF EXISTS sp_generate_invoice;
DROP PROCEDURE IF EXISTS sp_record_payment;
DROP PROCEDURE IF EXISTS sp_department_revenue;

DELIMITER $$

-- ---------------------------------------------------------------------------
-- Book a 30-minute slot (09:00-16:30, on the hour or half hour, in the future).
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_book_appointment(
  IN  p_patient_id INT UNSIGNED,
  IN  p_doctor_id  INT UNSIGNED,
  IN  p_at         DATETIME,
  IN  p_reason     VARCHAR(255),
  OUT p_appointment_id INT UNSIGNED
)
SQL SECURITY DEFINER
BEGIN
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown patient';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id AND is_active = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown or inactive doctor';
  END IF;

  IF p_at <= NOW() THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appointment must be in the future';
  END IF;

  IF TIME(p_at) < '09:00:00' OR TIME(p_at) > '16:30:00'
     OR MINUTE(p_at) NOT IN (0, 30) OR SECOND(p_at) <> 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Slots run 09:00-16:30 on the hour or half hour';
  END IF;

  IF EXISTS (SELECT 1 FROM appointments
             WHERE doctor_id = p_doctor_id AND appointment_at = p_at
               AND status <> 'CANCELLED') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Doctor already booked at that time';
  END IF;

  -- A cancelled booking in the same slot would violate uq_doctor_slot, so reuse it.
  IF EXISTS (SELECT 1 FROM appointments WHERE doctor_id = p_doctor_id AND appointment_at = p_at) THEN
    UPDATE appointments
       SET patient_id = p_patient_id, status = 'SCHEDULED', reason = p_reason,
           diagnosis = NULL, notes = NULL
     WHERE doctor_id = p_doctor_id AND appointment_at = p_at;
    SELECT appointment_id INTO p_appointment_id
      FROM appointments WHERE doctor_id = p_doctor_id AND appointment_at = p_at;
  ELSE
    INSERT INTO appointments (patient_id, doctor_id, appointment_at, reason)
    VALUES (p_patient_id, p_doctor_id, p_at, p_reason);
    SET p_appointment_id = LAST_INSERT_ID();
  END IF;
END$$

-- ---------------------------------------------------------------------------
-- A doctor completes THEIR OWN appointment and records the diagnosis.
-- Ownership is checked against the login name (doctors.db_username).
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_complete_appointment(
  IN p_appointment_id INT UNSIGNED,
  IN p_diagnosis      VARCHAR(255),
  IN p_notes          TEXT
)
SQL SECURITY DEFINER
BEGIN
  IF p_diagnosis IS NULL OR TRIM(p_diagnosis) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Diagnosis is required';
  END IF;

  IF NOT EXISTS (SELECT 1
                   FROM appointments a
                   JOIN doctors d ON d.doctor_id = a.doctor_id
                  WHERE a.appointment_id = p_appointment_id
                    AND d.db_username = SUBSTRING_INDEX(USER(), '@', 1)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not your appointment';
  END IF;

  IF (SELECT status FROM appointments WHERE appointment_id = p_appointment_id) <> 'SCHEDULED' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only SCHEDULED appointments can be completed';
  END IF;

  UPDATE appointments
     SET status = 'COMPLETED', diagnosis = p_diagnosis, notes = p_notes
   WHERE appointment_id = p_appointment_id;
END$$

-- ---------------------------------------------------------------------------
-- Create the invoice for a completed appointment: consultation fee plus the
-- price snapshot of every prescribed medicine.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_generate_invoice(
  IN  p_appointment_id INT UNSIGNED,
  OUT p_invoice_id     INT UNSIGNED
)
SQL SECURITY DEFINER
BEGIN
  DECLARE v_fee DECIMAL(8,2);
  DECLARE v_meds DECIMAL(10,2);

  IF NOT EXISTS (SELECT 1 FROM appointments
                  WHERE appointment_id = p_appointment_id AND status = 'COMPLETED') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appointment not found or not completed';
  END IF;

  IF EXISTS (SELECT 1 FROM invoices WHERE appointment_id = p_appointment_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invoice already exists for this appointment';
  END IF;

  SELECT d.consultation_fee INTO v_fee
    FROM appointments a JOIN doctors d ON d.doctor_id = a.doctor_id
   WHERE a.appointment_id = p_appointment_id;

  SELECT IFNULL(SUM(pi.quantity * pi.unit_price), 0) INTO v_meds
    FROM prescriptions p
    JOIN prescription_items pi ON pi.prescription_id = p.prescription_id
   WHERE p.appointment_id = p_appointment_id;

  INSERT INTO invoices (appointment_id, consultation_fee, medicine_total, issued_on)
  VALUES (p_appointment_id, v_fee, v_meds, CURDATE());
  SET p_invoice_id = LAST_INSERT_ID();
END$$

-- ---------------------------------------------------------------------------
-- Record a payment. Rejects overpayment and keeps invoices.status in step.
-- The invoice row is locked so two cashiers cannot overpay at the same time.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_record_payment(
  IN p_invoice_id INT UNSIGNED,
  IN p_amount     DECIMAL(10,2),
  IN p_method     VARCHAR(10)
)
SQL SECURITY DEFINER
BEGIN
  DECLARE v_total DECIMAL(10,2);
  DECLARE v_paid  DECIMAL(10,2);
  DECLARE v_found INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment amount must be positive';
  END IF;

  START TRANSACTION;

  SELECT COUNT(*), MAX(total_amount) INTO v_found, v_total
    FROM invoices WHERE invoice_id = p_invoice_id FOR UPDATE;

  IF v_found = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown invoice';
  END IF;

  SELECT IFNULL(SUM(amount), 0) INTO v_paid FROM payments WHERE invoice_id = p_invoice_id;

  IF v_paid + p_amount > v_total THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment exceeds the outstanding balance';
  END IF;

  INSERT INTO payments (invoice_id, amount, method, paid_at)
  VALUES (p_invoice_id, p_amount, p_method, NOW());

  UPDATE invoices
     SET status = IF(v_paid + p_amount = v_total, 'PAID', 'PARTIAL')
   WHERE invoice_id = p_invoice_id;

  COMMIT;
END$$

-- ---------------------------------------------------------------------------
-- Report: billed vs collected per department between two dates (inclusive).
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_department_revenue(IN p_from DATE, IN p_to DATE)
SQL SECURITY DEFINER
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid date range';
  END IF;

  SELECT dep.name                              AS department,
         COUNT(i.invoice_id)                   AS invoices,
         IFNULL(SUM(i.total_amount), 0)        AS billed,
         IFNULL(SUM(pay.paid), 0)              AS collected,
         IFNULL(SUM(i.total_amount), 0) - IFNULL(SUM(pay.paid), 0) AS outstanding
    FROM departments dep
    LEFT JOIN doctors d       ON d.department_id = dep.department_id
    LEFT JOIN appointments a  ON a.doctor_id = d.doctor_id
    LEFT JOIN invoices i      ON i.appointment_id = a.appointment_id
                             AND i.issued_on BETWEEN p_from AND p_to
    LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payments GROUP BY invoice_id) pay
                              ON pay.invoice_id = i.invoice_id
   GROUP BY dep.department_id, dep.name
   ORDER BY billed DESC;
END$$

DELIMITER ;
