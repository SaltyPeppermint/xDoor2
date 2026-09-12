import asyncio
import contextlib
import logging
from collections.abc import Awaitable, Callable

import asyncssh
from asyncssh import SSHServerChannel

import xdoor2.lock_control
from xdoor2.lock_control import ACTION_TIMEOUT, QUEUE_TIMEOUT, DoorBusy, DoorStuck
from xdoor2.ssh_keys import KeyStore

ALLOWED: dict[str, Callable[[SSHServerChannel], Awaitable[str]]] = {
    "open": xdoor2.lock_control.unlock,
    "close": xdoor2.lock_control.lock,
    "admin": xdoor2.lock_control.admin,
}

log = logging.getLogger(__name__)


class DoorSession(asyncssh.SSHServerSession):
    def __init__(self, username: str, peer: str | None) -> None:
        if not peer:
            log.warning("Peer is None")
        self._username = username
        self._peer = peer
        self._chan: asyncssh.SSHServerChannel | None = None
        self._task: asyncio.Task[None] | None = None

    def connection_made(self, chan: asyncssh.SSHServerChannel) -> None:
        self._chan = chan

    def connection_lost(self, exc: Exception | None) -> None:
        # Do not cancel the opening/closing otherwise we get a weird state
        self._chan = None

    def shell_requested(self) -> bool:
        return True

    def session_started(self) -> None:
        self._task = asyncio.create_task(self._run(), name=f"door-{self._username}")

    async def _run(self) -> None:
        if self._chan is None:
            log.info(f"{self._username} from {self._peer} disappeared before doing anything")
            return

        log.info(f"{self._username} requested by {self._peer}")
        code = 1
        message = "failed"

        try:
            result = await ALLOWED[self._username](self._chan)
        except DoorBusy:
            log.warning(f"{self._username} waited {QUEUE_TIMEOUT}s for the door ({self._peer})")
            message = "Someone else is interfacing with the door."
        except DoorStuck:
            log.error(f"{self._username} did not finish in {ACTION_TIMEOUT}s ({self._peer})")
            message = "Door mechanism did not finish in time. This is worrying! Ask Ronja or Nicole"
        except Exception:
            log.exception(f"{self._username} failed for {self._peer}")
        else:
            log.info(f"{self._username} succeeded for {self._peer}")
            code, message = 0, result
        finally:
            self._finish(code, message)

    def _finish(self, code: int, message: str) -> None:
        chan = self._chan
        if chan is None:
            return
        with contextlib.suppress(OSError):
            chan.write(f"{message}\r\n")
            chan.exit(code)


class DoorServer(asyncssh.SSHServer):
    def __init__(self, keystore: KeyStore, greeting: str) -> None:
        self._keystore = keystore
        self._peer = None
        self._greeting = greeting
        self._conn: asyncssh.SSHServerConnection | None = None

    def connection_made(self, conn: asyncssh.SSHServerConnection) -> None:
        self._conn = conn
        peername = conn.get_extra_info("peername")
        self._peer = peername[0] if peername else None

    def begin_auth(self, username: str) -> bool:
        assert self._conn is not None
        if username in ALLOWED:
            self._conn.send_auth_banner(self._greeting)
        else:
            # No keys means no public key can validate means auth fails.
            log.warning(f"auth attempt for unknown user {username!r} from {self._peer}")
            self._conn.set_authorized_keys(None)
            return True
        self._conn.set_authorized_keys(self._keystore.current())
        return True  # WE always require auth so we return true!

    def public_key_auth_supported(self) -> bool:
        return True

    def kbdint_auth_supported(self) -> bool:
        return False

    def password_auth_supported(self) -> bool:
        return False

    def session_requested(self) -> asyncssh.SSHServerSession:
        assert self._conn is not None
        return DoorSession(self._conn.get_extra_info("username"), self._peer)


async def listen(keystore: KeyStore, config: dict, greeting: str) -> asyncssh.SSHAcceptor:
    return await asyncssh.listen(
        host=config["listen_address"],
        port=config["port"],
        server_factory=lambda: DoorServer(keystore, greeting),
        server_host_keys=[config["host_key"]],
        login_timeout=20,
        keepalive_interval=15,
        keepalive_count_max=3,
        x11_forwarding=False,
        agent_forwarding=False,
    )
