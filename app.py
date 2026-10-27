"""Breathe API: breathing techniques, users, sessions and "continue last session".

Run:  python app.py      (reads settings from .env, see .env.example)

Security notes
  * Every query is parameterized. The only f-string SQL pieces are fixed,
    whitelisted column names or placeholder lists, never user input.
  * Users are exposed only by a random UUID (public_id), never the
    auto-increment id, so IDs can't be guessed or enumerated.
  * Technique admin endpoints need the X-Admin-Key header (ADMIN_API_KEY).
  * User endpoints are NOT authenticated yet. Anyone with a user's UUID can
    read and write that user's data. Add real auth before going beyond a PoC.
"""
import hmac
import json
import logging
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pymysql
from dotenv import load_dotenv
from flask import Flask, g, jsonify, request

load_dotenv()

from db import get_connection  # noqa: E402  (env must be loaded first)

app = Flask(__name__)
app.json.sort_keys = False
log = logging.getLogger("breathe-api")
logging.basicConfig(level=logging.INFO)

_cors_origins = [o.strip() for o in os.environ.get("CORS_ORIGINS", "").split(",") if o.strip()]
if _cors_origins:
    from flask_cors import CORS

    CORS(app, resources={r"/api/*": {"origins": _cors_origins}})

SESSIONS_PER_STAGE = int(os.environ.get("SESSIONS_PER_STAGE", "10"))
PLANT_STAGES = ("collected", "grown", "flourishing")
PHASE_TYPES = ("inhale", "hold_in", "exhale", "hold_out")
SESSION_STATUSES = ("in_progress", "completed", "abandoned")
MAX_SESSION_SEC = 4 * 60 * 60
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
DUPLICATE_KEY = 1062


# --------------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


@app.errorhandler(ApiError)
def handle_api_error(err):
    return jsonify(error=err.message), err.status


@app.errorhandler(pymysql.MySQLError)
def handle_db_error(err):
    log.exception("Database error")  # full detail goes to logs only
    return jsonify(error="A database error occurred."), 500


@app.errorhandler(404)
def handle_not_found(_err):
    return jsonify(error="Not found."), 404


@app.errorhandler(405)
def handle_bad_method(_err):
    return jsonify(error="Method not allowed."), 405


# --------------------------------------------------------------------------
# DB connection per request
# --------------------------------------------------------------------------
def db():
    if "db" not in g:
        g.db = get_connection()
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    conn = g.pop("db", None)
    if conn is None:
        return
    try:
        conn.rollback()  # discards anything not explicitly committed
    except pymysql.MySQLError:
        pass
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Input helpers
# --------------------------------------------------------------------------
def json_body() -> dict:
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ApiError(400, "Request body must be a JSON object.")
    return data


def parse_uuid(value, label: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError):
        raise ApiError(400, f"{label} must be a valid UUID.")


def get_int(data, key, *, required=False, default=None, min_value=None, max_value=None):
    if data.get(key) is None:
        if required:
            raise ApiError(400, f"'{key}' is required.")
        return default
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApiError(400, f"'{key}' must be an integer.")
    if (min_value is not None and value < min_value) or (max_value is not None and value > max_value):
        raise ApiError(400, f"'{key}' must be between {min_value} and {max_value}.")
    return value


def get_number(data, key, *, required=False, min_value=None, max_value=None):
    if data.get(key) is None:
        if required:
            raise ApiError(400, f"'{key}' is required.")
        return None
    value = data[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ApiError(400, f"'{key}' must be a number.")
    if (min_value is not None and value < min_value) or (max_value is not None and value > max_value):
        raise ApiError(400, f"'{key}' must be between {min_value} and {max_value}.")
    return Decimal(str(value)).quantize(Decimal("0.01"))


def get_str(data, key, *, required=False, max_len=255):
    value = data.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ApiError(400, f"'{key}' is required.")
        return None
    if not isinstance(value, str):
        raise ApiError(400, f"'{key}' must be a string.")
    value = value.strip()
    if len(value) > max_len:
        raise ApiError(400, f"'{key}' must be at most {max_len} characters.")
    return value


def query_int(name, default, min_value, max_value):
    raw = request.args.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        raise ApiError(400, f"Query parameter '{name}' must be an integer.")
    if not min_value <= value <= max_value:
        raise ApiError(400, f"Query parameter '{name}' must be between {min_value} and {max_value}.")
    return value


def parse_timestamp(value, key):
    """Accept ISO-8601 with a timezone; store as naive UTC."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ApiError(400, f"'{key}' must be an ISO-8601 timestamp string.")
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ApiError(400, f"'{key}' must be an ISO-8601 timestamp.")
    if dt.tzinfo is None:
        raise ApiError(400, f"'{key}' must include a timezone, e.g. 2026-10-27T13:09:00Z.")
    return dt.astimezone(timezone.utc).replace(tzinfo=None, microsecond=0)


def utc_now():
    return datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


def require_admin():
    expected = os.environ.get("ADMIN_API_KEY")
    if not expected:
        raise ApiError(403, "Admin endpoints are disabled (ADMIN_API_KEY is not set).")
    provided = request.headers.get("X-Admin-Key", "")
    if not hmac.compare_digest(provided.encode(), expected.encode()):
        raise ApiError(401, "Invalid or missing admin key.")


# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
def iso(dt):
    return None if dt is None else dt.replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def num(value):
    """Decimal/float -> int when whole, else float (so 4.00 shows as 4)."""
    if value is None:
        return None
    value = float(value)
    return int(value) if value.is_integer() else round(value, 2)


def pattern_label(phases):
    return "-".join(str(num(p["duration_sec"])) for p in phases)


def user_json(row):
    return {
        "id": row["public_id"],
        "display_name": row["display_name"],
        "email": row["email"],
        "created_at": iso(row["created_at"]),
    }


def technique_json(row, phases):
    return {
        "id": row["id"],
        "slug": row["slug"],
        "name": row["name"],
        "description": row["description"],
        "pattern": pattern_label(phases),
        "phases": phases,
        "cycle_duration_sec": num(sum(Decimal(str(p["duration_sec"])) for p in phases)),
        "default_duration_sec": row["default_duration_sec"],
        "plant_key": row["plant_key"],
        "sort_order": row["sort_order"],
        "is_active": bool(row["is_active"]),
    }


def session_json(row):
    phases = row["phase_snapshot"]
    if isinstance(phases, (str, bytes)):
        phases = json.loads(phases)
    target, elapsed = row["target_duration_sec"], row["elapsed_sec"]
    return {
        "id": row["public_id"],
        "technique": {
            "id": row["technique_id"],
            "slug": row["technique_slug"],
            "name": row["technique_name"],
            "plant_key": row["technique_plant_key"],
        },
        "status": row["status"],
        "pattern": pattern_label(phases),
        "phases": phases,
        "target_duration_sec": target,
        "elapsed_sec": elapsed,
        "remaining_sec": max(target - elapsed, 0),
        "progress_pct": round(min(elapsed / target, 1) * 100, 1) if target else 0,
        "cycles_completed": row["cycles_completed"],
        "accuracy_pct": num(row["accuracy_pct"]),
        "started_at": iso(row["started_at"]),
        "completed_at": iso(row["completed_at"]),
        "updated_at": iso(row["updated_at"]),
    }


def plant_progress(completed_count):
    """Every SESSIONS_PER_STAGE completed sessions grows the plant one stage.

    0 -> not collected; 1-9 -> collected; 10-19 -> grown; 20+ -> flourishing.
    """
    if completed_count == 0:
        return {"stage": "not_collected", "completed_sessions": 0,
                "progress_to_next": 0, "sessions_per_stage": SESSIONS_PER_STAGE}
    level = min(completed_count // SESSIONS_PER_STAGE, len(PLANT_STAGES) - 1)
    is_final = level == len(PLANT_STAGES) - 1
    return {
        "stage": PLANT_STAGES[level],
        "completed_sessions": completed_count,
        "progress_to_next": None if is_final else completed_count % SESSIONS_PER_STAGE,
        "sessions_per_stage": SESSIONS_PER_STAGE,
    }


# --------------------------------------------------------------------------
# Data access helpers
# --------------------------------------------------------------------------
TECHNIQUE_COLUMNS = "id, slug, name, description, default_duration_sec, plant_key, sort_order, is_active"

SESSION_SELECT = """
    SELECT s.id, s.public_id, s.user_id, s.technique_id, s.status, s.target_duration_sec,
           s.elapsed_sec, s.cycles_completed, s.accuracy_pct, s.phase_snapshot,
           s.started_at, s.completed_at, s.updated_at,
           t.slug AS technique_slug, t.name AS technique_name, t.plant_key AS technique_plant_key
    FROM breathing_sessions s
    JOIN techniques t ON t.id = s.technique_id
"""


def fetch_user(cur, user_id):
    cur.execute(
        "SELECT id, public_id, display_name, email, created_at FROM users WHERE public_id = %s",
        (parse_uuid(user_id, "user_id"),),
    )
    row = cur.fetchone()
    if not row:
        raise ApiError(404, "User not found.")
    return row


def fetch_technique(cur, ref, *, active_only=False):
    """Look up a technique by numeric id or by slug."""
    ref = str(ref).strip().lower()
    if ref.isdigit():
        where, param = "id = %s", int(ref)
    elif SLUG_RE.match(ref):
        where, param = "slug = %s", ref
    else:
        raise ApiError(400, "Technique must be referenced by its numeric id or slug.")
    sql = f"SELECT {TECHNIQUE_COLUMNS} FROM techniques WHERE {where}"
    if active_only:
        sql += " AND is_active = 1"
    cur.execute(sql, (param,))
    row = cur.fetchone()
    if not row:
        raise ApiError(404, "Technique not found.")
    return row


def load_phases(cur, technique_ids):
    result = {tid: [] for tid in technique_ids}
    if not technique_ids:
        return result
    placeholders = ", ".join(["%s"] * len(technique_ids))
    cur.execute(
        f"""SELECT technique_id, step_order, phase, duration_sec FROM technique_phases
            WHERE technique_id IN ({placeholders}) ORDER BY technique_id, step_order""",
        tuple(technique_ids),
    )
    for r in cur.fetchall():
        result[r["technique_id"]].append(
            {"step": r["step_order"], "phase": r["phase"], "duration_sec": num(r["duration_sec"])}
        )
    return result


def validate_phases(raw):
    if not isinstance(raw, list) or not 2 <= len(raw) <= 8:
        raise ApiError(400, "'phases' must be a list of 2 to 8 steps.")
    cleaned = []
    for i, item in enumerate(raw, start=1):
        if not isinstance(item, dict):
            raise ApiError(400, f"phases[{i}] must be an object.")
        if item.get("phase") not in PHASE_TYPES:
            raise ApiError(400, f"phases[{i}].phase must be one of: {', '.join(PHASE_TYPES)}.")
        duration = get_number(item, "duration_sec", required=True, min_value=0.5, max_value=60)
        cleaned.append((i, item["phase"], duration))
    kinds = {phase for _, phase, _ in cleaned}
    if "inhale" not in kinds or "exhale" not in kinds:
        raise ApiError(400, "'phases' must include at least one inhale and one exhale.")
    return cleaned


def insert_phases(cur, technique_id, phases):
    cur.executemany(
        "INSERT INTO technique_phases (technique_id, step_order, phase, duration_sec) VALUES (%s, %s, %s, %s)",
        [(technique_id, step, phase, duration) for step, phase, duration in phases],
    )


def technique_response(cur, technique_id):
    row = fetch_technique(cur, technique_id)
    return technique_json(row, load_phases(cur, [row["id"]])[row["id"]])


def fetch_session(cur, user_row, session_id, *, for_update=False):
    sql = SESSION_SELECT + " WHERE s.public_id = %s AND s.user_id = %s"
    if for_update:
        sql += " FOR UPDATE"
    cur.execute(sql, (parse_uuid(session_id, "session_id"), user_row["id"]))
    row = cur.fetchone()
    if not row:
        raise ApiError(404, "Session not found.")
    return row


def set_last_session(cur, user_db_id, session_db_id, technique_id):
    cur.execute(
        """
        INSERT INTO user_last_session (user_id, session_id, technique_id) VALUES (%s, %s, %s)
        ON DUPLICATE KEY UPDATE session_id = VALUES(session_id),
                                technique_id = VALUES(technique_id),
                                updated_at = CURRENT_TIMESTAMP
        """,
        (user_db_id, session_db_id, technique_id),
    )


def compute_streak(days_desc, today):
    """days_desc: distinct practice dates, newest first. Streak survives until end of the next day."""
    if not days_desc:
        return 0
    expected = today if days_desc[0] == today else today - timedelta(days=1)
    streak = 0
    for d in days_desc:
        if d == expected:
            streak += 1
            expected -= timedelta(days=1)
        elif d < expected:
            break
    return streak


# --------------------------------------------------------------------------
# Health
# --------------------------------------------------------------------------
@app.get("/api/health")
def health():
    cur = db().cursor()
    cur.execute("SELECT 1 AS ok")
    return jsonify(status="ok")


# --------------------------------------------------------------------------
# 1 & 2. Techniques and their phase timings
# --------------------------------------------------------------------------
@app.get("/api/techniques")
def list_techniques():
    include_inactive = request.args.get("include_inactive", "false").lower() == "true"
    cur = db().cursor()
    sql = f"SELECT {TECHNIQUE_COLUMNS} FROM techniques"
    if not include_inactive:
        sql += " WHERE is_active = 1"
    cur.execute(sql + " ORDER BY sort_order, name")
    rows = cur.fetchall()
    phases = load_phases(cur, [r["id"] for r in rows])
    return jsonify(techniques=[technique_json(r, phases[r["id"]]) for r in rows])


@app.get("/api/techniques/<ref>")
def get_technique(ref):
    return jsonify(technique=technique_response(db().cursor(), ref))


@app.post("/api/techniques")
def create_technique():
    require_admin()
    data = json_body()
    slug = get_str(data, "slug", required=True, max_len=64).lower()
    if not SLUG_RE.match(slug) or slug.isdigit():
        raise ApiError(400, "'slug' must be lowercase words joined by hyphens, e.g. 'box-breathing'.")
    name = get_str(data, "name", required=True, max_len=100)
    description = get_str(data, "description", max_len=2000)
    default_duration = get_int(data, "default_duration_sec", required=True, min_value=30, max_value=MAX_SESSION_SEC)
    plant_key = get_str(data, "plant_key", max_len=32)
    sort_order = get_int(data, "sort_order", default=0, min_value=0, max_value=100000)
    phases = validate_phases(data.get("phases"))

    conn = db()
    cur = conn.cursor()
    try:
        cur.execute(
            """INSERT INTO techniques (slug, name, description, default_duration_sec, plant_key, sort_order)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (slug, name, description, default_duration, plant_key, sort_order),
        )
    except pymysql.err.IntegrityError as e:
        if e.args[0] == DUPLICATE_KEY:
            raise ApiError(409, "A technique with this slug already exists.")
        raise
    technique_id = cur.lastrowid
    insert_phases(cur, technique_id, phases)
    conn.commit()
    return jsonify(technique=technique_response(cur, technique_id)), 201


@app.patch("/api/techniques/<ref>")
def update_technique(ref):
    require_admin()
    data = json_body()
    conn = db()
    cur = conn.cursor()
    technique = fetch_technique(cur, ref)

    updates = {}
    if "name" in data:
        updates["name"] = get_str(data, "name", required=True, max_len=100)
    if "description" in data:
        updates["description"] = get_str(data, "description", max_len=2000)
    if "default_duration_sec" in data:
        updates["default_duration_sec"] = get_int(
            data, "default_duration_sec", required=True, min_value=30, max_value=MAX_SESSION_SEC)
    if "plant_key" in data:
        updates["plant_key"] = get_str(data, "plant_key", max_len=32)
    if "sort_order" in data:
        updates["sort_order"] = get_int(data, "sort_order", required=True, min_value=0, max_value=100000)
    if "is_active" in data:
        if not isinstance(data["is_active"], bool):
            raise ApiError(400, "'is_active' must be true or false.")
        updates["is_active"] = int(data["is_active"])
    if not updates:
        raise ApiError(400, "Nothing to update.")

    set_clause = ", ".join(f"{col} = %s" for col in updates)  # keys come from the fixed list above
    cur.execute(f"UPDATE techniques SET {set_clause} WHERE id = %s", (*updates.values(), technique["id"]))
    conn.commit()
    return jsonify(technique=technique_response(cur, technique["id"]))


@app.put("/api/techniques/<ref>/phases")
def replace_phases(ref):
    """Replace a technique's phase timings. Past sessions keep their own snapshot, so history is unaffected."""
    require_admin()
    phases = validate_phases(json_body().get("phases"))
    conn = db()
    cur = conn.cursor()
    technique = fetch_technique(cur, ref)
    cur.execute("DELETE FROM technique_phases WHERE technique_id = %s", (technique["id"],))
    insert_phases(cur, technique["id"], phases)
    conn.commit()  # delete + insert land together or not at all
    return jsonify(technique=technique_response(cur, technique["id"]))


# --------------------------------------------------------------------------
# 3. Users
# --------------------------------------------------------------------------
@app.post("/api/users")
def create_user():
    data = json_body()
    display_name = get_str(data, "display_name", required=True, max_len=100)
    email = get_str(data, "email", max_len=255)
    if email:
        email = email.lower()
        if not EMAIL_RE.match(email):
            raise ApiError(400, "'email' is not a valid email address.")

    conn = db()
    cur = conn.cursor()
    public_id = str(uuid.uuid4())
    try:
        cur.execute(
            "INSERT INTO users (public_id, display_name, email) VALUES (%s, %s, %s)",
            (public_id, display_name, email),
        )
    except pymysql.err.IntegrityError as e:
        if e.args[0] == DUPLICATE_KEY:
            raise ApiError(409, "A user with this email already exists.")
        raise
    conn.commit()
    return jsonify(user=user_json(fetch_user(cur, public_id))), 201


@app.get("/api/users/<user_id>")
def get_user(user_id):
    return jsonify(user=user_json(fetch_user(db().cursor(), user_id)))


# --------------------------------------------------------------------------
# 4. Sessions (every exercise a user starts or completes)
# --------------------------------------------------------------------------
@app.post("/api/users/<user_id>/sessions")
def create_session(user_id):
    """Start a session (status in_progress, the default) or log an already-finished one (status completed).

    Starting a new in-progress session abandons any other in-progress session for the
    user, so "Redo" never leaves a half-finished session behind.
    """
    data = json_body()
    conn = db()
    cur = conn.cursor()
    user = fetch_user(cur, user_id)

    if data.get("technique") is None:
        raise ApiError(400, "'technique' (id or slug) is required.")
    technique = fetch_technique(cur, data["technique"], active_only=True)
    phases = load_phases(cur, [technique["id"]])[technique["id"]]
    if not phases:
        raise ApiError(409, "This technique has no phases configured.")

    status = data.get("status", "in_progress")
    if status not in ("in_progress", "completed"):
        raise ApiError(400, "'status' must be 'in_progress' or 'completed' when creating a session.")
    target = get_int(data, "target_duration_sec", default=technique["default_duration_sec"],
                     min_value=30, max_value=MAX_SESSION_SEC)
    elapsed = get_int(data, "elapsed_sec", default=0, min_value=0, max_value=MAX_SESSION_SEC)
    cycles = get_int(data, "cycles_completed", default=0, min_value=0, max_value=10000)
    accuracy = get_number(data, "accuracy_pct", min_value=0, max_value=100)
    started_at = parse_timestamp(data.get("started_at"), "started_at") or utc_now()
    completed_at = None
    if status == "completed":
        completed_at = parse_timestamp(data.get("completed_at"), "completed_at") or utc_now()
        if completed_at < started_at:
            raise ApiError(400, "'completed_at' cannot be before 'started_at'.")

    snapshot = json.dumps([{"phase": p["phase"], "duration_sec": p["duration_sec"]} for p in phases])

    if status == "in_progress":
        cur.execute(
            "UPDATE breathing_sessions SET status = 'abandoned' WHERE user_id = %s AND status = 'in_progress'",
            (user["id"],),
        )
    public_id = str(uuid.uuid4())
    cur.execute(
        """
        INSERT INTO breathing_sessions
            (public_id, user_id, technique_id, status, target_duration_sec, elapsed_sec,
             cycles_completed, accuracy_pct, phase_snapshot, started_at, completed_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """,
        (public_id, user["id"], technique["id"], status, target, elapsed,
         cycles, accuracy, snapshot, started_at, completed_at),
    )
    set_last_session(cur, user["id"], cur.lastrowid, technique["id"])
    conn.commit()
    return jsonify(session=session_json(fetch_session(cur, user, public_id))), 201


@app.patch("/api/users/<user_id>/sessions/<session_id>")
def update_session(user_id, session_id):
    """Save progress on an in-progress session, or finish it (completed / abandoned)."""
    data = json_body()
    conn = db()
    cur = conn.cursor()
    user = fetch_user(cur, user_id)
    row = fetch_session(cur, user, session_id, for_update=True)
    if row["status"] != "in_progress":
        raise ApiError(409, f"Only in-progress sessions can be updated; this one is {row['status']}.")

    updates = {}
    elapsed = get_int(data, "elapsed_sec", min_value=0, max_value=MAX_SESSION_SEC)
    if elapsed is not None:
        if elapsed < row["elapsed_sec"]:
            raise ApiError(400, "'elapsed_sec' cannot go backwards.")
        updates["elapsed_sec"] = elapsed
    cycles = get_int(data, "cycles_completed", min_value=0, max_value=10000)
    if cycles is not None:
        updates["cycles_completed"] = cycles
    accuracy = get_number(data, "accuracy_pct", min_value=0, max_value=100)
    if accuracy is not None:
        updates["accuracy_pct"] = accuracy

    status = data.get("status")
    if status is not None:
        if status not in SESSION_STATUSES:
            raise ApiError(400, f"'status' must be one of: {', '.join(SESSION_STATUSES)}.")
        updates["status"] = status
        if status == "completed":
            completed_at = parse_timestamp(data.get("completed_at"), "completed_at") or utc_now()
            if completed_at < row["started_at"]:
                raise ApiError(400, "'completed_at' cannot be before 'started_at'.")
            updates["completed_at"] = completed_at
    if not updates:
        raise ApiError(400, "Nothing to update.")

    set_clause = ", ".join(f"{col} = %s" for col in updates)  # keys come from the fixed list above
    cur.execute(f"UPDATE breathing_sessions SET {set_clause} WHERE id = %s", (*updates.values(), row["id"]))
    set_last_session(cur, user["id"], row["id"], row["technique_id"])
    conn.commit()
    return jsonify(session=session_json(fetch_session(cur, user, session_id)))


@app.get("/api/users/<user_id>/sessions")
def list_sessions(user_id):
    """History. Filters: ?status=completed&technique=box-breathing&limit=20&offset=0"""
    cur = db().cursor()
    user = fetch_user(cur, user_id)
    limit = query_int("limit", 20, 1, 100)
    offset = query_int("offset", 0, 0, 1_000_000)

    where, params = ["s.user_id = %s"], [user["id"]]
    status = request.args.get("status")
    if status:
        if status not in SESSION_STATUSES:
            raise ApiError(400, f"'status' must be one of: {', '.join(SESSION_STATUSES)}.")
        where.append("s.status = %s")
        params.append(status)
    if request.args.get("technique"):
        where.append("s.technique_id = %s")
        params.append(fetch_technique(cur, request.args["technique"])["id"])
    where_sql = " AND ".join(where)

    cur.execute(f"SELECT COUNT(*) AS n FROM breathing_sessions s WHERE {where_sql}", tuple(params))
    total = cur.fetchone()["n"]
    cur.execute(
        f"{SESSION_SELECT} WHERE {where_sql} ORDER BY s.started_at DESC, s.id DESC LIMIT %s OFFSET %s",
        (*params, limit, offset),
    )
    return jsonify(total=total, limit=limit, offset=offset,
                   sessions=[session_json(r) for r in cur.fetchall()])


@app.get("/api/users/<user_id>/sessions/<session_id>")
def get_session(user_id, session_id):
    cur = db().cursor()
    user = fetch_user(cur, user_id)
    return jsonify(session=session_json(fetch_session(cur, user, session_id)))


# --------------------------------------------------------------------------
# 5. Last session ("Continue last session" card)
# --------------------------------------------------------------------------
@app.get("/api/users/<user_id>/last-session")
def get_last_session(user_id):
    cur = db().cursor()
    user = fetch_user(cur, user_id)
    cur.execute(SESSION_SELECT + " JOIN user_last_session l ON l.session_id = s.id WHERE l.user_id = %s",
                (user["id"],))
    row = cur.fetchone()
    if not row:
        return jsonify(last_session=None)
    return jsonify(last_session={**session_json(row), "can_continue": row["status"] == "in_progress"})


@app.put("/api/users/<user_id>/last-session")
def put_last_session(user_id):
    """Point the card at a specific session. Body: {"session_id": "<uuid>"}.
    Normally not needed: creating or updating a session already does this."""
    data = json_body()
    conn = db()
    cur = conn.cursor()
    user = fetch_user(cur, user_id)
    if data.get("session_id") is None:
        raise ApiError(400, "'session_id' is required.")
    row = fetch_session(cur, user, data["session_id"])
    set_last_session(cur, user["id"], row["id"], row["technique_id"])
    conn.commit()
    return jsonify(last_session={**session_json(row), "can_continue": row["status"] == "in_progress"})


@app.delete("/api/users/<user_id>/last-session")
def delete_last_session(user_id):
    """Hide the card. Only removes the pointer; the session itself stays in history."""
    conn = db()
    cur = conn.cursor()
    user = fetch_user(cur, user_id)
    cur.execute("DELETE FROM user_last_session WHERE user_id = %s", (user["id"],))
    conn.commit()
    return "", 204


# --------------------------------------------------------------------------
# Extra: what the home screen needs that wasn't in the original list
# --------------------------------------------------------------------------
@app.get("/api/users/<user_id>/techniques")
def list_user_techniques(user_id):
    """Technique list with this user's plant progress ("Collected · 6/10 to grow")."""
    cur = db().cursor()
    user = fetch_user(cur, user_id)
    cur.execute(f"SELECT {TECHNIQUE_COLUMNS} FROM techniques WHERE is_active = 1 ORDER BY sort_order, name")
    rows = cur.fetchall()
    phases = load_phases(cur, [r["id"] for r in rows])
    cur.execute(
        """SELECT technique_id, COUNT(*) AS n, MAX(completed_at) AS last_completed_at
           FROM breathing_sessions WHERE user_id = %s AND status = 'completed'
           GROUP BY technique_id""",
        (user["id"],),
    )
    counts = {r["technique_id"]: r for r in cur.fetchall()}
    result = []
    for r in rows:
        c = counts.get(r["id"])
        progress = plant_progress(c["n"] if c else 0)
        progress["last_completed_at"] = iso(c["last_completed_at"]) if c else None
        result.append({**technique_json(r, phases[r["id"]]), "progress": progress})
    return jsonify(techniques=result)


@app.get("/api/users/<user_id>/summary")
def user_summary(user_id):
    """Streak and totals for the header. Days are counted in UTC for now."""
    cur = db().cursor()
    user = fetch_user(cur, user_id)
    cur.execute(
        """SELECT DISTINCT DATE(completed_at) AS d FROM breathing_sessions
           WHERE user_id = %s AND status = 'completed' ORDER BY d DESC LIMIT 1000""",
        (user["id"],),
    )
    days = [r["d"] for r in cur.fetchall()]
    today = utc_now().date()
    cur.execute(
        """SELECT COUNT(*) AS sessions, COALESCE(SUM(elapsed_sec), 0) AS seconds, AVG(accuracy_pct) AS avg_acc
           FROM breathing_sessions WHERE user_id = %s AND status = 'completed'""",
        (user["id"],),
    )
    totals = cur.fetchone()
    return jsonify(
        user=user_json(user),
        current_streak_days=compute_streak(days, today),
        practiced_today=bool(days) and days[0] == today,
        total_completed_sessions=totals["sessions"],
        total_practice_sec=num(totals["seconds"]),
        average_accuracy_pct=num(totals["avg_acc"]),
    )


if __name__ == "__main__":
    app.run(
        host=os.environ.get("HOST", "127.0.0.1"),
        port=int(os.environ.get("PORT", "5000")),
        debug=os.environ.get("FLASK_DEBUG") == "1",
    )