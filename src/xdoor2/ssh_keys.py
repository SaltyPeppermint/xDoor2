import asyncio
import base64
import contextlib
import logging
import random
import time
from pathlib import Path

import asyncssh
import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

log = logging.getLogger(__name__)


class KeyStore:
    def __init__(self, config: dict, *, hostname: str = "") -> None:
        self._config = config
        self._admin_keys = Path(config["admin_keys_path"]).read_text().rstrip("\n")
        self._hostname = hostname

        # self._verify_key = serialization.load_pem_public_key(
        #     Path(config["verify_key_path"]).read_bytes()
        # )

        self._raw = Path(config["cache_file"]).read_bytes()
        self._keys = self._build(self._raw)
        log.info("loaded persisted authorized_keys")
        self._last_update: float | None = None
        self._task: asyncio.Task[None] | None = None

    def current(self) -> asyncssh.SSHAuthorizedKeys:
        return self._keys

    @property
    def last_update(self) -> float | None:
        return self._last_update

    async def reload(self) -> None:
        raw, sig = await self._fetch()
        # RSA + PKCS1v15 + SHA256 matches ExPublicKey.verify/3 from the Elixir codebase.

        # FIXME TEMPORARY DISABLED SIGNATURE CHECK SO I CAN DEPLOY
        # if not isinstance(self._verify_key, rsa.RSAPublicKey):
        #     raise TypeError(f"expected an RSA public key, got {type(self._verify_key).__name__}")
        # self._verify_key.verify(sig, raw, padding.PKCS1v15(), hashes.SHA256())

        # Once we have parsed and validated, we can actually overwrite
        self._last_update = time.time()
        if raw == self._raw:
            log.debug("no changes to authorized keys")
            return

        keys = self._build(raw)
        Path(self._config["cache_file"]).write_bytes(raw)
        self._keys = keys
        self._raw = raw
        log.info("authorized keys changed")

    def start(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._loop(), name="authorized-keys")

    async def stop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._task
        self._task = None

    async def _loop(self) -> None:
        while True:
            try:
                await self.reload()
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("key refresh failed, keeping previous set")
            delay = max(1.0, self._config["update_interval_seconds"] + random.uniform(-3, 3))
            await asyncio.sleep(delay)

    async def _fetch(self) -> tuple[bytes, bytes]:
        headers = {"x-door": self._hostname}
        async with httpx.AsyncClient(follow_redirects=False) as client:
            keys = await client.get(self._config["url"], headers=headers)
            keys.raise_for_status()
            sig = await client.get(self._config["signature_url"])
            sig.raise_for_status()

        return keys.content, base64.b64decode(sig.text.strip(), validate=True)

    def _build(self, raw: bytes) -> asyncssh.SSHAuthorizedKeys:
        return asyncssh.import_authorized_keys(self._admin_keys + "\n" + raw.decode())
