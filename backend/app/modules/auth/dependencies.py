"""``current_user``: Bearer JWT -> UserDTO (auth spec §7.3). Attached to routers by ``app.main`` at mount time."""

from __future__ import annotations

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.modules.auth.repository import UserAccountRepository
from app.modules.auth.schemas import UserDTO
from app.modules.auth.security import decode_jwt
from app.modules.core import AuthenticationError, Clock, SessionDep, Settings, get_clock, get_settings

_bearer = HTTPBearer(auto_error=False)


async def current_user(
    session: SessionDep,
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    settings: Settings = Depends(get_settings),
    clock: Clock = Depends(get_clock),
) -> UserDTO:
    if credentials is None or credentials.scheme.lower() != "bearer" or not credentials.credentials:
        raise AuthenticationError("Authentication is required.", code="not_authenticated")
    claims = decode_jwt(credentials.credentials, settings.jwt_secret.get_secret_value())
    if claims.exp <= int(clock.now_utc().timestamp()):
        raise AuthenticationError("The access token has expired.", code="token_expired")
    user = await UserAccountRepository(session).get(claims.sub)
    if user is None or claims.ver != user.token_version:
        raise AuthenticationError("The access token is invalid.", code="invalid_token")
    return UserDTO(id=user.id, email=user.email)
