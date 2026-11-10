"""``user_account`` persistence (private to auth)."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.auth.models import UserAccount


class UserAccountRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get(self, user_id: UUID) -> UserAccount | None:
        return await self._session.get(UserAccount, user_id)

    async def get_by_email(self, email: str) -> UserAccount | None:
        stmt = select(UserAccount).where(UserAccount.email == email)
        return (await self._session.execute(stmt)).scalar_one_or_none()

    async def any_user(self) -> UserAccount | None:
        return (await self._session.execute(select(UserAccount).limit(1))).scalar_one_or_none()

    async def insert(self, email: str, password_hash: str) -> UserAccount | None:
        """Insert the owner; ``None`` when a concurrent start won the race (unique violation)."""
        try:
            async with self._session.begin_nested():
                user = UserAccount(email=email, password_hash=password_hash, token_version=1)
                self._session.add(user)
                await self._session.flush()
            return user
        except IntegrityError:
            return None
