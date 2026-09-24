"""JWT auth + role-based access control.

MVP auth issues a dev token for a known username (no password) so the whole path
is demonstrable; a production system swaps the token endpoint for real credential
/ OIDC auth while keeping these dependencies unchanged.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings
from app.enums import Role

_bearer = HTTPBearer(auto_error=False)


@dataclass
class Principal:
    user_id: str
    username: str
    role: Role


def create_access_token(user_id: str, username: str, role: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "username": username,
        "role": role,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=settings.jwt_ttl_seconds)).timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_token(token: str) -> Principal:
    try:
        data = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        return Principal(user_id=data["sub"], username=data["username"], role=Role(data["role"]))
    except (jwt.PyJWTError, KeyError, ValueError) as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token") from exc


async def get_current_principal(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> Principal:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    return decode_token(creds.credentials)


def require_roles(*roles: Role):
    """Dependency factory enforcing that the principal holds one of `roles`."""

    async def _dep(principal: Principal = Depends(get_current_principal)) -> Principal:
        if principal.role not in roles and principal.role != Role.system_admin:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
        return principal

    return _dep
