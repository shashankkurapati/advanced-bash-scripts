#!/bin/bash 
# ============================================================
# tibco_deploy.sh
# TIBCO EAR Deployment Script
# Flow:
#   1. Accept new EAR from temp location
#   2. Find old EAR location using find command
#   3. Get version from old EAR (unzip -p | grep version)
#   4. Backup old EAR with version in filename
#   5. Copy new EAR to that location
#   6. Run TIBCO deploy script from /opt/tibco/bin
#   7. Start the TIBCO application
#
# Author: Shashank Kurapati
# Usage : ./tibco_deploy.sh <new_ear_file>
# Example: ./tibco_deploy.sh /tmp/deploy/myapp.ear
# ============================================================

# ---- CONFIG -------------------------------------------------
TIBCO_BIN="/opt/tibco/bin"                    # TIBCO bin location
TIBCO_DEPLOY_SCRIPT="deploy.sh"               # Deploy script name inside /opt/tibco/bin
TIBCO_START_SCRIPT="start.sh"                 # Start script name inside /opt/tibco/bin
SEARCH_BASE="/opt/tibco"                      # Base path to search for old EAR
BACKUP_DIR="/opt/tibco/backup"                # Backup location for old EAR files
APP_NAME=""                                   # Will be auto-detected from EAR filename
OLD_EAR_PATH=""
OLD_EAR_DIR=""
BACKUP_PATH=""
VERSION=""
OLD_VERSION=""

# ---- COLORS -------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- LOG FILE -----------------------------------------------
DEPLOY_LOG="/tmp/tibco_deploy_$(date +%Y%m%d_%H%M%S).log"

# ---- LOGGING ------------------------------------------------
log()      { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$DEPLOY_LOG"; }
log_ok()   { log "${GREEN}[OK]${NC}      $1"; }
log_fail() { log "${RED}[FAIL]${NC}    $1"; }
log_info() { log "${CYAN}[INFO]${NC}    $1"; }
log_warn() { log "${YELLOW}[WARN]${NC}    $1"; }
log_step() { log "${YELLOW}[STEP]${NC}    -- $1"; }

# ---- BANNER -------------------------------------------------
print_banner() {
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}       TIBCO EAR DEPLOYMENT SCRIPT                   ${NC}"
    echo -e "${CYAN}       Find > Backup > Copy > Deploy > Start          ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo ""
}

# ---- ABORT --------------------------------------------------
abort() {
    echo ""
    log_fail "DEPLOYMENT ABORTED: $1"
    echo -e "${RED}Check log: $DEPLOY_LOG${NC}"
    exit 1
}

# ---- STEP 0: VALIDATE INPUTS --------------------------------
validate_inputs() {
    log_step "STEP 0: Validating inputs..."

    NEW_EAR="$1"

    if [[ -z "$NEW_EAR" ]]; then
        echo -e "${RED}ERROR: No EAR file provided.${NC}"
        echo "Usage: $0 /tmp/deploy/myapp.ear"
        exit 1
    fi

    if [[ ! -f "$NEW_EAR" ]]; then
        abort "New EAR file not found: $NEW_EAR"
    fi

    if [[ "${NEW_EAR##*.}" != "ear" ]]; then
        abort "File is not an EAR: $NEW_EAR"
    fi

    # Auto-detect app name from filename
    APP_NAME=$(basename "$NEW_EAR" .ear)
    log_ok "New EAR file : $NEW_EAR"
    log_ok "App Name     : $APP_NAME"

    if ! command -v unzip &>/dev/null; then
        abort "unzip not found. Install it first."
    fi

    if [[ ! -d "$TIBCO_BIN" ]]; then
        abort "TIBCO bin directory not found: $TIBCO_BIN"
    fi

    if [[ ! -f "$TIBCO_BIN/$TIBCO_DEPLOY_SCRIPT" ]]; then
        abort "Deploy script not found: $TIBCO_BIN/$TIBCO_DEPLOY_SCRIPT"
    fi

    mkdir -p "$BACKUP_DIR" || abort "Cannot create backup dir: $BACKUP_DIR"

    log_ok "All validations passed."
}

# ---- STEP 1: FIND OLD EAR USING FIND COMMAND ----------------
find_old_ear() {
    log_step "STEP 1: Searching for existing EAR using find..."

    log_info "Running: find $SEARCH_BASE -name ${APP_NAME}.ear"

    # Use find to locate existing EAR — exclude backup folder
    OLD_EAR_PATH=$(find "$SEARCH_BASE" -name "${APP_NAME}.ear" \
        -not -path "*/backup/*" 2>/dev/null | head -1)

    if [[ -z "$OLD_EAR_PATH" ]]; then
        log_warn "No existing EAR found for ${APP_NAME}.ear"
        log_warn "This will be treated as a fresh deployment."
        OLD_EAR_DIR="$SEARCH_BASE/deploy"
        mkdir -p "$OLD_EAR_DIR"
        log_info "Deploy location defaulted to: $OLD_EAR_DIR"
    else
        OLD_EAR_DIR=$(dirname "$OLD_EAR_PATH")
        log_ok "Old EAR found at  : $OLD_EAR_PATH"
        log_ok "Deploy location   : $OLD_EAR_DIR"
    fi
}

# ---- STEP 2: GET VERSION FROM OLD EAR -----------------------
get_old_version() {
    log_step "STEP 2: Extracting version from old EAR..."

    if [[ -z "$OLD_EAR_PATH" ]] || [[ ! -f "$OLD_EAR_PATH" ]]; then
        log_warn "No old EAR to extract version from. Skipping."
        OLD_VERSION="$(date +%Y%m%d%H%M%S)"
        return
    fi

    # Try META-INF/application.xml first
    OLD_VERSION=$(unzip -p "$OLD_EAR_PATH" META-INF/application.xml 2>/dev/null \
        | grep -i "version" | head -1 \
        | sed 's/.*<version>\(.*\)<\/version>.*/\1/' \
        | tr -d '[:space:]')

    # Try MANIFEST.MF
    if [[ -z "$OLD_VERSION" ]]; then
        log_info "Trying MANIFEST.MF for version..."
        OLD_VERSION=$(unzip -p "$OLD_EAR_PATH" META-INF/MANIFEST.MF 2>/dev/null \
            | grep -iE "Implementation-Version|Bundle-Version" \
            | head -1 | cut -d':' -f2 | tr -d '[:space:]')
    fi

    # Fallback: strings grep
    if [[ -z "$OLD_VERSION" ]]; then
        log_info "Trying strings grep inside EAR..."
        OLD_VERSION=$(unzip -p "$OLD_EAR_PATH" 2>/dev/null \
            | strings | grep -i "^version=" | head -1 \
            | cut -d'=' -f2 | tr -d '[:space:]')
    fi

    # Final fallback
    if [[ -z "$OLD_VERSION" ]]; then
        OLD_VERSION="$(date +%Y%m%d%H%M%S)"
        log_warn "Could not extract version. Using timestamp: $OLD_VERSION"
    fi

    log_ok "Old EAR version : $OLD_VERSION"
}

# ---- STEP 3: GET VERSION FROM NEW EAR -----------------------
get_new_version() {
    log_step "STEP 3: Extracting version from new EAR..."

    VERSION=$(unzip -p "$NEW_EAR" META-INF/application.xml 2>/dev/null \
        | grep -i "version" | head -1 \
        | sed 's/.*<version>\(.*\)<\/version>.*/\1/' \
        | tr -d '[:space:]')

    if [[ -z "$VERSION" ]]; then
        VERSION=$(unzip -p "$NEW_EAR" META-INF/MANIFEST.MF 2>/dev/null \
            | grep -iE "Implementation-Version|Bundle-Version" \
            | head -1 | cut -d':' -f2 | tr -d '[:space:]')
    fi

    if [[ -z "$VERSION" ]]; then
        VERSION="$(date +%Y%m%d%H%M%S)"
        log_warn "Could not extract new version. Using: $VERSION"
    fi

    log_ok "New EAR version : $VERSION"
}

# ---- STEP 4: BACKUP OLD EAR WITH VERSION IN NAME ------------
backup_old_ear() {
    log_step "STEP 4: Backing up old EAR as ${APP_NAME}_v${OLD_VERSION}.ear ..."

    if [[ -z "$OLD_EAR_PATH" ]] || [[ ! -f "$OLD_EAR_PATH" ]]; then
        log_warn "No old EAR to backup. Skipping."
        return
    fi

    BACKUP_FILENAME="${APP_NAME}_v${OLD_VERSION}_$(date +%Y%m%d%H%M%S).ear"
    BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

    cp "$OLD_EAR_PATH" "$BACKUP_PATH" || abort "Backup failed to: $BACKUP_PATH"

    log_ok "Backup saved at : $BACKUP_PATH"
}

# ---- STEP 5: COPY NEW EAR TO DEPLOY LOCATION ----------------
copy_new_ear() {
    log_step "STEP 5: Copying new EAR to deploy location..."

    DEST_PATH="${OLD_EAR_DIR}/${APP_NAME}.ear"

    cp "$NEW_EAR" "$DEST_PATH" || abort "Failed to copy EAR to $DEST_PATH"

    if [[ -f "$DEST_PATH" ]]; then
        DEST_SIZE=$(du -h "$DEST_PATH" | cut -f1)
        log_ok "Copied to      : $DEST_PATH ($DEST_SIZE)"
    else
        abort "Copy verification failed. File missing at $DEST_PATH"
    fi
}

# ---- STEP 6: RUN TIBCO DEPLOY SCRIPT ------------------------
run_deploy() {
    log_step "STEP 6: Running TIBCO deploy script..."

    echo ""
    echo -e "${YELLOW}About to run: $TIBCO_BIN/$TIBCO_DEPLOY_SCRIPT${NC}"
    echo -e "${YELLOW}EAR file    : ${OLD_EAR_DIR}/${APP_NAME}.ear${NC}"
    echo ""
    echo -ne "${RED}Proceed with deployment? (y/n): ${NC}"
    read -r CONFIRM
    [[ "$CONFIRM" != "y" ]] && abort "Deploy cancelled by user."

    cd "$TIBCO_BIN" || abort "Cannot cd to $TIBCO_BIN"

    log_info "Executing deploy script..."

    # Pass EAR path as argument to deploy script
    # Modify below line if your deploy.sh takes different arguments
    bash "$TIBCO_DEPLOY_SCRIPT" "${OLD_EAR_DIR}/${APP_NAME}.ear" 2>&1 | tee -a "$DEPLOY_LOG"

    DEPLOY_EXIT=${PIPESTATUS[0]}

    if [[ $DEPLOY_EXIT -eq 0 ]]; then
        log_ok "Deploy script completed successfully."
    else
        abort "Deploy script failed with exit code: $DEPLOY_EXIT"
    fi
}

# ---- STEP 7: START TIBCO APPLICATION ------------------------
start_application() {
    log_step "STEP 7: Starting TIBCO application..."

    START_SCRIPT_PATH="$TIBCO_BIN/$TIBCO_START_SCRIPT"

    if [[ -f "$START_SCRIPT_PATH" ]]; then
        log_info "Running: $START_SCRIPT_PATH"
        bash "$START_SCRIPT_PATH" 2>&1 | tee -a "$DEPLOY_LOG"
    else
        log_warn "Start script not found at $START_SCRIPT_PATH"
        log_info "Trying systemctl start tibco as fallback..."
        sudo systemctl start tibco 2>&1 | tee -a "$DEPLOY_LOG"
    fi

    if [[ $? -eq 0 ]]; then
        log_ok "TIBCO application started successfully."
    else
        log_fail "Application start may have failed. Please verify manually."
    fi
}

# ---- STEP 8: FINAL SUMMARY ----------------------------------
print_summary() {
    echo ""
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}           DEPLOYMENT SUMMARY                        ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "  App Name        : ${CYAN}$APP_NAME${NC}"
    echo -e "  Old Version     : ${YELLOW}$OLD_VERSION${NC}"
    echo -e "  New Version     : ${GREEN}$VERSION${NC}"
    echo -e "  Deploy Location : ${CYAN}${OLD_EAR_DIR}/${APP_NAME}.ear${NC}"
    echo -e "  Backup Location : ${CYAN}$BACKUP_PATH${NC}"
    echo -e "  Deploy Log      : ${CYAN}$DEPLOY_LOG${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo ""
    log_ok "Deployment DONE: $APP_NAME  OLD:v$OLD_VERSION  NEW:v$VERSION"
}

# ---- MAIN ---------------------------------------------------
print_banner
validate_inputs "$1"
find_old_ear
get_old_version
get_new_version
backup_old_ear
copy_new_ear
run_deploy
start_application
print_summary
