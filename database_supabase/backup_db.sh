#!/bin/bash

# Universal Database Backup Script
# Automatically detects and backs up the running database

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

# SQLite check and backup
if [ -f "${DB_NAME}" ]; then
    echo "Backing up SQLite database..."
    cp "${DB_NAME}" "database_backup.db"
    echo "✓ Backup saved to database_backup.db"
    exit 0
fi

# PostgreSQL check and backup
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1)
if [ -n "$PG_VERSION" ]; then
    PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "Backing up PostgreSQL database..."
        PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/pg_dump \
            -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} \
            --clean --if-exists > database_backup.sql
        echo "✓ Backup saved to database_backup.sql"
        exit 0
    fi
fi

# MySQL check and backup
if sudo mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; then
    echo "Backing up MySQL database..."
    sudo mysqldump --socket=/var/run/mysqld/mysqld.sock \
        -u root -p${DB_PASSWORD} \
        --databases ${DB_NAME} --add-drop-database \
        --routines --triggers > database_backup.sql
    echo "✓ Backup saved to database_backup.sql"
    exit 0
fi

# MongoDB check and backup
if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
    echo "Backing up MongoDB database..."
    mongodump --port ${DB_PORT} --db ${DB_NAME} \
        --archive=database_backup.archive --quiet
    echo "✓ Backup saved to database_backup.archive"
    exit 0
fi

echo "⚠ No running database detected"
echo "Make sure your database is running before creating a backup"
exit 1
