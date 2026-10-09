-- =============================================================================
-- Hospital Management Database  |  indexes.sql
-- Secondary indexes for the most common query patterns. Primary keys, unique
-- keys and foreign keys already create their own indexes (see schema.sql).
-- Evidence for why these help: performance_demo.sql and README.md.
-- =============================================================================
USE hospital_db;

-- "Show appointments for a date range, filtered by status" (reception, admin reports)
CREATE INDEX idx_appointments_date_status ON appointments (appointment_at, status);

-- "Find a patient by name" (reception front desk)
CREATE INDEX idx_patients_name ON patients (last_name, first_name);

-- "List unpaid or part-paid invoices, oldest first" (billing)
CREATE INDEX idx_invoices_status_date ON invoices (status, issued_on);

-- Note: appointments (doctor_id, appointment_at) is already covered by the
-- unique key uq_doctor_slot, which also prevents double-booking.
