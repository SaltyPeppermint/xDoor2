import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from enum import Enum, auto
from pathlib import Path

from gpiozero import GPIOZeroError

from xdoor2.helpers import DoorAction, ReadLine, WriteLine
from xdoor2.stepper import StepperDriver

log = logging.getLogger(__name__)


class DoorState(Enum):
    LOCKED = auto()
    UNLOCKED = auto()
    MAINTENANCE = auto()


ADMIN_HELP = """Commands:
  move {steps}     run the motor for {steps}, a negative value runs it backwards
  commit           save what this session moved as the travel distance
  edit {steps}     set the travel distance directly
  help             help help help
  exit             leave admin mode"""


class DoorBusy(TimeoutError):
    """Another request held the door for longer than the timeout"""


class PhysicalProblem(Exception):
    """Error during physical door action"""


class DoorMisconfig(Exception):
    """Door was never properly configured and this is bad!"""


class StateMachineIssue(Exception):
    """Door somehow ended up in a broken state machine state!"""


class Door:
    def __init__(self, config: dict, *, distance_file: Path) -> None:
        self._motor = StepperDriver(config["pul_line"], config["dir_line"], config["ena_line"])
        self._distance_file = distance_file
        self._lock = asyncio.Lock()
        self._state = DoorState.LOCKED
        self._distance: int | None = None

    @property
    def state(self) -> DoorState:
        return self._state

    @property
    def actions(self) -> dict[str, DoorAction]:
        return {"open": self.unlock, "close": self.lock, "admin": self.admin}

    async def unlock(self, write: WriteLine, read: ReadLine) -> str:
        async with self._hold():
            log.debug("Starting door unlocking")
            write("Starting door unlocking")
            match self._state:
                case DoorState.LOCKED:
                    await self._move(-self._travel_distance())
                    self._state = DoorState.UNLOCKED
                    return "Door locked!"
                case DoorState.UNLOCKED:
                    return "Door was already unlocked!"
                case DoorState.MAINTENANCE:
                    raise StateMachineIssue("Tried unlocking, but was in maintainance mode")

    async def lock(self, write: WriteLine, read: ReadLine) -> str:
        async with self._hold():
            log.debug("Starting door locking")
            write("Starting door locking")
            match self._state:
                case DoorState.UNLOCKED:
                    await self._move(self._travel_distance())
                    self._state = DoorState.LOCKED
                    return "Door locked!"
                case DoorState.LOCKED:
                    return "Door was already locked!"
                case DoorState.MAINTENANCE:
                    raise StateMachineIssue("Tried locking, but was in maintainance mode")

    async def admin(self, write: WriteLine, read: ReadLine) -> str:
        async with self._hold():
            previous_state = self._state
            self._state = DoorState.MAINTENANCE
            log.info("Admin Mode entered")
            await self._admin_session(write, read)
            log.info("Admin Mode exited")
            self._state = previous_state
        return "Admin mode exited."

    async def _admin_session(self, write: WriteLine, read: ReadLine) -> None:
        """Big dispatch loop for the commands"""
        write("YOU ARE NOW IN ADMIN MODE!")
        write("THIS IS FOR CALIBRATING THE LOCKING MECHANISM!")
        write("THIS CAN EASILY DESTROY PHYSICAL EQUIPMENT!")
        write("LOG OUT UNLESS YOU HAVE READ THE SOURCE CODE *AND* TALKED TO BOTH RONJA AND NICOLE!")
        for line in ADMIN_HELP.splitlines():
            write(line)

        # Movement steps from where the door is now
        traveled = 0
        while True:
            line = await read(300)
            if line is None:
                write("Nothing typed for 300s. You still there buddy?")
                continue

            match line.split():
                case []:
                    continue
                case ["exit"]:
                    return
                case ["help"]:
                    for line in ADMIN_HELP.splitlines():
                        write(line)
                case ["commit"]:
                    if traveled <= 0:
                        write("Nothing moved, nothing to commit.")
                        continue
                    self._set_travel_steps(traveled)
                    write(f"Travel distance is now {traveled}s.")
                case ["edit", value] if (steps := _parse_steps(value)) is not None:
                    if steps <= 0:
                        write("Please give *positive* values for the travel time.")
                        continue
                    self._set_travel_steps(steps)
                    write(f"Travel distance is now {steps}s.")
                case ["edit", *_]:
                    write("Edit requires positive int as second arg")
                case ["move", value] if (steps := _parse_steps(value)) is not None:
                    await self._move(steps)
                    traveled += steps
                    write(f"Moved {steps} steps, {traveled} in total. Use 'commit' to commit it.")
                case ["move", *_]:
                    write("'move' requires a int as second arg. (negative = backwards)")
                case _:
                    write("Unknown command, try 'help'")

    @asynccontextmanager
    async def _hold(self) -> AsyncIterator[None]:
        """Manage the state machine that is the door via the queue, basically a mutex around this"""
        try:
            async with asyncio.timeout(15.0):
                await self._lock.acquire()
        except TimeoutError as exc:
            # Killing acquire() gives the lock to the next one
            # Means we dont have to release anything
            raise DoorBusy from exc
        try:
            yield
        finally:
            self._lock.release()

    async def _move(self, steps: int) -> None:
        if steps == 0:
            return
        try:
            self._motor.steps(steps)
        except GPIOZeroError as exc:
            raise PhysicalProblem(f"motor could not run {steps}") from exc

    def _travel_distance(self) -> int:
        """Ugly hand rolled cache"""
        if self._distance is not None:
            return self._distance

        distance = int(self._distance_file.read_text().strip())
        if distance <= 0:
            raise DoorMisconfig(f"{self._distance_file} holds {distance}, the door is uncalibrated")

        self._distance = distance
        return distance

    def _set_travel_steps(self, distance: int) -> None:
        self._distance_file.write_text(f"{distance}\n")
        self._distance = distance
        log.info(f"travel distance set to {distance}s")


def _parse_steps(value: str) -> int | None:
    try:
        return int(value)
    except ValueError:
        return None
