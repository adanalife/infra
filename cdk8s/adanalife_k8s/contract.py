"""Loader for contract.json — the canonical service names / ports / env keys
shared with tripbot (the anti-drift bridge). Constructs reference these instead
of hard-coding strings, so a rename/port change is one edit on the tripbot side
(regenerate + `task contract:sync`) and any mismatch is caught by tests.
"""
from __future__ import annotations

import json
from functools import cache
from pathlib import Path

_CONTRACT_PATH = Path(__file__).resolve().parent.parent / "contract.json"


class Contract:
    def __init__(self, raw: dict):
        self.services: dict[str, str] = raw["services"]
        self.ports: dict[str, int] = raw["ports"]
        self.env_keys: dict[str, str] = raw["env_keys"]

    def svc(self, key: str) -> str:
        return self.services[key]

    def port(self, key: str) -> int:
        return self.ports[key]

    # Composed URLs the OBS image consumes (built from canonical names+ports so
    # they can't drift from the Services they point at).
    @property
    def dashcam_rtsp_url(self) -> str:
        return f"rtsp://{self.svc('vlc_server')}:{self.port('vlc_rtsp')}/dashcam"

    @property
    def onscreens_url_base(self) -> str:
        return f"http://{self.svc('onscreens_server')}:{self.port('onscreens_http')}"

    @property
    def vlc_url_base(self) -> str:
        return f"http://{self.svc('vlc_server')}:{self.port('vlc_http')}"


@cache
def load_contract() -> Contract:
    return Contract(json.loads(_CONTRACT_PATH.read_text()))
