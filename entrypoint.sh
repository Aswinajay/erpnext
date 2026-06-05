#!/bin/bash
set -e

SITES_DIR="/home/frappe/frappe-bench/sites"
SITE_NAME="${SITE_NAME:-site1.local}"
SITE_DIR="${SITES_DIR}/${SITE_NAME}"

echo "Starting entrypoint script as root..."

# Ensure frappe user owns the sites directory
chown -R frappe:frappe /home/frappe/frappe-bench/sites

# Wait for PostgreSQL if environment variables are provided
if [ -n "$DB_HOST" ]; then
    echo "Waiting for PostgreSQL ($DB_HOST)..."
    until python3 -c "import socket; s = socket.socket(); s.settimeout(2); s.connect(('$DB_HOST', int('${DB_PORT:-5432}')))" 2>/dev/null; do
        echo "Database offline, retrying..."
        sleep 2
    done
    echo "Database online!"
fi

# Dynamically construct common_site_config.json
echo "Updating common_site_config.json..."
python3 - <<EOF
import json, os
config_path = "$SITES_DIR/common_site_config.json"
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except Exception:
    config = {}

# Set Redis connection strings
redis_url = os.getenv('REDIS_URL', 'redis://127.0.0.1:6379')
config['redis_cache'] = f"{redis_url}/0"
config['redis_queue'] = f"{redis_url}/1"
config['redis_socketio'] = f"{redis_url}/2"

config['socketio_port'] = 9000
config['webserver_port'] = 8000

with open(config_path, 'w') as f:
    json.dump(config, f, indent=4)
EOF
chown frappe:frappe "$SITES_DIR/common_site_config.json"

# Write site_config.json dynamically
echo "Writing site_config.json..."
mkdir -p "${SITE_DIR}"
python3 - <<EOF
import json, os
site_config_path = "$SITE_DIR/site_config.json"
config = {
    "db_name": os.getenv("DB_NAME"),
    "db_user": os.getenv("DB_USER"),
    "db_password": os.getenv("DB_PASSWORD"),
    "db_type": "postgres",
    "db_host": os.getenv("DB_HOST"),
    "db_port": int(os.getenv("DB_PORT", "5432")),
    "encryption_key": os.getenv("ENCRYPTION_KEY", "generate_if_needed")
}
with open(site_config_path, "w") as f:
    json.dump(config, f, indent=4)
EOF
chown -R frappe:frappe "${SITE_DIR}"

# Check if database has been initialized
echo "Checking if database is initialized..."
DATABASE_STATUS=0
python3 - <<EOF
import psycopg2, os, sys
try:
    conn = psycopg2.connect(
        host=os.getenv("DB_HOST"),
        database=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        port=int(os.getenv("DB_PORT", "5432"))
    )
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM information_schema.tables WHERE lower(table_name) = 'tabuser';")
    exists = cur.fetchone()
    cur.close()
    conn.close()
    if exists:
        print("Database already contains tabUser.")
        sys.exit(0)
    else:
        print("Database is empty.")
        sys.exit(1)
except Exception as e:
    print(f"Error/Empty Database: {e}")
    sys.exit(1)
EOF && DATABASE_STATUS=$? || DATABASE_STATUS=$?

if [ "$DATABASE_STATUS" -ne 0 ]; then
    echo "First time setup: Initializing Postgres database..."
    
    # Reinstall site to populate the postgres tables
    su frappe -c "cd /home/frappe/frappe-bench && bench --site ${SITE_NAME} reinstall --yes"
    
    echo "Installing erpnext app on site ${SITE_NAME}..."
    su frappe -c "cd /home/frappe/frappe-bench && bench --site ${SITE_NAME} install-app erpnext"
    
    # Change the administrator password if provided
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "Setting administrator password..."
        su frappe -c "cd /home/frappe/frappe-bench && bench --site ${SITE_NAME} set-admin-password ${ADMIN_PASSWORD}"
    fi
else
    echo "Database is already initialized. Running migrations..."
    su frappe -c "cd /home/frappe/frappe-bench && bench --site ${SITE_NAME} migrate"
fi

echo "Starting Supervisor..."
exec supervisord -c /etc/supervisor/supervisord.conf
