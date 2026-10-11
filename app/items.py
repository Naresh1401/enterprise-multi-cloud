"""/api/items: a small resource stored in PostgreSQL, to exercise the database end to end."""

import functools
import logging
from collections.abc import Callable
from typing import Any

from flask import Blueprint, jsonify, request
from sqlalchemy import (
    BigInteger,
    Column,
    Connection,
    DateTime,
    Identity,
    MetaData,
    String,
    Table,
    func,
    insert,
    select,
)
from sqlalchemy.exc import InterfaceError, OperationalError

from app import db

log = logging.getLogger(__name__)

MAX_NAME_LENGTH = 100
PAGE_SIZE = 50

# Matches the table that app/migrations creates
metadata = MetaData(schema=db.SCHEMA)
items = Table(
    "items",
    metadata,
    Column("id", BigInteger, Identity(), primary_key=True),
    Column("name", String(MAX_NAME_LENGTH), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
)

bp = Blueprint("items", __name__, url_prefix="/api/items")


def _error(message: str, status: int) -> tuple[Any, int]:
    return jsonify(status="error", error=message), status


def _unavailable() -> tuple[Any, int]:
    # The details go to the log, not to the caller
    log.warning("Database request failed", exc_info=True)
    response, status = _error("database unavailable", 503)
    response.headers["Retry-After"] = "5"
    return response, status


def with_connection(view: Callable[..., Any]) -> Callable[..., Any]:
    """Runs the view with a pooled connection, and answers 503 when the database can't
    be used right now."""

    @functools.wraps(view)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            database = db.get_database()
            if database is None:
                return _error("database not configured", 503)
            connection = database.engine.connect()
        except Exception:
            # Bad settings, a failed sign-in, an unreachable server or a full pool
            return _unavailable()
        with connection:
            try:
                return view(connection, *args, **kwargs)
            except (OperationalError, InterfaceError):
                # The connection dropped, or a query ran past its time limit
                return _unavailable()

    return wrapper


def _item(row: Any) -> dict[str, Any]:
    return {"id": row["id"], "name": row["name"], "created_at": row["created_at"].isoformat()}


@bp.get("")
@with_connection
def list_items(connection: Connection) -> Any:
    query = select(items).order_by(items.c.id.desc()).limit(PAGE_SIZE)
    rows = connection.execute(query).mappings().all()
    return jsonify(items=[_item(row) for row in rows])


@bp.post("")
@with_connection
def create_item(connection: Connection) -> Any:
    payload = request.get_json(silent=True)
    name = payload.get("name") if isinstance(payload, dict) else None
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= MAX_NAME_LENGTH:
        return _error(f"name must be text of 1 to {MAX_NAME_LENGTH} characters", 400)
    statement = insert(items).values(name=name.strip()).returning(*items.c)
    row = connection.execute(statement).mappings().one()
    connection.commit()
    return jsonify(_item(row)), 201


@bp.get("/<int:item_id>")
@with_connection
def get_item(connection: Connection, item_id: int) -> Any:
    row = connection.execute(select(items).where(items.c.id == item_id)).mappings().first()
    if row is None:
        return _error("not found", 404)
    return jsonify(_item(row))
