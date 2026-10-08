"""Runner-owned, test-only infrastructure wait factor; product timing never scales."""

import math

from ci_summary import require

FACTOR_ENVIRONMENT_KEY = "IMMICHSLIDES_TEST_WAIT_FACTOR"


def wait_configuration(factor):
    require(type(factor) in (int, float) and math.isfinite(factor) and 1 <= factor <= 4,
            "test wait factor must be finite and between 1 and 4")
    return {"schema_version": 1, "environment_key": FACTOR_ENVIRONMENT_KEY,
            "infrastructure_factor": float(factor), "product_factor": 1,
            "minimum_factor": 1, "maximum_factor": 4, "source": "runner-argument"}
