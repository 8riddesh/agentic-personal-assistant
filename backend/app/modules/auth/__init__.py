"""Public interface of ``auth`` (spec §2). Only ``app.main`` imports this module (it attaches ``current_user``)."""

from app.modules.auth.dependencies import current_user
from app.modules.auth.schemas import LoginRequest, TokenDTO, UserDTO
from app.modules.auth.service import AuthService, get_auth_service

__all__ = ["AuthService", "LoginRequest", "TokenDTO", "UserDTO", "current_user", "get_auth_service"]
