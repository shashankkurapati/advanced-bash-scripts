#!/bin/bash
# ============================================================
# ldap_delete_users.sh
# LDAP User Deletion Script
# Flow: CSV → LDIF → Count → Delete one by one
# Author: Shashank Kurapati
# Usage: ./ldap_delete_users.sh users.csv
# ============================================================

# ─── LDAP CONFIG ─────────────────────────────────────────────
LDAP_HOST="ldap://10.0.1.50"           # Your OpenDJ / LDAP server
LDAP_PORT="389"                         # 636 for LDAPS
LDAP_BIND_DN="cn=Directory Manager"    # Admin bind DN
LDAP_BIND_PW="YourAdminPassword"       # Admin password
BASE_DN="ou=People,dc=example,dc=com"  # Base DN where users exist

# ─── FILE PATHS ──────────────────────────────────────────────
INPUT_CSV="$1"
LDIF_FILE="/tmp/delete_users_$(date +%Y%m%d_%H%M%S).ldif"
SUCCESS_LOG="/tmp/ldap_delete_success_$(date +%Y%m%d_%H%M%S).log"
FAILED_LOG="/tmp/ldap_delete_failed_$(date +%Y%m%d_%H%M%S).log"
AUDIT_LOG="/tmp/ldap_delete_audit_$(date +%Y%m%d_%H%M%S).log"

# ─── COLORS ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── LOGGING ─────────────────────────────────────────────────
log()      { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$AUDIT_LOG"; }
log_ok()   { log "${GREEN}[OK]${NC}      $1"; }
log_fail() { log "${RED}[FAIL]${NC}    $1"; }
log_info() { log "${CYAN}[INFO]${NC}    $1"; }
log_warn() { log "${YELLOW}[WARN]${NC}    $1"; }
log_step() { log "${YELLOW}[STEP]${NC}    $1"; }

# ─── BANNER ──────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}       LDAP USER DELETION SCRIPT                    ${NC}"
    echo -e "${CYAN}       CSV → LDIF → Count → Delete                  ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─── STEP 0: VALIDATIONS ─────────────────────────────────────
validate_inputs() {
    log_step "STEP 0: Validating inputs..."

    # Check CSV file passed
    if [[ -z "$INPUT_CSV" ]]; then
        echo -e "${RED}ERROR: No CSV file provided.${NC}"
        echo "Usage: $0 users.csv"
        exit 1
    fi

    # Check CSV file exists
    if [[ ! -f "$INPUT_CSV" ]]; then
        echo -e "${RED}ERROR: File not found: $INPUT_CSV${NC}"
        exit 1
    fi

    # Check ldapdelete is available
    if ! command -v ldapdelete &>/dev/null; then
        echo -e "${RED}ERROR: ldapdelete not found. Install openldap-clients.${NC}"
        exit 1
    fi

    # Check CSV has content (skip header)
    DATA_LINES=$(tail -n +2 "$INPUT_CSV" | grep -v '^[[:space:]]*$' | wc -l)
    if [[ "$DATA_LINES" -eq 0 ]]; then
        echo -e "${RED}ERROR: CSV file is empty or has only header.${NC}"
        exit 1
    fi

    log_ok "Input CSV validated: $INPUT_CSV"
}

# ─── STEP 1: SHOW CSV PREVIEW ────────────────────────────────
preview_csv() {
    log_step "STEP 1: CSV Preview (first 5 rows)..."
    echo ""
    echo -e "${CYAN}--- CSV Content Preview ---${NC}"
    head -6 "$INPUT_CSV"
    echo -e "${CYAN}---------------------------${NC}"
    echo ""
}

# ─── STEP 2: CONVERT CSV TO LDIF ─────────────────────────────
# Expected CSV format (with header):
#   uid,cn,ou
#   jsmith,John Smith,Engineering
#   mjones,Mary Jones,Finance
#
# If your CSV has only uid column, script handles that too.
# LDIF delete format is simply:   dn: uid=USER,ou=People,dc=example,dc=com
#                                 changetype: delete

convert_csv_to_ldif() {
    log_step "STEP 2: Converting CSV to LDIF..."

    # Clear/create LDIF file
    > "$LDIF_FILE"

    local line_num=0
    local success_count=0
    local skip_count=0

    while IFS=',' read -r uid rest; do
        # Skip header line
        (( line_num++ ))
        if [[ $line_num -eq 1 ]]; then
            log_info "Skipping header: $uid"
            continue
        fi

        # Trim whitespace and carriage returns (Windows CSV fix)
        uid=$(echo "$uid" | tr -d '[:space:]\r')

        # Skip empty lines
        if [[ -z "$uid" ]]; then
            (( skip_count++ ))
            continue
        fi

        # Build the DN
        DN="uid=${uid},${BASE_DN}"

        # Write LDIF delete entry
        echo "dn: $DN"          >> "$LDIF_FILE"
        echo "changetype: delete" >> "$LDIF_FILE"
        echo ""                  >> "$LDIF_FILE"

        (( success_count++ ))

    done < "$INPUT_CSV"

    log_ok "LDIF file created: $LDIF_FILE"
    log_info "Entries written to LDIF : $success_count"
    [[ $skip_count -gt 0 ]] && log_warn "Blank lines skipped      : $skip_count"
}

# ─── STEP 3: COUNT USERS TO DELETE ───────────────────────────
count_users() {
    log_step "STEP 3: Counting users to be deleted..."

    TOTAL_USERS=$(grep -c "^changetype: delete" "$LDIF_FILE")

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Total users to be DELETED : ${RED}$TOTAL_USERS${NC}"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo ""
    log_info "Total users queued for deletion: $TOTAL_USERS"
}

# ─── STEP 4: CONFIRM BEFORE DELETE ───────────────────────────
confirm_deletion() {
    log_step "STEP 4: Confirmation..."

    echo -e "${RED}WARNING: This will permanently delete $TOTAL_USERS users from LDAP.${NC}"
    echo -e "${YELLOW}LDAP Server : $LDAP_HOST${NC}"
    echo -e "${YELLOW}Base DN     : $BASE_DN${NC}"
    echo -e "${YELLOW}LDIF File   : $LDIF_FILE${NC}"
    echo ""
    echo -ne "${RED}Are you sure you want to proceed? Type YES to confirm: ${NC}"
    read -r CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        log_warn "Deletion cancelled by user."
        echo "Exiting. No users deleted."
        exit 0
    fi

    log_info "User confirmed deletion. Proceeding..."
}

# ─── STEP 5: DELETE USERS ONE BY ONE ─────────────────────────
delete_users() {
    log_step "STEP 5: Starting deletion one by one..."

    local deleted=0
    local failed=0
    local current=0

    # Initialize log files
    > "$SUCCESS_LOG"
    > "$FAILED_LOG"

    # Parse LDIF and process each DN
    while IFS= read -r line; do
        # Grab the DN line
        if [[ "$line" =~ ^dn:\ (.+)$ ]]; then
            DN="${BASH_REMATCH[1]}"
            (( current++ ))

            echo ""
            echo -e "${CYAN}[$current/$TOTAL_USERS] Deleting: $DN${NC}"
            log_info "[$current/$TOTAL_USERS] Attempting delete: $DN"

            # Run ldapdelete for this single DN
            ldapdelete \
                -H "${LDAP_HOST}:${LDAP_PORT}" \
                -D "$LDAP_BIND_DN" \
                -w "$LDAP_BIND_PW" \
                "$DN" >> "$AUDIT_LOG" 2>&1

            if [[ $? -eq 0 ]]; then
                log_ok "DELETED: $DN"
                echo "$DN" >> "$SUCCESS_LOG"
                (( deleted++ ))
            else
                log_fail "FAILED : $DN"
                echo "$DN" >> "$FAILED_LOG"
                (( failed++ ))
            fi

            # Small pause between deletes (safe for LDAP)
            sleep 1
        fi
    done < "$LDIF_FILE"

    # ─── SUMMARY REPORT ──────────────────────────────────────
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              DELETION SUMMARY              ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "  Total Queued  : ${YELLOW}$TOTAL_USERS${NC}"
    echo -e "  Deleted       : ${GREEN}$deleted${NC}"
    echo -e "  Failed        : ${RED}$failed${NC}"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "  Success Log   : $SUCCESS_LOG"
    echo -e "  Failed Log    : $FAILED_LOG"
    echo -e "  Audit Log     : $AUDIT_LOG"
    echo -e "  LDIF File     : $LDIF_FILE"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo ""

    log_info "Deletion complete. Deleted=$deleted Failed=$failed"

    if [[ $failed -gt 0 ]]; then
        log_warn "Some deletions failed. Check: $FAILED_LOG"
        echo -e "${RED}Re-run only failed users? Check $FAILED_LOG and re-create CSV from it.${NC}"
    fi
}

# ─── MAIN ────────────────────────────────────────────────────
print_banner
validate_inputs
preview_csv
convert_csv_to_ldif
count_users
confirm_deletion
delete_users
