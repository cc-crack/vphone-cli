#!/usr/bin/env python3
"""Regression coverage for the vphone task-list menu entry."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TaskListMenuTests(unittest.TestCase):
    def test_apps_menu_exposes_task_list_entry(self):
        source = (ROOT / "Sources/vphone-cli/VPhoneMenuApps.swift").read_text()

        self.assertIn('"Task List"', source)
        self.assertIn("taskListItem", source)
        self.assertIn("openTaskList", source)

    def test_task_list_opens_running_filter(self):
        source = (ROOT / "Sources/vphone-cli/VPhoneAppWindowController.swift").read_text()

        self.assertIn("initialFilter: VPhoneAppBrowserModel.AppFilter", source)
        self.assertIn("model.filter = initialFilter", source)


if __name__ == "__main__":
    unittest.main()
