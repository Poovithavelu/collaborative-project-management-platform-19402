#!/usr/bin/env bash
# Purpose: Apply all SQL files in schema/ directory in sorted order to the configured Postgres database.
# Usage:
#   1) Ensure environment variables are set (POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_HOST, POSTGRES_PORT)
#      You can place them in a .env file in this directory or source an external file (e.g., db_visualizer/postgres.env).
#   2) Run: ./migrate.sh
#
# Behavior:
#   - Loads environment variables from .env if present, otherwise attempts db_visualizer/postgres.env
#   - Validates that all required variables are set
#   - Applies all schema/*.sql files in lexicographical order using psql
#   - Stops on the first error and prints a clear message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Helpful colors
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

echo -e "${GREEN}== CollabTask Database Migration ==${NC}"

# Load env from common files if present
ENV_LOADED="false"
if [ -f ".env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^\s*#' .env | xargs -0 -I{} bash -lc 'echo "{}"' 2>/dev/null || true)
  echo -e "Loaded environment variables from ${YELLOW}.env${NC}"
  ENV_LOADED="true"
elif [ -f "postgres.env" ]; then
  # Allow a local postgres.env in this directory
  # shellcheck disable=SC1091
  source "postgres.env"
  echo -e "Loaded environment variables from ${YELLOW}postgres.env${NC}"
  ENV_LOADED="true"
elif [ -f "db_visualizer/postgres.env" ]; then
  # shellcheck disable=SC1091
  source "db_visualizer/postgres.env"
  echo -e "Loaded environment variables from ${YELLOW}db_visualizer/postgres.env${NC}"
  ENV_LOADED="true"
fi

if [ "${ENV_LOADED}" = "false" ]; then
  echo -e "${YELLOW}No .env or postgres.env found. Continuing with existing shell environment...${NC}"
fi

# Default host if not provided (many scripts use localhost)
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"

# Validate required variables
REQUIRED_VARS=(POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT)
MISSING=false
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo -e "${RED}Missing required environment variable: ${var}${NC}"
    MISSING=true
  fi
done

if [ "${MISSING}" = "true" ]; then
  echo ""
  echo -e "Please create a ${YELLOW}.env${NC} file in database_supabase/ or export the variables in your shell."
  echo -e "See ${YELLOW}.env.example${NC} for the required variables."
  exit 1
fi

# Check for psql availability
if ! command -v psql >/dev/null 2>&1; then
  echo -e "${RED}psql command not found. Please install PostgreSQL client utilities.${NC}"
  exit 1
fi

# Build connection flags (use PGPASSWORD env var so it is not echoed in the process list)
export PGPASSWORD="${POSTGRES_PASSWORD}"
PSQL_FLAGS=(-h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v "ON_ERROR_STOP=1")

# Verify connectivity before applying migrations
echo -e "${GREEN}Testing database connection...${NC}"
if ! psql "${PSQL_FLAGS[@]}" -c "select version();" >/dev/null; then
  echo -e "${RED}Unable to connect to database with the provided credentials.${NC}"
  echo "  Host: ${POSTGRES_HOST}"
  echo "  Port: ${POSTGRES_PORT}"
  echo "  DB:   ${POSTGRES_DB}"
  echo "  User: ${POSTGRES_USER}"
  exit 1
fi
echo -e "✓ Connection successful"

SCHEMA_DIR="${SCRIPT_DIR}/schema"
if [ ! -d "${SCHEMA_DIR}" ]; then
  echo -e "${RED}Schema directory not found at ${SCHEMA_DIR}${NC}"
  exit 1
fi

# Gather SQL files in sorted order
mapfile -t FILES < <(find "${SCHEMA_DIR}" -maxdepth 1 -type f -name "*.sql" | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo -e "${YELLOW}No .sql files found in schema/. Nothing to apply.${NC}"
  exit 0
fi

echo -e "${GREEN}Applying migrations to ${POSTGRES_DB} on ${POSTGRES_HOST}:${POSTGRES_PORT}...${NC}"
for file in "${FILES[@]}"; do
  base="$(basename "${file}")"
  echo -e "→ Applying ${YELLOW}${base}${NC}"
  # Use -v ON_ERROR_STOP=1 to stop on error and echo the file name for clarity
  if ! psql "${PSQL_FLAGS[@]}" -f "${file}"; then
    echo -e "${RED}✗ Error applying ${base}. Migration halted.${NC}"
    exit 1
  fi
  echo -e "✓ Applied ${GREEN}${base}${NC}"
done

echo -e "${GREEN}All migrations applied successfully.${NC}"
