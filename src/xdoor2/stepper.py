import time

from gpiozero import CompositeDevice, OutputDevice
from gpiozero.pins import Factory


class StepperDriver(CompositeDevice):
    """Stepper driver driver"""

    def __init__(
        self,
        pul: int,
        dir: int,
        ena: int,
        step_time: float = 0.002,
        pin_factory: Factory | None = None,
    ) -> None:
        devices = {
            "pul": OutputDevice(pul, initial_value=False),
            "dir": OutputDevice(dir, initial_value=False),
            "ena": OutputDevice(ena, active_high=True, initial_value=False),
        }

        super().__init__(_order=tuple(devices), pin_factory=pin_factory, **devices)

        self.step_time = step_time
        self.position = 0

    def steps(self, steps: int) -> None:
        """Move steps. Negative steps run backwards."""
        if steps == 0:
            return
        self.dir.value = steps > 0
        self.ena.on()
        time.sleep(0.002)
        try:
            for _ in range(abs(steps)):
                self.pul.on()
                time.sleep(self.step_time / 2)
                self.pul.off()
                time.sleep(self.step_time / 2)
                self.position += 1 if steps > 0 else -1
        finally:
            self.pul.off()
            self.ena.off()
