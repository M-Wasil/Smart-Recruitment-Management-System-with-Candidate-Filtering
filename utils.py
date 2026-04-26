# =============================================================================
# utils.py — Response Helpers (Oracle-aware serialisation)
# =============================================================================
# Oracle-specific serialisation differences vs MySQL version:
#
#   cx_Oracle / oracledb returns:
#     NUMBER(6,2)  → Python float  (already JSON-serialisable ✓)
#     NUMBER       → Python int    (already JSON-serialisable ✓)
#     TIMESTAMP    → Python datetime.datetime (needs .isoformat())
#     DATE         → Python datetime.datetime (same — Oracle DATE has time)
#     CLOB         → oracledb.LOB object  ← must call .read() to get string
#
#   The _sanitise() function below handles all four cases.
# =============================================================================

import datetime
from flask import jsonify

try:
    import oracledb
    _LOB_TYPE = oracledb.LOB
except ImportError:
    _LOB_TYPE = None


def _sanitise(data):
    """
    Recursively convert Oracle-specific Python types to JSON-serialisable ones.

    Handles:
      datetime.datetime / datetime.date → ISO 8601 string
      oracledb.LOB                      → str (reads CLOB content)
      list / dict                       → recursive
    """
    if isinstance(data, list):
        return [_sanitise(item) for item in data]

    if isinstance(data, dict):
        return {key: _sanitise(val) for key, val in data.items()}

    if isinstance(data, (datetime.datetime, datetime.date)):
        return data.isoformat()

    # oracledb.LOB is a streaming object — call .read() to materialise
    if _LOB_TYPE and isinstance(data, _LOB_TYPE):
        return data.read()

    return data


def success_response(data, status_code: int = 200):
    return jsonify({"success": True, "data": _sanitise(data)}), status_code


def error_response(message: str, status_code: int = 400, db_code: int = None):
    body = {"success": False, "error": message, "code": status_code}
    if db_code is not None:
        body["db_code"] = db_code
    return jsonify(body), status_code
