import asyncio
import contextlib
import logging

import asyncssh

from xdoor2.helpers import DoorAction, WriterGone
from xdoor2.lock_control import DoorBusy, DoorMisconfig, PhysicalProblem
from xdoor2.ssh_keys import KeyStore

log = logging.getLogger(__name__)


class DoorSession(asyncssh.SSHServerSession):
    def __init__(self, username: str, action: DoorAction, peer: str | None) -> None:
        if not peer:
            log.warning("Peer is None")
        self._username = username
        self._action = action
        self._peer = peer
        self._chan: asyncssh.SSHServerChannel | None = None
        self._task: asyncio.Task[None] | None = None
        self._input: asyncio.Queue[str | None] = asyncio.Queue()
        self._buf = ""
        self._eof = False

    def connection_made(self, chan: asyncssh.SSHServerChannel) -> None:
        self._chan = chan

    def connection_lost(self, exc: Exception | None) -> None:
        # Do not cancel the opening/closing otherwise we get a weird state
        self._chan = None
        self._input.put_nowait(None)  # unblock anyone waiting

    def shell_requested(self) -> bool:
        return True

    def session_started(self) -> None:
        self._task = asyncio.create_task(self._run(), name=f"door-{self._username}")

    def data_received(self, data: str, datatype: asyncssh.DataType) -> None:
        self._input.put_nowait(data)

    def eof_received(self) -> bool:
        self._input.put_nowait(None)
        return True

    async def _read_line(self, timeout: float | None = 30) -> str | None:
        try:
            async with asyncio.timeout(timeout):
                while True:
                    nl = self._buf.find("\n")
                    if nl >= 0:
                        line, self._buf = self._buf[:nl], self._buf[nl + 1 :]
                        return line.rstrip("\r")
                    if self._eof:
                        raise WriterGone
                    chunk = await self._input.get()
                    if chunk is None:
                        self._eof = True
                    else:
                        self._buf += chunk
        except TimeoutError:
            return None

    async def _run(self) -> None:
        if self._chan is None:
            log.info(f"{self._username} from {self._peer} disappeared before doing anything")
            return

        log.info(f"{self._username} requested by {self._peer}")
        code = 1
        message = "failed"

        # TODO: Type inference somehow fails if I dont bind it
        chan = self._chan
        try:
            result = await self._action(lambda line: self._write_line(chan, line), self._read_line)
        except DoorBusy:
            log.warning(f"{self._username} had a timeout waiting for the door ({self._peer})")
            message = "Someone else is interfacing with the door."
        except PhysicalProblem:
            log.error(f"{self._username} resulted in physical malfunction ({self._peer})")
            message = "Door mechanism had a physical malfunction. This is bad! Ask Ronja or Nicole"
        except DoorMisconfig:
            log.error(f"{self._username} hit a misconfigured door ({self._peer})")
            message = "The door configured wrong. This can be fixed in admin mode but please mode ask Ronja or Nicole"
        except WriterGone:
            log.info(f"{self._username} disconnected mid action ({self._peer})")
            message = "Client disconnected."
        except Exception:
            log.exception(f"{self._username} failed for {self._peer}")
        else:
            log.info(f"{self._username} succeeded for {self._peer}")
            code, message = 0, result
        finally:
            self._finish(code, message)

    @staticmethod
    def _write_line(chan: asyncssh.SSHServerChannel, line: str) -> None:
        # A client that vanished mid-action must not abort the door action
        with contextlib.suppress(OSError):
            chan.write(f"{line}\r\n")

    def _finish(self, code: int, message: str) -> None:
        if self._chan is None:
            return
        self._write_line(self._chan, message)
        with contextlib.suppress(OSError):
            self._chan.exit(code)


class DoorServer(asyncssh.SSHServer):
    def __init__(self, keystore: KeyStore, actions: dict[str, DoorAction], greeting: str) -> None:
        self._keystore = keystore
        self._actions = actions
        self._peer = None
        self._greeting = greeting
        self._conn: asyncssh.SSHServerConnection | None = None

    def connection_made(self, conn: asyncssh.SSHServerConnection) -> None:
        self._conn = conn
        peername = conn.get_extra_info("peername")
        self._peer = peername[0] if peername else None

    def begin_auth(self, username: str) -> bool:
        assert self._conn is not None
        if username in self._actions:
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
        username = self._conn.get_extra_info("username")
        return DoorSession(username, self._actions[username], self._peer)


async def listen(
    keystore: KeyStore, actions: dict[str, DoorAction], config: dict, greeting: str
) -> asyncssh.SSHAcceptor:
    return await asyncssh.listen(
        host=config["listen_address"],
        port=config["port"],
        server_factory=lambda: DoorServer(keystore, actions, greeting),
        server_host_keys=[config["host_key"]],
        login_timeout=20,
        keepalive_interval=15,
        keepalive_count_max=3,
        x11_forwarding=False,
        agent_forwarding=False,
    )
