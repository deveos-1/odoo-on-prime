#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Entrypoint for the Odoo multi-tenant image on Render.com
#
# Responsibilities:
#   1. Resolve DB connection info from Render's injected env vars
#      (DATABASE_URL, or discrete PG* vars from a linked Render Postgres).
#   2. Render /etc/odoo/odoo.conf at container start (so Render env var
#      changes are picked up on every deploy without rebuilding the image).
#   3. Enforce multi-tenant settings: proxy_mode, dbfilter on subdomain,
#      database listing disabled, attachments stored in DB (no persistent
#      disk is available on Render's free web service plan).
#   4. Optionally bootstrap the first tenant database on cold start.
#   5. Exec the requested process (odoo server, shell, or tenant tooling).
# ---------------------------------------------------------------------------
set -euo pipefail

CONF_FILE="/etc/odoo/odoo.conf"
HTTP_PORT="${PORT:-8069}"

# ---- 1. Resolve Postgres connection ---------------------------------------
# Render Postgres exposes a connection string via DATABASE_URL (internal
# host, recommended) when the two services are linked with an env var group
# or a manual fromDatabase reference in render.yaml.
if [ -n "${DATABASE_URL:-}" ]; then
  # postgres://user:password@host:port/dbname
  proto_stripped="${DATABASE_URL#*://}"
  creds="${proto_stripped%%@*}"
  hostpart="${proto_stripped#*@}"
  DB_USER="${creds%%:*}"
  DB_PASSWORD="${creds#*:}"
  hostport="${hostpart%%/*}"
  DB_HOST="${hostport%%:*}"
  DB_PORT="${hostport##*:}"
else
  DB_HOST="${PGHOST:-localhost}"
  DB_PORT="${PGPORT:-5432}"
  DB_USER="${PGUSER:-odoo}"
  DB_PASSWORD="${PGPASSWORD:-odoo}"
fi

ODOO_DBFILTER="${ODOO_DBFILTER:-^%d$}"
ODOO_LIST_DB="${ODOO_LIST_DB:-False}"
ODOO_WORKERS="${ODOO_WORKERS:-0}"
ODOO_MAX_CRON_THREADS="${ODOO_MAX_CRON_THREADS:-1}"
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD:-}"

if [ -z "$ODOO_MASTER_PASSWORD" ]; then
  echo "WARNING: ODOO_MASTER_PASSWORD not set, generating a random one for this container run." >&2
  ODOO_MASTER_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  echo "Generated master password (store it as ODOO_MASTER_PASSWORD env var): $ODOO_MASTER_PASSWORD" >&2
fi

# ---- 2. Render odoo.conf ----------------------------------------------
cat > "$CONF_FILE" <<EOF
[options]
admin_passwd = ${ODOO_MASTER_PASSWORD}
db_host = ${DB_HOST}
db_port = ${DB_PORT}
db_user = ${DB_USER}
db_password = ${DB_PASSWORD}
db_name = False
db_maxconn = ${ODOO_DB_MAXCONN:-16}
dbfilter = ${ODOO_DBFILTER}
list_db = ${ODOO_LIST_DB}
proxy_mode = True
workers = ${ODOO_WORKERS}
max_cron_threads = ${ODOO_MAX_CRON_THREADS}
http_port = ${HTTP_PORT}
http_interface = 0.0.0.0
addons_path = /opt/odoo/addons,/mnt/extra-addons
data_dir = /var/lib/odoo
log_level = ${ODOO_LOG_LEVEL:-info}
limit_memory_soft = ${ODOO_LIMIT_MEMORY_SOFT:-451000000}
limit_memory_hard = ${ODOO_LIMIT_MEMORY_HARD:-512000000}
limit_time_cpu = ${ODOO_LIMIT_TIME_CPU:-60}
limit_time_real = ${ODOO_LIMIT_TIME_REAL:-120}
limit_request = ${ODOO_LIMIT_REQUEST:-2000}
without_demo = all
EOF

echo "Generated odoo.conf:"
grep -v '^admin_passwd' "$CONF_FILE"

# ---- 3. Optional first-boot tenant bootstrap --------------------------
if [ "${1:-}" = "odoo" ] && [ -n "${BOOTSTRAP_TENANT_DB:-}" ]; then
  echo "Checking bootstrap tenant database '${BOOTSTRAP_TENANT_DB}'..."
  python3 /opt/odoo/infra/create_tenant.py --if-missing --name "${BOOTSTRAP_TENANT_DB}" \
    --admin-password "${BOOTSTRAP_TENANT_ADMIN_PASSWORD:-$ODOO_MASTER_PASSWORD}" || \
    echo "Bootstrap tenant creation skipped/failed (continuing to start Odoo)."
fi

# ---- 4. Dispatch -------------------------------------------------------
if [ "${1:-}" = "odoo" ]; then
  shift
  exec python3 /opt/odoo/odoo-bin --config "$CONF_FILE" "$@"
elif [ "${1:-}" = "create-tenant" ]; then
  shift
  exec python3 /opt/odoo/infra/create_tenant.py "$@"
elif [ "${1:-}" = "shell" ]; then
  shift
  exec python3 /opt/odoo/odoo-bin shell --config "$CONF_FILE" "$@"
else
  exec "$@"
fi
