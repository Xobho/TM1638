from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class Config:
    raw: dict

    @staticmethod
    def load(path: str) -> "Config":
        p = Path(path)
        if not p.exists():
            raise FileNotFoundError(
                f"{path} not found. Copy config.example.yaml to config.yaml and edit it."
            )
        with p.open() as f:
            return Config(raw=yaml.safe_load(f))

    @property
    def mt5(self) -> dict:
        return self.raw.get("mt5", {})

    @property
    def anthropic(self) -> dict:
        return self.raw.get("anthropic", {})

    @property
    def trading(self) -> dict:
        return self.raw.get("trading", {})

    @property
    def risk(self) -> dict:
        return self.raw.get("risk", {})

    @property
    def logging_cfg(self) -> dict:
        return self.raw.get("logging", {})
