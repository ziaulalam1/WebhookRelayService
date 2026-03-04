from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.database import init_db_pool, close_db_pool
from app.health import router as health_router
from app.webhooks import router as webhook_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db_pool()
    yield
    await close_db_pool()


app = FastAPI(title="Webhook Relay & Event Inbox", lifespan=lifespan)

app.include_router(health_router)
app.include_router(webhook_router)
