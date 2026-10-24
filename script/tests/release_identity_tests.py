"""Candidate version regression tests; historical 1.1.0 fixtures are unchanged."""
import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_identity import release_identity


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.project = {"rootObject": "project", "objects": {
            "project": {"targets": ["tests", "app"]},
            "tests": {"name": "SlateSyncTests"},
            "app": {"name": "SlateSync", "buildConfigurationList": "configs"},
            "configs": {"buildConfigurations": ["debug", "release"]},
            "debug": {"name": "Debug", "buildSettings": {"MARKETING_VERSION": "9.9.9"}},
            "release": {"name": "Release", "buildSettings": {
                "MARKETING_VERSION": "1.2.0", "CURRENT_PROJECT_VERSION": "19"}},
        }}

    def test_candidate_version_and_build_are_not_frozen(self):
        self.assertEqual(release_identity(self.project),
                         {"configuration": "Release", "version": "1.2.0", "build": "19"})

    def test_invalid_or_unresolved_settings_are_rejected(self):
        for key, value in [("MARKETING_VERSION", "$(VERSION)"), ("MARKETING_VERSION", "1.2"),
                           ("CURRENT_PROJECT_VERSION", "0"), ("CURRENT_PROJECT_VERSION", "")]:
            with self.subTest(key=key, value=value):
                project = copy.deepcopy(self.project)
                project["objects"]["release"]["buildSettings"][key] = value
                with self.assertRaises(ValueError):
                    release_identity(project)

    def test_missing_or_duplicate_release_is_rejected(self):
        for configurations in [["debug"], ["release", "release"]]:
            self.project["objects"]["configs"]["buildConfigurations"] = configurations
            with self.assertRaises(ValueError):
                release_identity(self.project)


if __name__ == "__main__":
    unittest.main()
