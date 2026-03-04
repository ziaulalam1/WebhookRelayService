import asyncpg
import os

_pool: asyncpg.Pool | None = None


async def init_db_pool() -> None:
    global _pool
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        raise RuntimeError(
            "DATABASE_URL environment variable is not set. "
            "Example: postgres://user:pass@localhost:5432/webhook_relay"
        )
    _pool = await asyncpg.create_pool(dsn, min_size=1, max_size=5)


async def close_db_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    """Return the live connection pool. Raises if called before init_db_pool()."""
    if _pool is None:
        raise RuntimeError("DB pool is not initialized")
    return _pool
