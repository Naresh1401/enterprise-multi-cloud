"""Alembic environment. ``python -m app.migrate`` signs in, takes the migration lock and
passes its connection here; running the ``alembic`` command against a database is not
supported."""

from alembic import context

from app.db import SCHEMA

connection = context.config.attributes.get("connection")
if connection is None:
    raise RuntimeError(
        "Apply migrations with `python -m app.migrate`, which signs in and takes the lock"
    )

context.configure(connection=connection, version_table_schema=SCHEMA)
with context.begin_transaction():
    context.run_migrations()
