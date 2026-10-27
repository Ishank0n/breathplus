"""Database connection helper.

All connection details come from environment variables (loaded from a local
.env file in development). Nothing is hardcoded here, so the code can be
committed safely. Never commit the .env file or the CA certificate.
"""
import os

import pymysql
from pymysql.cursors import DictCursor


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def get_connection(autocommit: bool = False) -> pymysql.connections.Connection:
    """Open a TLS-verified connection to MySQL.

    Aiven only accepts encrypted connections, signed by its own CA. Download
    the CA certificate from the Aiven console (service overview page) and point
    DB_SSL_CA at it. Verification is never switched off.
    """
    ca_path = _required("DB_SSL_CA")
    if not os.path.isfile(ca_path):
        raise RuntimeError(f"DB_SSL_CA points to a file that does not exist: {ca_path}")

    return pymysql.connect(
        host=_required("DB_HOST"),
        port=int(os.environ.get("DB_PORT", "3306")),
        user=_required("DB_USER"),
        password=_required("DB_PASSWORD"),
        database=_required("DB_NAME"),
        ssl={"ca": ca_path},
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=autocommit,
        connect_timeout=10,
    )