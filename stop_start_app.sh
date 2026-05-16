#!/bin/bash
# ============================================================
# deploy_manage.sh
# Deployment Stop/Start Script - Sequential SSH Hop
# Author: Shashank Kurapati
# Usage: ./deploy_manage.sh stop|start
# ============================================================

# ─── SERVER IPs ─────────────────────────────────────────────
WEB_SERVERS=("10.0.1.11" "10.0.1.12" "10.0.1.13" "10.0.1.14")
APP_SERVERS=("10.0.2.11" "10.0.2.12" "10.0.2.13" "10.0.2.14")
MQ_SERVERS=("10.0.3.11" "10.0.3.12" "10.0.3.13" "10.0.3.14")
SEARCH_SERVERS=("10.0.4.11" "10.0.4.12" "10.0.4.13")   # SolrCloud nodes
ZK_SERVERS=("10.0.4.11" "10.0.4.12" "10.0.4.13")        # ZooKeeper (same nodes as Solr or separate)

SSH_USER="deployer"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
JUMP_HOST="${WEB_SERVERS[0]}"   # We SSH into Web-1 first, then hop from there

# ─── COLORS ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── LOGGING ────────────────────────────────────────────────
LOG_FILE="/tmp/deploy_manage_$(date +%Y%m%d_%H%M%S).log"
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
log_ok()   { log "${GREEN}[OK]${NC}    $1"; }
log_fail() { log "${RED}[FAIL]${NC}  $1"; }
log_info() { log "${CYAN}[INFO]${NC}  $1"; }
log_step() { log "${YELLOW}[STEP]${NC}  $1"; }

# ─── SSH REMOTE EXEC ─────────────────────────────────────────
# Direct SSH (from your local machine to a server)
run_on() {
    local SERVER=$1
    local CMD=$2
    log_info "Executing on $SERVER: $CMD"
    ssh $SSH_OPTS ${SSH_USER}@${SERVER} "$CMD" >> "$LOG_FILE" 2>&1
    return $?
}

# Hop SSH (login to JUMP_HOST first, then SSH from there to target)
# This is the key concept - we land on Web-1 and jump from there
run_via_jump() {
    local TARGET=$1
    local CMD=$2
    log_info "Hopping via $JUMP_HOST → $TARGET: $CMD"
    ssh $SSH_OPTS ${SSH_USER}@${JUMP_HOST} \
        "ssh $SSH_OPTS ${SSH_USER}@${TARGET} '$CMD'" >> "$LOG_FILE" 2>&1
    return $?
}

# ─── GENERIC START/STOP FOR A LIST OF SERVERS ────────────────
manage_servers() {
    local ACTION=$1       # stop or start
    local LABEL=$2        # WEB / APP / MQ / SOLR / ZK
    local SERVICE=$3      # systemd service name or custom command keyword
    shift 3
    local SERVERS=("$@")

    log_step "─── ${ACTION^^} ${LABEL} SERVERS ───"

    for SERVER in "${SERVERS[@]}"; do
        if [[ "$ACTION" == "stop" ]]; then
            CMD="sudo systemctl stop ${SERVICE} && echo '${SERVICE} stopped on ${SERVER}'"
        else
            CMD="sudo systemctl start ${SERVICE} && echo '${SERVICE} started on ${SERVER}'"
        fi

        # Web-1 (JUMP_HOST) runs directly; all others hop via Web-1
        if [[ "$SERVER" == "$JUMP_HOST" ]]; then
            run_on "$SERVER" "$CMD"
        else
            run_via_jump "$SERVER" "$CMD"
        fi

        if [[ $? -eq 0 ]]; then
            log_ok "${LABEL} ${ACTION} SUCCESS on $SERVER"
        else
            log_fail "${LABEL} ${ACTION} FAILED on $SERVER"
            echo ""
            echo -e "${RED}ERROR: ${ACTION} failed on $SERVER. Check log: $LOG_FILE${NC}"
            echo -e "${YELLOW}Do you want to continue? (y/n):${NC} \c"
            read -r CHOICE
            [[ "$CHOICE" != "y" ]] && { log_info "Aborted by user after failure on $SERVER"; exit 1; }
        fi

        sleep 2   # small gap between servers
    done
}

# ─── STOP SEQUENCE ───────────────────────────────────────────
# Order: WEB → APP → MQ → SOLR → ZooKeeper
do_stop() {
    log_step "════════════════════════════════════"
    log_step "  STARTING STOP SEQUENCE"
    log_step "════════════════════════════════════"

    manage_servers stop "WEB"    "httpd"        "${WEB_SERVERS[@]}"
    manage_servers stop "APP"    "app-service"  "${APP_SERVERS[@]}"
    manage_servers stop "MQ"     "activemq"     "${MQ_SERVERS[@]}"
    manage_servers stop "SOLR"   "solr"         "${SEARCH_SERVERS[@]}"
    manage_servers stop "ZK"     "zookeeper"    "${ZK_SERVERS[@]}"

    log_step "════════════════════════════════════"
    log_ok   "  ALL SERVICES STOPPED SUCCESSFULLY"
    log_step "════════════════════════════════════"
}

# ─── START SEQUENCE ──────────────────────────────────────────
# Order: ZooKeeper → SOLR → MQ → APP → WEB (reverse of stop)
do_start() {
    log_step "════════════════════════════════════"
    log_step "  STARTING START SEQUENCE"
    log_step "════════════════════════════════════"

    manage_servers start "ZK"    "zookeeper"    "${ZK_SERVERS[@]}"

    log_info "Waiting 15s for ZooKeeper to be ready..."
    sleep 15

    manage_servers start "SOLR"  "solr"         "${SEARCH_SERVERS[@]}"

    log_info "Waiting 20s for Solr to be ready..."
    sleep 20

    manage_servers start "MQ"    "activemq"     "${MQ_SERVERS[@]}"
    manage_servers start "APP"   "app-service"  "${APP_SERVERS[@]}"
    manage_servers start "WEB"   "httpd"        "${WEB_SERVERS[@]}"

    log_step "════════════════════════════════════"
    log_ok   "  ALL SERVICES STARTED SUCCESSFULLY"
    log_step "════════════════════════════════════"
}

# ─── MAIN ────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 stop|start"
    exit 1
fi

ACTION=$1

case "$ACTION" in
    stop)
        log_info "Log file: $LOG_FILE"
        log_info "Jump Host: $JUMP_HOST"
        do_stop
        ;;
    start)
        log_info "Log file: $LOG_FILE"
        log_info "Jump Host: $JUMP_HOST"
        do_start
        ;;
    *)
        echo "Invalid option. Use: stop or start"
        exit 1
        ;;
esac

log_info "Full log saved at: $LOG_FILE"
