"""Renew credentials before API use and retry reads without replaying starts."""

from __future__ import annotations

import re
import time
from urllib.error import URLError

from ci_summary import ContractError, require
from ci_publish import GitHub
from ci_xcode_cloud_api import AppStoreConnect


def transient(error):
    if isinstance(error, (URLError, TimeoutError)):
        return True
    match = re.search(r"HTTP ([0-9]{3})", str(error))
    return bool(match and (int(match[1]) == 429 or int(match[1]) >= 500))


class RetryingGitHub(GitHub):
    def __init__(self, repository, token, deadline, *, timer=time.monotonic, sleep=time.sleep):
        super().__init__(repository, token)
        self.deadline, self.timer, self.sleep = deadline, timer, sleep

    def request(self, path, *, method="GET", **options):
        # Bound a failed read round so a consumer can re-evaluate its deadline.
        read_deadline, delay = min(self.deadline, self.timer() + 60), 2
        while True:
            require(self.timer() < self.deadline, "GitHub read deadline exceeded")
            try:
                return super().request(path, method=method, timeout=max(1, min(45, read_deadline - self.timer())), **options)
            except (ContractError, URLError, TimeoutError) as error:
                if method != "GET" or not transient(error) or self.timer() + delay >= read_deadline:
                    raise
                self.sleep(delay)
                delay = min(30, delay * 2)


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
