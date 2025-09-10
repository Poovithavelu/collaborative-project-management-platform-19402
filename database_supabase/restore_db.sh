#!/bin/bash

# Universal Database Restore Script
# Automatically detects backup type and restores to running database

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

# SQLite restore
if [ -f "database_backup.db" ] && [ -f "${DB_NAME}" ]; then
    echo "Restoring SQLite database from backup..."
    cp "database_backup.db" "${DB_NAME}"
    echo "✓ Database restored successfully"
    exit 0
fi

# PostgreSQL/MySQL restore from SQL file
if [ -f "database_backup.sql" ]; then
    # Try PostgreSQL
    PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1)
    if [ -n "$PG_VERSION" ]; then
        PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
        if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
            echo "Restoring PostgreSQL database from backup..."
            PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/psql \
                -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} \
                < database_backup.sql 2>/dev/null
            echo "✓ Database restored successfully"
            exit 0
        fi
    fi
    
    # Try MySQL
    if sudo mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; then
        echo "Restoring MySQL database from backup..."
        sudo mysql --socket=/var/run/mysqld/mysqld.sock \
            -u root -p${DB_PASSWORD} < database_backup.sql
        echo "✓ Database restored successfully"
        exit 0
    fi
fi

# MongoDB restore from archive
if [ -f "database_backup.archive" ]; then
    if mongosh --port ${DB_PORT} --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
        echo "Restoring MongoDB database from backup..."
        mongorestore --port ${DB_PORT} --archive=database_backup.archive \
            --drop --quiet
        echo "✓ Database restored successfully"
        exit 0
    fi
fi

echo "ℹ No backup found or database not running"
echo "  Starting with fresh database"
echo ""
echo "Backup files checked:"
echo "  - database_backup.db (SQLite)"
echo "  - database_backup.sql (PostgreSQL/MySQL)"  
echo "  - database_backup.archive (MongoDB)"
exit 0
