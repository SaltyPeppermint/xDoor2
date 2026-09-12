import asyncio
import functools
import logging
from collections.abc import Awaitable, Callable

from asyncssh import SSHServerChannel

log = logging.getLogger(__name__)

TIMEOUT = 30.0

_door_lock = asyncio.Lock()


def physical_action(
    fn: Callable[[SSHServerChannel], Awaitable[str]],
) -> Callable[[SSHServerChannel], Awaitable[str]]:
    """decorator for the door timeout/lock shenanigans"""

    @functools.wraps(fn)
    async def wrapper(chan: SSHServerChannel) -> str:
        async with asyncio.timeout(TIMEOUT), _door_lock:
            return await fn(chan)

    return wrapper


@physical_action
async def open(chan: SSHServerChannel) -> str:
    log.debug("Starting door unlocking")
    chan.write(f"{'Starting door unlocking'}\r\n")
    await asyncio.sleep(0.5)
    return "Door unlocked."


@physical_action
async def close(chan: SSHServerChannel) -> str:
    log.debug("Starting door locking")
    chan.write(f"{'Starting door locking'}\r\n")
    await asyncio.sleep(0.5)
    return "Door locked!"


@physical_action
async def admin(chan: SSHServerChannel) -> str:
    log.debug("Admin Mode entered")
    chan.write(
        "YOU ARE NOW IN ADMIN MODE!\r\n"
        "THIS IS FOR CALIBRATING THE LOCKING MECHANISM!\r\n"
        "THIS CAN EASILY DESTROY PHYSICAL EQUIPMENT!\r\n"
        "LOG OUT UNLESS YOU HAVE READ THE SOURCE CODE "
        "*AND* TALKED TO BOTH RONJA AND NICOLE!\r\n"
    )
    await asyncio.sleep(0.5)
    return "Admin mode exited."
