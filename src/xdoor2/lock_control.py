import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from enum import Enum, auto
from pathlib import Path

from gpiozero import GPIOZeroError, PhaseEnableMotor

from xdoor2.helpers import DoorAction, ReadLine, WriteLine

log = logging.getLogger(__name__)


class DoorState(Enum):
    LOCKED = auto()
    UNLOCKED = auto()
    MAINTENANCE = auto()


ADMIN_HELP = """Commands:
  move {seconds}   run the motor for {seconds}, a negative value runs it backwards
  commit           save what this session moved as the travel distance
  edit {seconds}   set the travel distance directly
  help             help help help
  exit             leave admin mode"""


class DoorBusy(TimeoutError):
    """Another request held the door for longer than the timeout"""


class PhysicalProblem(Exception):
    """Error during physical door action"""


class DoorMisconfig(Exception):
    """Door was never properly configured and this is bad!"""


class Door:
    def __init__(self, config: dict, *, distance_file: Path) -> None:
        self._motor = PhaseEnableMotor(config["phase_line"], config["enable_line"])
        self._distance_file = distance_file
        self._lock = asyncio.Lock()
        self._state = DoorState.LOCKED
        self._distance: float | None = None

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
            await self._move(-self._travel_seconds())
            await asyncio.sleep(0.5)
            self._state = DoorState.UNLOCKED
        return "Door unlocked!"

    async def lock(self, write: WriteLine, read: ReadLine) -> str:
        async with self._hold():
            log.debug("Starting door locking")
            write("Starting door locking")
            await self._move(self._travel_seconds())
            await asyncio.sleep(0.5)
            self._state = DoorState.LOCKED
        return "Door locked!"

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

        # Movement seconds from where the door is now
        traveled = 0.0
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
                    self._set_travel_seconds(traveled)
                    write(f"Travel distance is now {traveled}s.")
                case ["edit", value] if (seconds := _parse_seconds(value)) is not None:
                    if seconds <= 0:
                        write("Please give *positive* values for the travel time.")
                        continue
                    self._set_travel_seconds(seconds)
                    write(f"Travel distance is now {seconds}s.")
                case ["edit", *_]:
                    write("Edit requires positive floats as second arg")
                case ["move", value] if (seconds := _parse_seconds(value)) is not None:
                    await self._move(seconds)
                    traveled += seconds
                    write(f"Moved {seconds}s, {traveled}s in total. Use 'commit' to commit it.")
                case ["move", *_]:
                    write("'move' requires a float as second arg. (negative = backwards)")
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

    async def _move(self, seconds: float) -> None:
        if seconds == 0:
            return
        try:
            if seconds > 0:
                self._motor.forward()
            else:
                self._motor.backward()
            await asyncio.sleep(abs(seconds))
            self._motor.stop()
        except GPIOZeroError as exc:
            raise PhysicalProblem(f"motor could not run for {seconds}s") from exc

    def _travel_seconds(self) -> float:
        """Ugly hand rolled cache"""
        if self._distance is not None:
            return self._distance

        distance = float(self._distance_file.read_text().strip())
        if distance <= 0:
            raise DoorMisconfig(f"{self._distance_file} holds {distance}, the door is uncalibrated")

        self._distance = distance
        return distance

    def _set_travel_seconds(self, distance: float) -> None:
        self._distance_file.write_text(f"{distance}\n")
        self._distance = distance
        log.info(f"travel distance set to {distance}s")


def _parse_seconds(value: str) -> float | None:
    try:
        return float(value)
    except ValueError:
        return None
