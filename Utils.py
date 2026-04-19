# =============================================================================
# utils.py — Response Helpers & Error Formatting
# =============================================================================
# Centralising JSON response construction here means every route returns
# a consistent envelope shape. The frontend can always rely on:
#
#   Success:  { "success": true,  "data": <payload> }
#   Error:    { "success": false, "error": "<message>", "code": <int> }
#
# The "thin layer" principle: this file contains the ONLY non-SQL logic
# allowed in the application — serialisation and HTTP response shaping.
# =============================================================================

import decimal
import datetime
from flask import jsonify


# ---------------------------------------------------------------------------
# Custom JSON serialiser
# ---------------------------------------------------------------------------
# mysql-connector-python returns:
#   - DECIMAL columns as Python decimal.Decimal  → not JSON-serialisable
#   - DATE/DATETIME columns as datetime objects  → not JSON-serialisable
# This encoder converts both to standard Python types before jsonify runs.
# ---------------------------------------------------------------------------
class _RecruitmentJSONEncoder:
    """Not a subclass of JSONEncoder — Flask 3.x uses a provider pattern."""

    @staticmethod
    def default(obj):
        if isinstance(obj, decimal.Decimal):
            # Preserve numeric fidelity; the JS client receives a number.
            return float(obj)
        if isinstance(obj, (datetime.datetime, datetime.date)):
            # ISO 8601 string — universally parseable by JS Date().
            return obj.isoformat()
        raise TypeError(f"Object of type {type(obj)} is not JSON serialisable")


def _sanitise(data):
    """
    Recursively walk dicts/lists and convert non-serialisable types.
    Called before passing any DB result to jsonify().
    """
    if isinstance(data, list):
        return [_sanitise(item) for item in data]
    if isinstance(data, dict):
        return {
            key: _RecruitmentJSONEncoder.default(val)
                 if isinstance(val, (decimal.Decimal, datetime.datetime, datetime.date))
                 else val
            for key, val in data.items()
        }
    return data


# ---------------------------------------------------------------------------
# Response envelope constructors
# ---------------------------------------------------------------------------
def success_response(data, status_code: int = 200):
    """
    Wraps a payload in the standard success envelope.

    Args:
        data        : list, dict, or scalar — the query result
        status_code : HTTP status code (default 200)

    Returns:
        Flask Response with Content-Type: application/json
    """
    return jsonify({
        "success": True,
        "data":    _sanitise(data)
    }), status_code


def error_response(message: str, status_code: int = 400, db_errno: int = None):
    """
    Wraps an error message in the standard error envelope.

    Args:
        message     : Human-readable error description
        status_code : HTTP status code
        db_errno    : Optional MySQL errno for debugging (stripped in prod)

    Returns:
        Flask Response with Content-Type: application/json
    """
    body = {
        "success": False,
        "error":   message,
        "code":    status_code,
    }
    # Surface the MySQL custom errno (45001, 45002, 45003) during development
    # so the frontend can display domain-specific messages.
    if db_errno is not None:
        body["db_errno"] = db_errno
    return jsonify(body), status_code