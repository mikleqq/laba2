"""Gateway policies: which routes are public, which need a role, and rate limiting."""

import math
import re
import time
from collections import deque
from typing import Optional

from shopcommon.errors import ForbiddenError, RateLimitError
from shopcommon.security import ROLE_ADMIN, CurrentUser

# (methods, path regex) that can be called without a token.
PUBLIC_ROUTES: list[tuple[set[str], re.Pattern]] = [
    ({"POST"}, re.compile(r"^/api/auth/(register|login)$")),
    ({"GET"}, re.compile(r"^/api/products(/\d+)?$")),
]

# (methods, path regex, required role) - coarse-grained authorization at the edge.
# Fine-grained checks (ownership etc.) are done by the services themselves.
ROLE_ROUTES: list[tuple[set[str], re.Pattern, str]] = [
    ({"POST", "PATCH", "PUT", "DELETE"}, re.compile(r"^/api/products(/.*)?$"), ROLE_ADMIN),
    ({"GET"}, re.compile(r"^/api/users$"), ROLE_ADMIN),
]


def is_public(method: str, path: str) -> bool:
    return any(method in methods and rx.match(path) for methods, rx in PUBLIC_ROUTES)


def authorize(method: str, path: str, user: CurrentUser) -> None:
    for methods, rx, role in ROLE_ROUTES:
        if method in methods and rx.match(path) and user.role != role:
            raise ForbiddenError(f"Role '{role}' required")


class SlidingWindowRateLimiter:
    """In-memory sliding-window limiter (per client). For several gateway replicas use Redis."""

    def __init__(self, limit: int, window_seconds: int) -> None:
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = {}

    def check(self, key: str, now: Optional[float] = None) -> None:
        now = time.monotonic() if now is None else now
        hits = self._hits.setdefault(key, deque())
        while hits and hits[0] <= now - self.window:
            hits.popleft()
        if len(hits) >= self.limit:
            retry_after = max(1, math.ceil(self.window - (now - hits[0])))
            raise RateLimitError(
                f"Rate limit of {self.limit} requests per {self.window}s exceeded",
                headers={"Retry-After": str(retry_after)},
            )
        hits.append(now)
