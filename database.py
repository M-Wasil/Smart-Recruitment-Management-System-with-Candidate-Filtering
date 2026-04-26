# =============================================================================
# database.py — Oracle Connection Pool & Context Manager
# =============================================================================
# KEY DIFFERENCES vs mysql-connector-python:
#
#   Library         : python-oracledb (formerly cx_Oracle, maintained by Oracle)
#                     Thin mode (default): no Oracle Client libraries required.
#                     Thick mode: call oracledb.init_oracle_client() if you
#                     need features like Advanced Queuing or DRCP.
#
#   Pool creation   : oracledb.create_pool() — named parameters min/max/increment
#                     vs mysql's pool_size scalar.
#
#   Connection props: pool.acquire() / pool.release() — explicit acquire/release
#                     OR use the pool as a context manager (pool.acquire() as conn)
#
#   Autocommit      : Oracle connections default to autocommit=False — this
#                     matches our explicit transaction management exactly.
#                     (MySQL also defaults to False when set in pool config.)
#
#   Cursor types    : cursor.rowfactory = oracledb.extras equivalent →
#                     We use a custom rowfactory to return dicts instead of tuples.
#
#   Bind variables  : :param_name or :1, :2  (not %s)
# =============================================================================

import os
from contextlib import contextmanager

import oracledb
from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# Optional: Thick mode initialisation
# Uncomment ONLY if you need Oracle Client features (DRCP, AQ, etc.)
# and have Oracle Instant Client installed.
# ---------------------------------------------------------------------------
# oracledb.init_oracle_client(lib_dir="/opt/oracle/instantclient_21_9")

# ---------------------------------------------------------------------------
# Pool configuration
# ---------------------------------------------------------------------------
_POOL_CONFIG = {
    "user":         os.getenv("ORACLE_USER",     "recruitment"),
    "password":     os.getenv("ORACLE_PASSWORD", ""),
    "dsn":          os.getenv("ORACLE_DSN",      "localhost:1521/XEPDB1"),
    # min: connections created at pool startup (always ready)
    "min":          int(os.getenv("ORACLE_POOL_MIN",       "2")),
    # max: hard ceiling on simultaneous connections
    "max":          int(os.getenv("ORACLE_POOL_MAX",       "5")),
    # increment: how many new connections to open when pool is exhausted
    "increment":    int(os.getenv("ORACLE_POOL_INCREMENT", "1")),
}

# ---------------------------------------------------------------------------
# Singleton pool — created once at module import
# ---------------------------------------------------------------------------
try:
    _pool = oracledb.create_pool(**_POOL_CONFIG)
    print(
        f"[DB] Oracle pool created "
        f"(min={_POOL_CONFIG['min']}, max={_POOL_CONFIG['max']}, "
        f"dsn={_POOL_CONFIG['dsn']})"
    )
except oracledb.Error as e:
    print(f"[DB] FATAL — Could not create Oracle pool: {e}")
    raise


# ---------------------------------------------------------------------------
# Row factory — return dicts instead of bare tuples
# ---------------------------------------------------------------------------
# In mysql-connector we passed dictionary=True to cursor().
# In oracledb, we assign a rowfactory to the cursor after creation.
# This factory is called once per row and receives the column values.
# ---------------------------------------------------------------------------
def _dict_row_factory(cursor):
    """
    Returns a factory function that converts each row tuple into a dict
    keyed by lowercase column names.

    Oracle column names are returned UPPERCASE by default from cursor.description.
    We lowercase them here to match the MySQL column naming convention used
    in our Flask routes and JSON responses.
    """
    col_names = [col[0].lower() for col in cursor.description]
    def make_dict(*args):
        return dict(zip(col_names, args))
    return make_dict


# ---------------------------------------------------------------------------
# Context manager — primary interface for all route handlers
# ---------------------------------------------------------------------------
@contextmanager
def get_db_connection():
    """
    Acquires a connection from the Oracle pool and yields it.

    Usage (in route handlers):
        with get_db_connection() as conn:
            with conn.cursor() as cursor:
                cursor.rowfactory = _dict_row_factory(cursor)  # after execute
                ...

    Guarantees:
      - Connection is always released to the pool (finally block).
      - No implicit commit — callers must call conn.commit() or conn.rollback().
    """
    conn = None
    try:
        conn = _pool.acquire()
        yield conn
    finally:
        if conn:
            # release() returns the connection to the pool without closing
            # the underlying TCP socket.
            _pool.release(conn)


def get_pool_status() -> dict:
    """Returns pool diagnostic info for the /health endpoint."""
    return {
        "dsn":       _POOL_CONFIG["dsn"],
        "pool_min":  _POOL_CONFIG["min"],
        "pool_max":  _POOL_CONFIG["max"],
        "opened":    _pool.opened,   # current open connections
        "busy":      _pool.busy,     # connections currently in use
        "free":      _pool.opened - _pool.busy,
    }
