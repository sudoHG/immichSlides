import unittest


class FixtureFailureControl(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        def cleanup():
            raise ValueError("intentional class cleanup failure")
        cls.addClassCleanup(cleanup)
        raise RuntimeError("intentional fixture setup failure")

    def test_unexecuted_member(self):
        self.fail("must not run")


class CleanupSkipControl(unittest.TestCase):
    @classmethod
    def tearDownClass(cls):
        raise unittest.SkipTest("intentional cleanup skip reason")

    def test_executed_member(self):
        self.assertTrue(True)
