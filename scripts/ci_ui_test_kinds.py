"""Base-owned functional/screenshot rules over XCTest method names."""

from __future__ import annotations

from ci_summary import require
from ci_ui_shards import SELECTOR

# Keep both predicates explicit: the host audit catches a missing or overlapping rule.
RULES = (("functional", lambda method: "Screenshot" not in method and "Acceptance" not in method),
         ("screenshot", lambda method: "Screenshot" in method or "Acceptance" in method))


def method_kind(key):
    require(isinstance(key, str) and "/" in key and SELECTOR.fullmatch(key) is not None,
            "UI kind classification needs an exact method")
    matches = [kind for kind, predicate in RULES if predicate(key.split("/")[1])]
    require(matches, "unclassified UI method: " + key)
    require(len(matches) == 1, "ambiguous UI method: " + key)
    require(matches[0] in {"functional", "screenshot"}, "unsupported UI method kind")
    return matches[0]


def classify_ui_methods(populations):
    """Classify the unfiltered two-platform inventory, including non-default methods."""
    return {key: method_kind(key) for key in sorted({entry["key"] for platform in ("ios", "tvos")
                                                  for entry in populations.get("ui-" + platform, [])})}
