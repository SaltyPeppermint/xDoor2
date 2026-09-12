import asyncio
import functools
import logging
from collections.abc import Awaitable, Callable

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
    action: Callable[[Callable[[str], None]], Awaitable[str]],
) -> Callable[[Callable[[str], None]], Awaitable[str]]:
    """decorator for the door timeout/lock shenanigans"""

    @functools.wraps(action)
    async def wrapper(notify: Callable[[str], None]) -> str:
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
                return await action(notify)
        except TimeoutError as exc:
            if not budget.expired():
                raise  # Timeout from inside action
            raise DoorStuck from exc
        finally:
            _door_lock.release()

    return wrapper


@physical_action
async def unlock(write: Callable[[str], None]) -> str:
    log.debug("Starting door unlocking")
    write("Starting door unlocking")
    await asyncio.sleep(0.5)
    return "Door unlocked."


@physical_action
async def lock(write: Callable[[str], None]) -> str:
    log.debug("Starting door locking")
    write("Starting door locking")
    await asyncio.sleep(0.5)
    return "Door locked!"


@physical_action
async def admin(write: Callable[[str], None]) -> str:
    log.debug("Admin Mode entered")
    write("YOU ARE NOW IN ADMIN MODE!")
    write("THIS IS FOR CALIBRATING THE LOCKING MECHANISM!")
    write("THIS CAN EASILY DESTROY PHYSICAL EQUIPMENT!")
    write("LOG OUT UNLESS YOU HAVE READ THE SOURCE CODE *AND* TALKED TO BOTH RONJA AND NICOLE!")
    await asyncio.sleep(0.5)
    return "Admin mode exited."
