import importlib.machinery
import importlib.util
from pathlib import Path
import socket
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader(
    "shimmerctl", str(Path(__file__).resolve().parents[1] / "shimmerctl"))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)


class DoctorTests(unittest.TestCase):
    def test_bundled_cli_finds_its_own_relocated_app(self):
        with patch.object(cli, "__file__", "/Custom Apps/Shimmer.app/Contents/Resources/shimmerctl.py"):
            self.assertEqual(cli.default_app_path(), "/Custom Apps/Shimmer.app")

    def test_repository_cli_defaults_to_installed_app(self):
        with patch.object(cli, "__file__", "/repo/scripts/shimmerctl"):
            self.assertEqual(cli.default_app_path(), "/Applications/Shimmer.app")

    def test_real_macos_log_schema_keeps_process_identity_for_stream_verdicts(self):
        output = ('{"processID":1065,"timestamp":"2026-10-28 17:27:33.456573-0400",'
                  '"category":"AppModel","eventMessage":"DEBUG automation: stream is live"}\n')
        with patch.object(cli, "run", return_value=SimpleNamespace(
                returncode=0, stdout=output, stderr="")):
            entries = cli.log_entries()
        self.assertEqual(entries[0]["pid"], 1065)
        self.assertEqual(entries[0]["message"], "DEBUG automation: stream is live")

    def test_stream_test_never_relaunches_an_existing_app(self):
        with patch.object(cli, "app_status", return_value={
                "installed": True, "signature_valid": True, "running_pids": [1136]}), \
                patch.object(cli, "run") as launch:
            with self.assertRaisesRegex(RuntimeError, "already running"):
                cli.test_stream(SimpleNamespace(app="/Applications/Shimmer.app"))
        launch.assert_not_called()

    def test_http_alive_does_not_masquerade_as_healthy_secure_control(self):
        http = {"reachable": True}
        https = {"reachable": False, "error": "timed out"}
        self.assertEqual(cli.diagnosis(http, https), "secure_port_unreachable")

    def test_terminal_success_does_not_override_an_app_permission_denial(self):
        reachable = {"reachable": True}
        self.assertEqual(cli.diagnosis(reachable, reachable, permission_denied=True),
                         "macos_local_network_denied")

    def test_both_ports_down_is_a_host_or_route_failure(self):
        self.assertEqual(cli.diagnosis({"reachable": False}, {"reachable": False}),
                         "host_unreachable")

    def test_tcp_probe_connects_to_a_real_listener_then_reports_closed_port(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            port = server.getsockname()[1]

            def accept():
                connection, _ = server.accept()
                connection.close()

            thread = threading.Thread(target=accept)
            thread.start()
            connected = cli.tcp_probe("127.0.0.1", port, timeout=1)
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
            self.assertTrue(connected["reachable"])
            self.assertGreaterEqual(connected["connect_ms"], 0)
        self.assertFalse(cli.tcp_probe("127.0.0.1", port, timeout=1)["reachable"])


if __name__ == "__main__":
    unittest.main()
