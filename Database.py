# =============================================================================
# database.py — Connection Pool & Context Manager
# =============================================================================
# ARCHITECTURAL ROLE:
#   This module is the ONLY place in the entire application that knows how
#   to talk to MySQL. Every route in app.py borrows a connection from here
#   and returns it when done — the pool handles the lifecycle.
#
# WHY A POOL (not a single persistent connection)?
#   A single shared connection breaks under concurrent requests and silently
#   fails after MySQL's wait_timeout closes idle connections.
#   A pool (mysql.connector.pooling) maintains N ready connections and
#   reuses them across requests — far cheaper than opening a new TCP
#   connection for every HTTP request.
#
# CONNECTION FLOW:
#   Request arrives
#       │
#       ▼
#   get_db_connection()          ← borrows from pool (blocks if pool exhausted)
#       │
#       ▼
#   with get_db_connection() as conn:
#       cursor = conn.cursor(dictionary=True)
#       ...execute SQL...
#       conn.commit() / conn.rollback()
#       │
#       ▼  (context manager __exit__ runs)
#   connection returned to pool  ← even if an exception was raised
# =============================================================================

import os
from contextlib import contextmanager

import mysql.connector
from mysql.connector import pooling, Error as MySQLError
from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# Pool configuration — read once at module import time
# ---------------------------------------------------------------------------
_DB_CONFIG = {
    "host":             os.getenv("DB_HOST",      "localhost"),
    "port":             int(os.getenv("DB_PORT",  "3306")),
    "database":         os.getenv("DB_NAME",      "recruitment_db"),
    "user":             os.getenv("DB_USER",      "root"),
    "password":         os.getenv("DB_PASSWORD",  ""),
    # Return rows as {column: value} dicts instead of plain tuples.
    # This means every cursor.fetchall() is already JSON-serialisable.
    "use_pure":         True,
    # Keep the connection alive across idle periods.
    "connection_timeout": 30,
    "autocommit":       False,   # We manage transactions explicitly
}

_POOL_CONFIG = {
    "pool_name":        "recruitment_pool",
    "pool_size":        int(os.getenv("DB_POOL_SIZE", "5")),
    "pool_reset_session": os.getenv("DB_POOL_RESET_SESSION", "true").lower() == "true",
}

# ---------------------------------------------------------------------------
# Singleton pool — created once when this module is first imported
# ---------------------------------------------------------------------------
try:
    _connection_pool = pooling.MySQLConnectionPool(
        **_POOL_CONFIG,
        **_DB_CONFIG
    )
    print(f"[DB] Connection pool '{_POOL_CONFIG['pool_name']}' "
          f"created (size={_POOL_CONFIG['pool_size']})")
except MySQLError as e:
    # If the pool cannot be created at startup, fail loudly rather than
    # silently serving broken requests later.
    print(f"[DB] FATAL — Could not create connection pool: {e}")
    raise


# ---------------------------------------------------------------------------
# Context manager — the primary interface for all route handlers
# ---------------------------------------------------------------------------
@contextmanager
def get_db_connection():
    """
    Yields a PooledMySQLConnection from the singleton pool.

    Usage (in route handlers):
        with get_db_connection() as conn:
            cursor = conn.cursor(dictionary=True)
            ...

    Guarantees:
      - Connection is always returned to the pool (via finally block),
        even if an exception propagates out of the with-block.
      - autocommit is OFF — callers must explicitly commit or rollback.
    """
    conn = None
    try:
        conn = _connection_pool.get_connection()
        yield conn
    finally:
        # Return to pool regardless of success or failure.
        # If an exception propagated, the pool marks this connection
        # as clean (pool_reset_session=True re-issues SET SESSION vars).
        if conn and conn.is_connected():
            conn.close()   # returns to pool, does NOT close the TCP socket


def get_pool_status():
    """
    Returns diagnostic info about the pool for the /health endpoint.
    mysql-connector-python's pooling API does not expose live counters,
    so we return configuration data as a health signal.
    """
    return {
        "pool_name": _POOL_CONFIG["pool_name"],
        "pool_size": _POOL_CONFIG["pool_size"],
        "host":      _DB_CONFIG["host"],
        "database":  _DB_CONFIG["database"],
    }