-- =============================================================================
-- Hospital Management Database  |  schema.sql
-- Target: MySQL 8.0+ (also tested on MariaDB 10.11)
-- Design: 3NF, 9 tables, PK/FK/UNIQUE/CHECK constraints.
-- Run order: schema.sql -> procedures.sql -> views_and_roles.sql -> sample_data.sql -> indexes.sql
-- (setup.sh does this for you)
-- =============================================================================

DROP DATABASE IF EXISTS hospital_db;
CREATE DATABASE hospital_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
USE hospital_db;

-- ---------------------------------------------------------------------------
-- departments: lookup table, one row per hospital department
-- ---------------------------------------------------------------------------
CREATE TABLE departments (
  department_id SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name          VARCHAR(80)       NOT NULL,
  floor_no      TINYINT UNSIGNED  NOT NULL,
  phone         VARCHAR(15)       NULL,
  PRIMARY KEY (department_id),
  UNIQUE KEY uq_departments_name (name)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- doctors: each doctor belongs to exactly one department.
-- db_username links a doctor to a database login so views can show
-- "my" appointments only (see views_and_roles.sql).
-- ---------------------------------------------------------------------------
CREATE TABLE doctors (
  doctor_id        INT UNSIGNED      NOT NULL AUTO_INCREMENT,
  department_id    SMALLINT UNSIGNED NOT NULL,
  first_name       VARCHAR(50)       NOT NULL,
  last_name        VARCHAR(50)       NOT NULL,
  specialization   VARCHAR(80)       NOT NULL,
  email            VARCHAR(120)      NOT NULL,
  phone            VARCHAR(15)       NOT NULL,
  consultation_fee DECIMAL(8,2)      NOT NULL,
  db_username      VARCHAR(32)       NULL,
  joined_on        DATE              NOT NULL,
  is_active        TINYINT(1)        NOT NULL DEFAULT 1,
  PRIMARY KEY (doctor_id),
  UNIQUE KEY uq_doctors_email (email),
  UNIQUE KEY uq_doctors_db_username (db_username),
  CONSTRAINT fk_doctors_department
    FOREIGN KEY (department_id) REFERENCES departments (department_id),
  CONSTRAINT chk_doctors_fee CHECK (consultation_fee >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- patients
-- ---------------------------------------------------------------------------
CREATE TABLE patients (
  patient_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
  first_name    VARCHAR(50)  NOT NULL,
  last_name     VARCHAR(50)  NOT NULL,
  date_of_birth DATE         NOT NULL,
  gender        ENUM('F','M','O') NOT NULL,
  blood_group   ENUM('A+','A-','B+','B-','AB+','AB-','O+','O-') NULL,
  phone         VARCHAR(15)  NOT NULL,
  email         VARCHAR(120) NULL,
  city          VARCHAR(60)  NOT NULL,
  registered_on DATE         NOT NULL,
  PRIMARY KEY (patient_id),
  UNIQUE KEY uq_patients_email (email)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- appointments: one doctor, one patient, one time slot.
-- uq_doctor_slot makes double-booking a doctor impossible at the database level.
-- diagnosis/notes are clinical data: only doctors and admins may see them.
-- ---------------------------------------------------------------------------
CREATE TABLE appointments (
  appointment_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  patient_id     INT UNSIGNED NOT NULL,
  doctor_id      INT UNSIGNED NOT NULL,
  appointment_at DATETIME     NOT NULL,
  status         ENUM('SCHEDULED','COMPLETED','CANCELLED','NO_SHOW') NOT NULL DEFAULT 'SCHEDULED',
  reason         VARCHAR(255) NOT NULL,
  diagnosis      VARCHAR(255) NULL,
  notes          TEXT         NULL,
  created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (appointment_id),
  UNIQUE KEY uq_doctor_slot (doctor_id, appointment_at),
  CONSTRAINT fk_appointments_patient
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id),
  CONSTRAINT fk_appointments_doctor
    FOREIGN KEY (doctor_id)  REFERENCES doctors (doctor_id),
  CONSTRAINT chk_completed_has_diagnosis
    CHECK (status <> 'COMPLETED' OR diagnosis IS NOT NULL)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- medicines: catalogue with current price and stock
-- ---------------------------------------------------------------------------
CREATE TABLE medicines (
  medicine_id INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  name        VARCHAR(100)  NOT NULL,
  unit_price  DECIMAL(8,2)  NOT NULL,
  stock_qty   INT UNSIGNED  NOT NULL DEFAULT 0,
  PRIMARY KEY (medicine_id),
  UNIQUE KEY uq_medicines_name (name),
  CONSTRAINT chk_medicines_price CHECK (unit_price > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- prescriptions: at most one per appointment
-- ---------------------------------------------------------------------------
CREATE TABLE prescriptions (
  prescription_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  appointment_id  INT UNSIGNED NOT NULL,
  issued_on       DATE         NOT NULL,
  PRIMARY KEY (prescription_id),
  UNIQUE KEY uq_prescriptions_appointment (appointment_id),
  CONSTRAINT fk_prescriptions_appointment
    FOREIGN KEY (appointment_id) REFERENCES appointments (appointment_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- prescription_items: many-to-many between prescriptions and medicines.
-- unit_price is a snapshot, so later price changes do not rewrite old bills.
-- ---------------------------------------------------------------------------
CREATE TABLE prescription_items (
  prescription_id INT UNSIGNED      NOT NULL,
  medicine_id     INT UNSIGNED      NOT NULL,
  quantity        SMALLINT UNSIGNED NOT NULL,
  unit_price      DECIMAL(8,2)      NOT NULL,
  dosage          VARCHAR(100)      NOT NULL,
  PRIMARY KEY (prescription_id, medicine_id),
  CONSTRAINT fk_items_prescription
    FOREIGN KEY (prescription_id) REFERENCES prescriptions (prescription_id)
    ON DELETE CASCADE,
  CONSTRAINT fk_items_medicine
    FOREIGN KEY (medicine_id) REFERENCES medicines (medicine_id),
  CONSTRAINT chk_items_qty   CHECK (quantity > 0),
  CONSTRAINT chk_items_price CHECK (unit_price > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- invoices: one per completed appointment. total_amount is derived, so it can
-- never disagree with its parts.
-- ---------------------------------------------------------------------------
CREATE TABLE invoices (
  invoice_id       INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  appointment_id   INT UNSIGNED  NOT NULL,
  consultation_fee DECIMAL(8,2)  NOT NULL,
  medicine_total   DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_amount     DECIMAL(10,2) AS (consultation_fee + medicine_total) STORED,
  status           ENUM('PENDING','PARTIAL','PAID') NOT NULL DEFAULT 'PENDING',
  issued_on        DATE          NOT NULL,
  PRIMARY KEY (invoice_id),
  UNIQUE KEY uq_invoices_appointment (appointment_id),
  CONSTRAINT fk_invoices_appointment
    FOREIGN KEY (appointment_id) REFERENCES appointments (appointment_id),
  CONSTRAINT chk_invoices_amounts CHECK (consultation_fee >= 0 AND medicine_total >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- payments: an invoice can be paid in several instalments
-- ---------------------------------------------------------------------------
CREATE TABLE payments (
  payment_id INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  invoice_id INT UNSIGNED  NOT NULL,
  amount     DECIMAL(10,2) NOT NULL,
  method     ENUM('CASH','CARD','UPI','INSURANCE') NOT NULL,
  paid_at    DATETIME      NOT NULL,
  PRIMARY KEY (payment_id),
  CONSTRAINT fk_payments_invoice
    FOREIGN KEY (invoice_id) REFERENCES invoices (invoice_id),
  CONSTRAINT chk_payments_amount CHECK (amount > 0)
) ENGINE=InnoDB;
