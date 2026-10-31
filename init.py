"""Create all Breathe tables in MySQL and seed the default breathing techniques.

Safe to run more than once:
  * tables use CREATE TABLE IF NOT EXISTS, so nothing is dropped or altered
  * a technique is only seeded if its slug does not exist yet, and its phases
    are only inserted if it has none, so edits made through the API survive

Usage:
    python init_db.py
"""
from dotenv import load_dotenv

load_dotenv()

from db import get_connection  # noqa: E402  (env must be loaded first)

TABLE_OPTIONS = "ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"

TABLES = [
    (
        "users",
        f"""
        CREATE TABLE IF NOT EXISTS users (
            id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            public_id     CHAR(36)     NOT NULL,
            display_name  VARCHAR(100) NOT NULL,
            email         VARCHAR(255) NULL,
            created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uq_users_public_id (public_id),
            UNIQUE KEY uq_users_email (email)
        ) {TABLE_OPTIONS}
        """,
    ),
    (
        "techniques",
        f"""
        CREATE TABLE IF NOT EXISTS techniques (
            id                    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            slug                  VARCHAR(64)  NOT NULL,
            name                  VARCHAR(100) NOT NULL,
            description           TEXT         NULL,
            default_duration_sec  INT UNSIGNED NOT NULL,
            plant_key             VARCHAR(32)  NULL,
            sort_order            INT UNSIGNED NOT NULL DEFAULT 0,
            is_active             TINYINT(1)   NOT NULL DEFAULT 1,
            created_at            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uq_techniques_slug (slug),
            CONSTRAINT chk_techniques_duration CHECK (default_duration_sec > 0)
        ) {TABLE_OPTIONS}
        """,
    ),
    (
        "technique_phases",
        f"""
        CREATE TABLE IF NOT EXISTS technique_phases (
            id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            technique_id  INT UNSIGNED     NOT NULL,
            step_order    TINYINT UNSIGNED NOT NULL,
            phase         ENUM('inhale', 'hold_in', 'exhale', 'hold_out') NOT NULL,
            duration_sec  DECIMAL(5,2)     NOT NULL,
            UNIQUE KEY uq_phase_step (technique_id, step_order),
            CONSTRAINT fk_phase_technique FOREIGN KEY (technique_id)
                REFERENCES techniques (id) ON DELETE CASCADE,
            CONSTRAINT chk_phase_duration CHECK (duration_sec > 0)
        ) {TABLE_OPTIONS}
        """,
    ),
    (
        "breathing_sessions",
        f"""
        CREATE TABLE IF NOT EXISTS breathing_sessions (
            id                   BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            public_id            CHAR(36)        NOT NULL,
            user_id              BIGINT UNSIGNED NOT NULL,
            technique_id         INT UNSIGNED    NOT NULL,
            status               ENUM('in_progress', 'completed', 'abandoned') NOT NULL DEFAULT 'in_progress',
            target_duration_sec  INT UNSIGNED    NOT NULL,
            elapsed_sec          INT UNSIGNED    NOT NULL DEFAULT 0,
            cycles_completed     INT UNSIGNED    NOT NULL DEFAULT 0,
            accuracy_pct         DECIMAL(5,2)    NULL,
            phase_snapshot       JSON            NOT NULL,
            started_at           DATETIME        NOT NULL,
            completed_at         DATETIME        NULL,
            created_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY uq_sessions_public_id (public_id),
            KEY idx_sessions_user_status_completed (user_id, status, completed_at),
            KEY idx_sessions_user_technique (user_id, technique_id, status),
            KEY idx_sessions_user_started (user_id, started_at),
            CONSTRAINT fk_session_user FOREIGN KEY (user_id)
                REFERENCES users (id) ON DELETE CASCADE,
            CONSTRAINT fk_session_technique FOREIGN KEY (technique_id)
                REFERENCES techniques (id) ON DELETE RESTRICT,
            CONSTRAINT chk_session_accuracy CHECK (accuracy_pct IS NULL OR (accuracy_pct >= 0 AND accuracy_pct <= 100))
        ) {TABLE_OPTIONS}
        """,
    ),
    (
        "user_last_session",
        f"""
        CREATE TABLE IF NOT EXISTS user_last_session (
            user_id       BIGINT UNSIGNED NOT NULL PRIMARY KEY,
            session_id    BIGINT UNSIGNED NOT NULL,
            technique_id  INT UNSIGNED    NOT NULL,
            updated_at    DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            CONSTRAINT fk_last_user FOREIGN KEY (user_id)
                REFERENCES users (id) ON DELETE CASCADE,
            CONSTRAINT fk_last_session FOREIGN KEY (session_id)
                REFERENCES breathing_sessions (id) ON DELETE CASCADE,
            CONSTRAINT fk_last_technique FOREIGN KEY (technique_id)
                REFERENCES techniques (id) ON DELETE CASCADE
        ) {TABLE_OPTIONS}
        """,
    ),
    (
        "breathing_session_readings",
        f"""
        CREATE TABLE IF NOT EXISTS breathing_session_readings (
            id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
            session_id      BIGINT UNSIGNED NOT NULL,
            elapsed_ms      INT UNSIGNED NOT NULL,
            detected_phase  ENUM('inhale', 'hold_in', 'exhale', 'hold_out') NULL,
            confidence      DECIMAL(5,4) NULL,
            sensor_data     JSON NOT NULL,
            expected_phase  ENUM('inhale', 'hold_in', 'exhale', 'hold_out') NOT NULL,
            phase_matched   TINYINT(1) NOT NULL DEFAULT 0,
            received_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY uq_session_elapsed (session_id, elapsed_ms),
            KEY idx_readings_session_time (session_id, elapsed_ms),
            CONSTRAINT fk_readings_session FOREIGN KEY (session_id)
                REFERENCES breathing_sessions (id) ON DELETE CASCADE,
            CONSTRAINT chk_reading_confidence
                CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))
        ) {TABLE_OPTIONS}
        """,
    ),

]

# The five techniques on the home screen. Phase durations are in seconds.
SEED_TECHNIQUES = [
    {
        "slug": "box-breathing",
        "name": "Box Breathing",
        "description": "Equal counts in, hold, out, hold. Steadies the mind under pressure.",
        "default_duration_sec": 300,
        "plant_key": "succulent",
        "sort_order": 10,
        "phases": [("inhale", 4), ("hold_in", 4), ("exhale", 4), ("hold_out", 4)],
    },
    {
        "slug": "4-7-8-calm",
        "name": "4-7-8 Calm",
        "description": "A long hold and slow exhale to wind down before sleep.",
        "default_duration_sec": 240,
        "plant_key": "lavender",
        "sort_order": 20,
        "phases": [("inhale", 4), ("hold_in", 7), ("exhale", 8)],
    },
    {
        "slug": "coherent-breathing",
        "name": "Coherent Breathing",
        "description": "Even, unhurried breaths at about six per minute.",
        "default_duration_sec": 360,
        "plant_key": "shrub",
        "sort_order": 30,
        "phases": [("inhale", 5), ("exhale", 5)],
    },
    {
        "slug": "belly-breathing",
        "name": "Belly Breathing",
        "description": "Deep breaths into the belly with a longer, relaxed exhale.",
        "default_duration_sec": 300,
        "plant_key": "fern",
        "sort_order": 40,
        "phases": [("inhale", 4), ("exhale", 6)],
    },
    {
        "slug": "pursed-lip",
        "name": "Pursed-Lip",
        "description": "Short inhale through the nose, slow exhale through pursed lips.",
        "default_duration_sec": 180,
        "plant_key": "clover",
        "sort_order": 50,
        "phases": [("inhale", 2), ("exhale", 4)],
    },
]


def create_tables(cur) -> None:
    for name, ddl in TABLES:
        cur.execute(ddl)
        print(f"  table ready: {name}")


def seed_techniques(cur) -> None:
    for t in SEED_TECHNIQUES:
        # No-op on duplicate slug, so an existing technique is never overwritten.
        cur.execute(
            """
            INSERT INTO techniques (slug, name, description, default_duration_sec, plant_key, sort_order)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON DUPLICATE KEY UPDATE slug = slug
            """,
            (t["slug"], t["name"], t["description"], t["default_duration_sec"], t["plant_key"], t["sort_order"]),
        )
        cur.execute("SELECT id FROM techniques WHERE slug = %s", (t["slug"],))
        technique_id = cur.fetchone()["id"]

        cur.execute("SELECT COUNT(*) AS n FROM technique_phases WHERE technique_id = %s", (technique_id,))
        if cur.fetchone()["n"]:
            print(f"  technique exists, left unchanged: {t['slug']}")
            continue

        cur.executemany(
            "INSERT INTO technique_phases (technique_id, step_order, phase, duration_sec) VALUES (%s, %s, %s, %s)",
            [(technique_id, i, phase, secs) for i, (phase, secs) in enumerate(t["phases"], start=1)],
        )
        print(f"  technique seeded: {t['slug']}")


def main() -> None:
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT VERSION() AS v")
            print(f"Connected to MySQL {cur.fetchone()['v']}")
            print("Creating tables...")
            create_tables(cur)
            print("Seeding techniques...")
            seed_techniques(cur)
        conn.commit()
        print("Done.")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()