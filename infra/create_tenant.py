#!/usr/bin/env python3
"""Tenant provisioning tool for the multi-tenant Odoo deployment on Render.

Each tenant is a separate PostgreSQL database on the same shared Postgres
instance. Odoo's ``dbfilter = ^%d$`` routes incoming requests to the right
database based on the subdomain (e.g. ``acme.yourdomain.com`` -> db ``acme``).

Usage (inside the running container, e.g. via Render Shell):

    python3 infra/create_tenant.py --name acme --admin-password 'Str0ngPass!'

Flags:
    --name              Tenant / database name (also the expected subdomain).
    --admin-password    Password for the tenant's Odoo admin user.
    --if-missing        Do nothing (exit 0) if the database already exists.
    --demo               Load demo data (off by default).
"""
import argparse
import os
import secrets
import subprocess
import sys

import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT


def get_connection_params():
    database_url = os.environ.get("DATABASE_URL")
    if database_url:
        proto_stripped = database_url.split("://", 1)[1]
        creds, hostpart = proto_stripped.split("@", 1)
        user, password = creds.split(":", 1)
        hostport = hostpart.split("/", 1)[0]
        if ":" in hostport:
            host, port = hostport.split(":", 1)
        else:
            host, port = hostport, "5432"
        return {"host": host, "port": port, "user": user, "password": password}
    return {
        "host": os.environ.get("PGHOST", "localhost"),
        "port": os.environ.get("PGPORT", "5432"),
        "user": os.environ.get("PGUSER", "odoo"),
        "password": os.environ.get("PGPASSWORD", "odoo"),
    }


def database_exists(conn_params, name):
    conn = psycopg2.connect(dbname="postgres", **conn_params)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,))
            return cur.fetchone() is not None
    finally:
        conn.close()


def create_database(conn_params, name):
    conn = psycopg2.connect(dbname="postgres", **conn_params)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    try:
        with conn.cursor() as cur:
            cur.execute(f'CREATE DATABASE "{name}" ENCODING \'unicode\' TEMPLATE template0')
    finally:
        conn.close()


def init_odoo_database(name, admin_password, demo):
    cmd = [
        sys.executable, "/opt/odoo/odoo-bin",
        "--config", "/etc/odoo/odoo.conf",
        "-d", name,
        "-i", "base",
        "--stop-after-init",
        "--max-cron-threads=0",
    ]
    if not demo:
        cmd.append("--without-demo=all")
    subprocess.run(cmd, check=True)

    # Set admin password + force attachments into the DB (no persistent
    # disk on Render's free plan, so the filesystem filestore is ephemeral).
    shell_code = (
        "env = odoo.api.Environment(cr, odoo.SUPERUSER_ID, {});"
        "user = env.ref('base.user_admin');"
        f"user.write({{'password': {admin_password!r}}});"
        "env['ir.config_parameter'].set_param('ir_attachment.location', 'db');"
        "cr.commit()"
    )
    subprocess.run(
        [
            sys.executable, "/opt/odoo/odoo-bin", "shell",
            "--config", "/etc/odoo/odoo.conf",
            "-d", name,
            "--no-http",
        ],
        input=shell_code.encode(),
        check=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True, help="Tenant / database name")
    parser.add_argument("--admin-password", default=None)
    parser.add_argument("--if-missing", action="store_true")
    parser.add_argument("--demo", action="store_true")
    args = parser.parse_args()

    conn_params = get_connection_params()
    exists = database_exists(conn_params, args.name)

    if exists:
        if args.if_missing:
            print(f"Tenant database '{args.name}' already exists, skipping.")
            return
        print(f"ERROR: database '{args.name}' already exists.", file=sys.stderr)
        sys.exit(1)

    admin_password = args.admin_password or secrets.token_urlsafe(16)
    print(f"Creating tenant database '{args.name}'...")
    create_database(conn_params, args.name)
    print("Initializing Odoo (base module)...")
    init_odoo_database(args.name, admin_password, args.demo)
    print(f"Tenant '{args.name}' ready. Admin login: admin / {admin_password}")
    print(f"Point the subdomain '{args.name}.<your-domain>' to this Render service "
          f"so dbfilter (^%d$) can route requests to this database.")


if __name__ == "__main__":
    main()
