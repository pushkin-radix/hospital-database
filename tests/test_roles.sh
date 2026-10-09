#!/usr/bin/env bash
# Logs in as each demo user and checks what each role can and cannot do.
# Uses admin access (DB_USER, default root) only to pick test rows and to undo
# the changes the tests make, so it leaves your data as it found it.
# Usage:  ./tests/test_roles.sh     (after ./setup.sh)
set -uo pipefail

DB="hospital_db"
ADMIN_USER="${DB_USER:-root}"
PASS=0; FAIL=0

# run <user> <password> <role> <sql>  -> prints output/errors, never exits the script
run() {
  local user="$1" pw="$2" role="$3" sql="$4"
  # Roles are not active at login, so connect WITHOUT a default database,
  # activate the role, then USE the database.
  MYSQL_PWD="$pw" mysql -u"$user" -h localhost -N -B -e "SET ROLE $role; USE $DB; $sql" 2>&1
}
admin() { mysql -u"$ADMIN_USER" -h localhost "$DB" -N -B -e "$1" 2>&1; }

# check <description> <actual output> <expected regex> [fail]
ok()   { if [[ "$2" =~ $3 ]]; then echo "  PASS  $1"; ((PASS++)); else echo "  FAIL  $1"; echo "        got: $2"; ((FAIL++)); fi; }

DENIED='ERROR 1142|ERROR 1143|command denied|denied to user'

# ---- pick test data -------------------------------------------------------
DR1_APPT=$(admin "SELECT appointment_id FROM appointments WHERE doctor_id=1 AND status='SCHEDULED' ORDER BY appointment_at LIMIT 1")
DR2_APPT=$(admin "SELECT appointment_id FROM appointments WHERE doctor_id=2 AND status='SCHEDULED' ORDER BY appointment_at LIMIT 1")
DR1_COUNT=$(admin "SELECT COUNT(*) FROM appointments WHERE doctor_id=1")
TOTAL_APPTS=$(admin "SELECT COUNT(*) FROM appointments")
FREE_SLOT="2027-01-11 10:00:00"      # a Monday well after the sample data
echo "Test data: dr1 appointment=$DR1_APPT, dr2 appointment=$DR2_APPT"

echo; echo "== Doctor (dr_demo1, role_doctor) =="
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "SELECT COUNT(*) FROM v_doctor_my_appointments")
ok "sees only own appointments ($DR1_COUNT)" "$out" "^$DR1_COUNT$"
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "SELECT COUNT(*) FROM v_doctor_my_appointments WHERE diagnosis IS NOT NULL")
ok "can see diagnoses on own appointments" "$out" '^[1-9][0-9]*$'
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "SELECT COUNT(*) FROM appointments")
ok "cannot read base table appointments" "$out" "$DENIED"
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "SELECT COUNT(*) FROM v_billing_invoices")
ok "cannot read billing view" "$out" "$DENIED"
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "UPDATE appointments SET status='CANCELLED' WHERE appointment_id=$DR1_APPT")
ok "cannot UPDATE tables directly" "$out" "$DENIED"
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "CALL sp_complete_appointment($DR2_APPT, 'Fever', NULL)")
ok "cannot complete another doctor's appointment" "$out" 'Not your appointment'
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "CALL sp_complete_appointment($DR1_APPT, '', NULL)")
ok "diagnosis is required" "$out" 'Diagnosis is required'
out=$(run dr_demo1 'ChangeMe#Doc1' role_doctor "CALL sp_complete_appointment($DR1_APPT, 'Viral fever', 'Rest and fluids'); SELECT status, diagnosis FROM v_doctor_my_appointments WHERE appointment_id=$DR1_APPT")
ok "completes own appointment" "$out" 'COMPLETED[[:space:]]+Viral fever'
out=$(run dr_demo2 'ChangeMe#Doc2' role_doctor "SELECT COUNT(*) FROM v_doctor_my_appointments WHERE appointment_id=$DR1_APPT")
ok "another doctor cannot see that appointment" "$out" '^0$'

echo; echo "== Billing (billing_demo, role_billing) =="
out=$(run billing_demo 'ChangeMe#Bill' role_billing "SELECT COUNT(*) FROM v_billing_invoices")
ok "reads invoices" "$out" '^[1-9][0-9]*$'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "SELECT diagnosis FROM v_billing_invoices LIMIT 1")
ok "billing view has no diagnosis column" "$out" 'ERROR 1054|Unknown column'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "SELECT COUNT(*) FROM appointments")
ok "cannot read base table appointments" "$out" "$DENIED"
out=$(run billing_demo 'ChangeMe#Bill' role_billing "SELECT COUNT(*) FROM v_doctor_my_appointments")
ok "cannot read doctor views" "$out" "$DENIED"
out=$(run billing_demo 'ChangeMe#Bill' role_billing "DELETE FROM payments")
ok "cannot DELETE payments" "$out" "$DENIED"
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_generate_invoice(999999, @i)")
ok "cannot invoice a missing appointment" "$out" 'not found or not completed'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_generate_invoice($DR2_APPT, @i)")
ok "cannot invoice an appointment that is not completed" "$out" 'not found or not completed'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_generate_invoice($DR1_APPT, @i); SELECT @i")
ok "generates invoice for completed appointment" "$out" '^[0-9]+$'
INV=$(admin "SELECT invoice_id FROM invoices WHERE appointment_id=$DR1_APPT")
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_generate_invoice($DR1_APPT, @i)")
ok "cannot invoice the same appointment twice" "$out" 'already exists'
TOTAL=$(admin "SELECT total_amount FROM invoices WHERE invoice_id=$INV")
HALF=$(admin "SELECT ROUND(total_amount/2,2) FROM invoices WHERE invoice_id=$INV")
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_record_payment($INV, $TOTAL + 1, 'CASH')")
ok "overpayment is rejected" "$out" 'exceeds the outstanding balance'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_record_payment($INV, 0, 'CASH')")
ok "zero payment is rejected" "$out" 'must be positive'
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_record_payment($INV, $HALF, 'UPI'); SELECT status FROM v_billing_invoices WHERE invoice_id=$INV")
ok "part payment sets status PARTIAL" "$out" '^PARTIAL$'
REST=$(admin "SELECT total_amount - SUM(p.amount) FROM invoices i JOIN payments p USING (invoice_id) WHERE i.invoice_id=$INV")
out=$(run billing_demo 'ChangeMe#Bill' role_billing "CALL sp_record_payment($INV, $REST, 'CARD'); SELECT status, balance FROM v_billing_invoices WHERE invoice_id=$INV")
ok "final payment sets status PAID, balance 0" "$out" 'PAID[[:space:]]+0\.00'

echo; echo "== Reception (reception_demo, role_reception) =="
out=$(run reception_demo 'ChangeMe#Recep' role_reception "SELECT COUNT(*) FROM v_reception_schedule")
ok "reads schedule" "$out" "^$TOTAL_APPTS$"
out=$(run reception_demo 'ChangeMe#Recep' role_reception "SELECT diagnosis FROM v_reception_schedule LIMIT 1")
ok "schedule view has no diagnosis column" "$out" 'ERROR 1054|Unknown column'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "SELECT blood_group FROM v_reception_patients LIMIT 1")
ok "patient view hides blood group" "$out" 'ERROR 1054|Unknown column'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "SELECT COUNT(*) FROM invoices")
ok "cannot read invoices" "$out" "$DENIED"
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(1, 1, '$FREE_SLOT', 'Routine check-up', @a); SELECT @a")
ok "books a free slot" "$out" '^[0-9]+$'
NEW_APPT=$(admin "SELECT appointment_id FROM appointments WHERE doctor_id=1 AND appointment_at='$FREE_SLOT'")
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(2, 1, '$FREE_SLOT', 'Fever', @a)")
ok "double-booking the same doctor and slot is rejected" "$out" 'already booked'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(2, 1, '2027-01-11 10:15:00', 'Fever', @a)")
ok "off-grid time (10:15) is rejected" "$out" 'Slots run'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(2, 1, '2027-01-11 18:00:00', 'Fever', @a)")
ok "after-hours time (18:00) is rejected" "$out" 'Slots run'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(2, 1, '2025-01-06 10:00:00', 'Fever', @a)")
ok "past date is rejected" "$out" 'must be in the future'
out=$(run reception_demo 'ChangeMe#Recep' role_reception "CALL sp_book_appointment(999999, 1, '2027-01-11 11:00:00', 'Fever', @a)")
ok "unknown patient is rejected" "$out" 'Unknown patient'

echo; echo "== Admin (admin_demo, role_admin) =="
out=$(run admin_demo 'ChangeMe#Admin' role_admin "SELECT COUNT(*) FROM appointments")
ok "reads base tables" "$out" '^[0-9]+$'
out=$(run admin_demo 'ChangeMe#Admin' role_admin "SELECT COUNT(*) FROM mysql.user")
ok "cannot read the server's user table" "$out" "$DENIED"

echo; echo "== Database rules (as admin) =="
out=$(admin "INSERT INTO appointments (patient_id, doctor_id, appointment_at, status, reason) VALUES (1,1,'2027-02-01 09:00:00','COMPLETED','x')")
ok "COMPLETED without diagnosis violates CHECK" "$out" 'ERROR 4025|ERROR 3819|CONSTRAINT|constraint'
out=$(admin "DELETE FROM patients WHERE patient_id=1")
ok "deleting a patient with appointments is blocked by FK" "$out" 'ERROR 1451|foreign key'
out=$(admin "INSERT INTO payments (invoice_id, amount, method, paid_at) VALUES ($INV, -5, 'CASH', NOW())")
ok "negative payment violates CHECK" "$out" 'ERROR 4025|ERROR 3819|CONSTRAINT|constraint'

# ---- undo everything the tests changed ------------------------------------
admin "DELETE FROM payments WHERE invoice_id=$INV; DELETE FROM invoices WHERE invoice_id=$INV;
       UPDATE appointments SET status='SCHEDULED', diagnosis=NULL, notes=NULL WHERE appointment_id=$DR1_APPT;
       DELETE FROM appointments WHERE appointment_id=$NEW_APPT;" > /dev/null

echo; echo "Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
