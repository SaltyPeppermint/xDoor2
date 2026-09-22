import asyncio
import logging
import os
from pathlib import Path

from xdoor2 import helpers, ssh_server
from xdoor2.lock_control import Door
from xdoor2.ssh_keys import KeyStore

log = logging.getLogger(__name__)


async def run(config: dict) -> None:

    log.info("Starting up")

    door = Door(config["gpio"], distance_file=Path(config["storage"]["door_distance_file"]))
    log.info("Door claimed")

    store = KeyStore(config["authorized_keys"], hostname=config["device"]["hostname"])
    store.start()
    log.info("Keystore initialized and running")

    log.info("Starting SSH Server")
    await ssh_server.listen(store, door.actions, config["ssh"])
    await asyncio.Event().wait()


def main() -> None:
    config = helpers.load_config(Path(os.environ["XDOOR_CONFIG"]))
    logging.basicConfig(
        level=config["logging"]["level"], format="%(asctime)s %(levelname)-8s %(name)s: %(message)s"
    )

    asyncio.run(run(config))


if __name__ == "__main__":
    main()
