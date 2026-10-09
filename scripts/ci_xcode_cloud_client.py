"""Renew credentials before API use and retry reads without replaying starts."""

from __future__ import annotations

import re
import time
from urllib.error import URLError

from ci_summary import ContractError, require
from ci_xcode_cloud_api import AppStoreConnect


def transient(error):
    if isinstance(error, (URLError, TimeoutError)):
        return True
    match = re.search(r"HTTP ([0-9]{3})", str(error))
    return bool(match and (int(match[1]) == 429 or int(match[1]) >= 500))


class RenewingAppStoreConnect(AppStoreConnect):
    def __init__(self, token_factory, deadline, *, timer=time.monotonic, sleep=time.sleep):
        super().__init__("")
        self.factory, self.deadline = token_factory, deadline
        self.timer, self.sleep, self.renewed = timer, sleep, None

    def request(self, path, *, method="GET", payload=None):
        delay = 2
        while True:
            require(self.timer() < self.deadline, "cloud API deadline exceeded")
            if self.renewed is None or self.timer() - self.renewed >= 8 * 60:
                self.token, self.renewed = self.factory(), self.timer()
            try:
                return super().request(path, method=method, payload=payload)
            except (ContractError, URLError, TimeoutError) as error:
                # A timed-out or 5xx POST may already have created a build.
                # Its persisted reservation must reconcile that uncertainty.
                if method != "GET" or not transient(error):
                    raise
                remaining = self.deadline - self.timer()
                require(remaining > delay, "cloud API retry deadline exceeded")
                self.sleep(delay)
                delay = min(60, delay * 2)
