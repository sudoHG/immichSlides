import unittest


class HostNegativeControlTests(unittest.TestCase):
    def test_intentional_host_failure_is_reported(self):
        self.fail("Intentional host-summary negative control")
