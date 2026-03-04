from fastapi import APIRouter
from fastapi.responses import JSONResponse

from app.database import get_pool

router = APIRouter()


@router.get("/healthz", include_in_schema=False)
async def healthz():
    """Liveness: returns 200 if the process is alive."""
    return {"status": "ok"}


@router.get("/readyz", include_in_schema=False)
async def readyz():
    """Readiness: returns 200 only if the DB connection pool is up and responsive."""
    try:
        pool = get_pool()
        async with pool.acquire(timeout=2) as conn:
            await conn.fetchval("SELECT 1")
        return {"status": "ok"}
    except Exception as exc:
        return JSONResponse(
            status_code=503,
            content={"status": "error", "detail": str(exc)},
        )
