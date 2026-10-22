#!/usr/bin/env python3
"""Real stdio MCP contract test using synthetic files and an isolated config.

No browser, GUI, provider request, desktop project database, or credentials are
used. Keep the optional transcript as reproducible protocol evidence.
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import subprocess
import tempfile
import time


def run(binary, report, managed=False, no_grants=False):
    transcript = []
    # A short private root keeps Unix socket paths below Darwin's sun_path limit.
    with tempfile.TemporaryDirectory(prefix="slatesync-mcp-smoke-", dir="/tmp") as temporary, ExitStack() as cleanup:
        root = Path(temporary).resolve()
        csv = root / "source.csv"
        source = b"File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,,,,\r\n"
        csv.write_bytes(source)
        output = root / "output.csv"
        # Pass only ordinary process settings; never inherit provider secrets.
        environment = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
        # Empty grants exercise discovery while retaining deny-by-default file access.
        arguments = ["--settings-directory", str(root / "settings")]
        if not no_grants:
            arguments += ["--allow-directory", str(root)]
        broker = None
        if managed:
            endpoint = root / "managed" / "service.sock"
            broker = subprocess.Popen([str(binary), "--managed-socket", str(endpoint)] + arguments,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)

            def stop_broker():
                if broker.poll() is None:
                    broker.stdin.close()
                    try:
                        broker.wait(timeout=12)
                    except subprocess.TimeoutExpired:
                        os.killpg(broker.pid, signal.SIGKILL)
                        broker.wait(timeout=5)

            cleanup.callback(stop_broker)
            ready, _, _ = select.select([broker.stdout], [], [], 10)
            assert ready, "Broker did not become ready"
            readiness = broker.stdout.readline()
            assert readiness == b"SLATESYNC_MCP_READY\n", readiness
            assert stat.S_IMODE(endpoint.stat().st_mode) == 0o600
            assert stat.S_IMODE(endpoint.parent.stat().st_mode) == 0o700
            # A second instance cannot unlink or replace the live broker.
            duplicate = subprocess.run([str(binary), "--managed-socket", str(endpoint)] + arguments,
                                       input=b"", capture_output=True, timeout=5, env=environment)
            assert duplicate.returncode != 0 and b"already running" in duplicate.stderr, duplicate
            command = [str(binary), "--connect", str(endpoint)]
        else:
            command = [str(binary)] + arguments
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
        buffer = bytearray()
        sequence = 0

        def send(message):
            process.stdin.write(json.dumps(message, ensure_ascii=False).encode() + b"\n")
            process.stdin.flush()

        def receive(timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if b"\n" not in buffer:
                    ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
                    assert ready, "Timed out waiting for a protocol response"
                    chunk = os.read(process.stdout.fileno(), 65536)
                    assert chunk, "Server exited while waiting for a response"
                    buffer.extend(chunk)
                    continue
                line, _, rest = buffer.partition(b"\n")
                buffer[:] = rest
                return json.loads(line)
            raise AssertionError("No protocol response")

        def request(method, params=None):
            nonlocal sequence
            sequence += 1
            message = {"jsonrpc": "2.0", "id": sequence, "method": method}
            if params is not None:
                message["params"] = params
            send(message)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                response = receive(max(0, deadline - time.monotonic()))
                transcript.append({"request": message, "response": response})
                if response.get("id") == sequence:
                    return response
            raise AssertionError(f"No response for {method}")

        def call(name, arguments):
            return request("tools/call", {"name": name, "arguments": arguments})

        try:
            uninitialized = request("tools/list")
            assert "error" in uninitialized, uninitialized
            initialized = request("initialize", {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "slatesync-offline-smoke", "version": "1.0"},
            })
            assert initialized["result"]["protocolVersion"] == "2025-11-25", initialized
            send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = request("tools/list")["result"]["tools"]
            assert len(tools) == 6, tools
            assert all(tool["inputSchema"]["type"] == "object" for tool in tools)
            assert request("ping")["result"] == {}
            records = [{"cardNumber": "A001", "videoCode": "C001", "scene": "1", "shot": "2", "take": "3", "takeStatus": "过"}]
            if no_grants:
                models = call("slatesync_list_models", {})["result"]
                assert models["isError"] is False, models
                denied_local = call("slatesync_import_slate_csv", {"path": str(csv)})["result"]
                assert denied_local["structuredContent"]["code"] == "MCP_PATH_DENIED", denied_local
                denied_export = call("slatesync_export_csv", {"csvPath": str(csv), "records": records, "outputPath": str(output)})["result"]
                assert denied_export["structuredContent"]["code"] == "MCP_PATH_DENIED", denied_export
                assert not output.exists()
                transcript.append({"noGrants": "PASS", "checks": ["initialize", "six tools", "model listing", "read denied", "export denied"]})
            else:
                preview = call("slatesync_preview_merge", {"csvPath": str(csv), "records": records})["result"]
                assert preview["isError"] is False, preview
                assert preview["structuredContent"]["canExport"] is True
                exported = call("slatesync_export_csv", {"csvPath": str(csv), "records": records, "outputPath": str(output)})["result"]
                assert exported["isError"] is False, exported
                assert output.read_bytes() == b"File Name,Scene,Shot,Take,Comments\r\nA001C001.mov,001,02,03,_OK\r\n"
                assert csv.read_bytes() == source
                repeated = call("slatesync_export_csv", {"csvPath": str(csv), "records": records, "outputPath": str(output)})["result"]
                assert repeated["structuredContent"]["code"] == "MCP_OUTPUT_EXISTS", repeated
                # Two large replies must not interleave when stdio backpressure
                # suspends a partial write. Exercise the real SDK in both direct
                # and managed modes; a concurrent ping also checks small frames.
                large_csv = root / "large.csv"
                note = "a" * 4096
                large_csv.write_text("File Name,Scene,Shot,Take,Notes\n"
                                     + f"A001C001.mov,,,,{note}\n" * 200)
                preview_ids = []
                for _ in range(2):
                    sequence += 1
                    preview_ids.append(sequence)
                    send({"jsonrpc": "2.0", "id": sequence, "method": "tools/call", "params": {
                        "name": "slatesync_preview_merge", "arguments": {
                            "csvPath": str(large_csv), "records": records, "limit": 200}}})
                sequence += 1
                ping_id = sequence
                send({"jsonrpc": "2.0", "id": ping_id, "method": "ping"})
                time.sleep(0.2)
                responses = {}
                for _ in range(3):
                    response = receive()
                    identifier = response.get("id")
                    assert identifier in preview_ids + [ping_id] and identifier not in responses
                    responses[identifier] = response
                for identifier in preview_ids:
                    result = responses[identifier]["result"]
                    assert result["isError"] is False
                    structured = result["structuredContent"]
                    assert structured == json.loads(result["content"][0]["text"])
                    assert structured["rowCount"] == 200 and len(structured["rows"]) == 200
                    notes_column = structured["headers"].index("Notes")
                    assert all(row[notes_column] == note for row in structured["rows"])
                assert responses[ping_id]["result"] == {}
                transcript.append({"concurrentLargeReplies": "PASS", "previewCount": 2,
                                   "rowsPerPreview": 200, "noteBytesPerRow": len(note), "concurrentPing": True})
            denied = call("slatesync_import_slate_csv", {"path": "/etc/hosts"})["result"]
            assert denied["structuredContent"]["code"] == "MCP_PATH_DENIED", denied
            invalid = call("slatesync_preview_merge", {"csvPath": str(csv), "records": records, "limit": -1})
            assert invalid["error"]["code"] == -32602, invalid
            unknown = call("not_a_tool", {})
            assert unknown["error"]["code"] == -32602, unknown
            disabled = call("slatesync_recognize", {"path": str(root / "not-read.jpg")})["result"]
            assert disabled["structuredContent"]["code"] == "MCP_MODEL_REQUESTS_DISABLED", disabled
            # EOF is the primary stdio shutdown signal and must terminate promptly.
            process.stdin.close()
            assert process.wait(timeout=10) == 0
            assert process.stdout.read() == b"", "Unexpected non-protocol output"
            stderr = process.stderr.read().decode()
            assert not stderr, stderr
            if managed:
                # Independent sessions can use the same JSON-RPC IDs. Keep
                # them connected while app-control EOF drains the whole broker.
                connections = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(2)]
                try:
                    for connection in connections:
                        connection.settimeout(10)
                        connection.connect(str(endpoint))
                        connection.sendall(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                            "protocolVersion": "2025-11-25", "capabilities": {},
                            "clientInfo": {"name": "managed-second-client", "version": "1.0"}}}).encode() + b"\n")
                        data = bytearray()
                        while b"\n" not in data:
                            data.extend(connection.recv(65536))
                        assert json.loads(data)["result"]["protocolVersion"] == "2025-11-25"
                    broker.stdin.close()
                    assert broker.wait(timeout=12) == 0
                    for connection in connections:
                        assert connection.recv(1) == b"", "Session survived app shutdown"
                    assert not endpoint.exists(), "Stopped broker left a socket"
                    assert broker.stderr.read() == b""
                    stopped = subprocess.run(command, input=b"", capture_output=True, timeout=5, env=environment)
                    assert stopped.returncode != 0 and b"service is stopped" in stopped.stderr
                    # A stale socket from a killed app can be recovered, but
                    # an ordinary file at the endpoint must remain untouched.
                    endpoint.write_text("preserve this file")
                    blocked = subprocess.run([str(binary), "--managed-socket", str(endpoint)] + arguments,
                                             input=b"", capture_output=True, timeout=5, env=environment)
                    assert blocked.returncode != 0 and endpoint.read_text() == "preserve this file"
                    endpoint.unlink()
                    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    stale.bind(str(endpoint))
                    stale.close()
                    broker = subprocess.Popen([str(binary), "--managed-socket", str(endpoint)] + arguments,
                                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
                    ready, _, _ = select.select([broker.stdout], [], [], 10)
                    assert ready and broker.stdout.readline() == b"SLATESYNC_MCP_READY\n", "Stale socket recovery failed"
                    broker.terminate()
                    assert broker.wait(timeout=12) == 0
                    assert not endpoint.exists() and broker.stderr.read() == b""
                    transcript.append({"managed": "PASS", "checks": ["private permissions", "duplicate rejection", "two sessions", "app EOF drain", "socket cleanup", "stopped connection error", "non-socket preservation", "stale socket recovery", "SIGTERM shutdown"]})
                finally:
                    for connection in connections:
                        connection.close()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if report:
                Path(report).write_text(json.dumps(transcript, ensure_ascii=False, indent=2) + "\n")
    print(f"MCP {'managed' if managed else 'stdio'} smoke: PASS (no_grants={no_grants}, initialize, six tools, permissions, errors, EOF)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--report")
    parser.add_argument("--managed", action="store_true", help="Exercise app-owned broker and client stdio bridge")
    parser.add_argument("--no-grants", action="store_true", help="Verify directory-free startup and denied file access")
    args = parser.parse_args()
    run(args.binary.resolve(), args.report, managed=args.managed, no_grants=args.no_grants)
