#!/bin/bash
set -e

# === Odoo Backup Script (Docker) FINAL ===

# ----- Colors -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----- Logging functions -----
log_success() { echo -e "${GREEN}[OK] $1${NC}"; }
log_error()   { echo -e "${RED}[FAIL] $1${NC}" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_info()    { echo -e "${BLUE}[INFO] $1${NC}"; }

# ----- Error exit -----
error_exit() {
    log_error "$1"
    exit 1
}

# ----- Spinner -----
start_spinner() {
    local message="$1"
    local pid=$2
    local delay=0.1
    local spinstr='|/-\'

    printf "%s " "$message"
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\b${spinstr:$i:1}"
            sleep $delay
        done
    done
    printf "\b \n"
}

stop_spinner() {
    kill "$SPINNER_PID" > /dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
}

# ----- Select container -----
select_container() {
    local prompt="$1"
    local varname="$2"
    local containers=($(docker ps --format '{{.Names}}'))

    if [ ${#containers[@]} -eq 0 ]; then
        error_exit "No running Docker containers found."
    fi

    echo ""
    echo "$prompt"
    echo ""

    PS3="Select the container (number): "

    select container in "${containers[@]}"; do
        if [[ -n "$container" ]]; then
            log_info "You selected: $container"
            eval "$varname='$container'"
            return
        else
            log_warn "Invalid selection. Try again."
        fi
    done
}

# ----- Select database -----
select_database() {
    local db_container_name="$1"
    local db_user="$2"
    local db_password="$3"
    local varname="$4"

    echo ""
    echo "=== Select the database ==="
    echo ""

    local databases=($(docker exec -e PGPASSWORD="$db_password" "$db_container_name" psql -U "$db_user" -d postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | xargs)) || error_exit "Cannot fetch databases from Postgres."

    if [ ${#databases[@]} -eq 0 ]; then
        error_exit "No databases found."
    fi

    PS3="Select the database (number): "

    select db in "${databases[@]}"; do
        if [[ -n "$db" ]]; then
            log_info "You selected database: $db"
            eval "$varname='$db'"
            return
        else
            log_warn "Invalid selection. Try again."
        fi
    done
}

# ----- Ask for input with default -----
ask_param() {
    local var_name=$1
    local prompt=$2
    local default_value=$3

    read -p "$prompt [$default_value]: " input
    input="${input:-$default_value}"
    eval "$var_name=\"$input\""
}

# ----- Show separator -----
show_bar() {
    echo -e "${BLUE}---------------------------------------------------${NC}"
}

# ----- Main -----

# Capture parameters
DB_USER="$1"
DB_PASSWORD="$2"
ODOO_CONTAINER="$3"
POSTGRES_CONTAINER="$4"
DB_NAME="$5"

# Select containers first
[ -z "$ODOO_CONTAINER" ] && select_container "[ODOO] Select your Odoo container:" ODOO_CONTAINER
[ -z "$POSTGRES_CONTAINER" ] && select_container "[POSTGRES] Select your PostgreSQL container:" POSTGRES_CONTAINER

# Then ask for database user/password
[ -z "$DB_USER" ] && ask_param DB_USER "[USER] PostgreSQL user" "odoo"
[ -z "$DB_PASSWORD" ] && ask_param DB_PASSWORD "[PASS] PostgreSQL password" "odoo"

# Then select database
[ -z "$DB_NAME" ] && select_database "$POSTGRES_CONTAINER" "$DB_USER" "$DB_PASSWORD" DB_NAME

# Show a summary and build the backup command
echo ""
#show_bar
echo "Summary of your selections:"
echo "- Odoo container     : $ODOO_CONTAINER"
echo "- Postgres container : $POSTGRES_CONTAINER"
echo "- Database           : $DB_NAME"
echo "- DB User            : $DB_USER"
#show_bar
echo ""

# Confirm backup
echo "Backup command will:"
echo "- Dump database"
echo "- Copy filestore"
echo "- Save everything to ./backups/<timestamp>/"
echo ""
read -p "[ACTION] Proceed with backup? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_info "Backup cancelled by user."
    exit 0
fi

# Create temp backup directory
FINAL_BACKUP_DIR="./backups/$(date +%Y-%m-%d_%H%M%S)"
TEMP_BACKUP_DIR="$FINAL_BACKUP_DIR/temp"
mkdir -p "$TEMP_BACKUP_DIR/filestore" || error_exit "Failed to create temporary backup directory."

# Backup database (as plain SQL)
log_info "Dumping database $DB_NAME into dump.sql..."
(docker exec -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fp) > "$TEMP_BACKUP_DIR/dump.sql" &
PROCESS_PID=$!
start_spinner "Creating dump.sql..." "$PROCESS_PID"
wait "$PROCESS_PID" || error_exit "Failed to dump database."

#show_bar

# Backup filestore
log_info "Copying filestore from Odoo container..."
(docker cp "$ODOO_CONTAINER:/var/lib/odoo/.local/share/Odoo/filestore/." "$TEMP_BACKUP_DIR/filestore/") &
PROCESS_PID=$!
start_spinner "Copying filestore..." "$PROCESS_PID"
wait "$PROCESS_PID" || error_exit "Failed to copy filestore."

#show_bar
# Create final ZIP
ZIP_FILE="$FINAL_BACKUP_DIR/backup.zip"

log_info "Creating final backup.zip..."
(
    cd "$TEMP_BACKUP_DIR" || error_exit "Cannot access temporary backup directory."
    zip -rq "../backup.zip" .
) || error_exit "Failed to create ZIP archive."

# Clean temp folder
rm -rf "$TEMP_BACKUP_DIR"

log_success "Backup completed successfully!"
log_info "Backup zip is located at: $ZIP_FILE"
echo ""
