import asyncio
import functools
import logging
from collections.abc import Awaitable, Callable

from asyncssh import SSHServerChannel

log = logging.getLogger(__name__)

# Separate timeouts for the lock/unlock action and the queue for the lock
QUEUE_TIMEOUT = 15.0
ACTION_TIMEOUT = 30.0

_door_lock = asyncio.Lock()


class DoorBusy(TimeoutError):
    """Another request held the door for longer than QUEUE_TIMEOUT"""


class DoorStuck(TimeoutError):
    """The mechanism did not finish within ACTION_TIMEOUT"""


def physical_action(
    action: Callable[[SSHServerChannel], Awaitable[str]],
) -> Callable[[SSHServerChannel], Awaitable[str]]:
    """decorator for the door timeout/lock shenanigans"""

    @functools.wraps(action)
    async def wrapper(chan: SSHServerChannel) -> str:
        try:
            async with asyncio.timeout(QUEUE_TIMEOUT):
                await _door_lock.acquire()
        except TimeoutError as exc:
            # Killing acquire() gives the lock to the next one
            # Means we dont have to release anything
            raise DoorBusy from exc

        budget = asyncio.timeout(ACTION_TIMEOUT)
        try:
            async with budget:
                return await action(chan)
        except TimeoutError as exc:
            if not budget.expired():
                raise  # Timeout from inside action
            raise DoorStuck from exc
        finally:
            _door_lock.release()

    return wrapper


@physical_action
async def unlock(chan: SSHServerChannel) -> str:
    log.debug("Starting door unlocking")
    chan.write("Starting door unlocking\r\n")
    await asyncio.sleep(0.5)
    return "Door unlocked."


@physical_action
async def lock(chan: SSHServerChannel) -> str:
    log.debug("Starting door locking")
    chan.write("Starting door locking\r\n")
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
