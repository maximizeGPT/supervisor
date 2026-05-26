#!/usr/bin/env python3
"""
Tests for dispatch_loop_hook.py — v0.4.1-hook reliability fixes.

Covers:
  1. JSON parse error retry: mock DeepSeek returning malformed JSON twice,
     assert silent_exit after one retry.
  2. requires_human_presence gate: mock dispatcher returning
     requires_human_presence=true, assert GATE_FAIL with that reason.
  3. Retry success on second attempt: first call fails, second succeeds.
"""

import json
import os
import unittest
from unittest.mock import patch, MagicMock
from pathlib import Path

# Import the hook module from the same directory.
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dispatch_loop_hook as hook


class TestParseRetry(unittest.TestCase):
    """v0.4.1: JSON parse error retry — one retry, then silent-exit."""

    def test_malformed_json_retries_once_then_silent_exits(self):
        """When DeepSeek returns malformed JSON twice, the hook
        should call the dispatcher exactly twice (original + 1 retry)
        and then silent_exit."""
        call_count = 0

        def fake_call(*, key, cfg, system_prompt, user_message):
            nonlocal call_count
            call_count += 1
            return None  # simulates parse failure

        exit_reasons = []
        def fake_silent_exit(reason):
            exit_reasons.append(reason)
            raise SystemExit(0)

        with patch.object(hook, 'call_dispatcher', side_effect=fake_call), \
             patch.object(hook, 'silent_exit', side_effect=fake_silent_exit), \
             patch.object(hook, 'load_config', return_value=dict(hook.DEFAULTS)), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'detect_worker_stopped', return_value=True), \
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done. Ready for next task.", "ts": ""}
             ]), \
             patch.object(hook, 'fetch_diff_stat', return_value=[]), \
             patch.object(hook, 'current_branch', return_value="autonomous-test"), \
             patch.object(hook, 'fetch_issues', return_value=[]), \
             patch.object(hook, 'fetch_commits', return_value=[]), \
             patch.object(hook, 'read_keychain', return_value="sk-test"), \
             patch.object(hook, 'load_system_prompt', return_value="test prompt"), \
             patch.object(hook, 'ENABLED_FLAG', new=MagicMock(exists=MagicMock(return_value=True))), \
             patch('sys.stdin', MagicMock(read=MagicMock(return_value=json.dumps({
                 "session_id": "s1",
                 "cwd": "/Users/main/supervisor",
                 "transcript_path": "/tmp/test.jsonl",
             })))):
            try:
                hook.main()
            except SystemExit:
                pass

        self.assertEqual(call_count, 2,
                         "hook must call dispatcher exactly twice (original + 1 retry)")
        self.assertTrue(len(exit_reasons) > 0, "silent_exit must be called")
        self.assertIn("dispatcher_returned_none", exit_reasons[-1])

    def test_retry_succeeds_on_second_attempt(self):
        """When first call returns None but second returns valid high-confidence
        result, the hook should emit_block (not silent_exit)."""
        call_count = 0

        def fake_call(*, key, cfg, system_prompt, user_message):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return None  # first call fails
            return {
                "next_task_proposal": "Do the next thing per PRINCIPLES.",
                "justification": "Mechanical follow-on.",
                "confidence": "high",
                "selected_path": "continue_branch",
            }

        with patch.object(hook, 'call_dispatcher', side_effect=fake_call), \
             patch.object(hook, 'emit_block') as mock_block, \
             patch.object(hook, 'load_config', return_value=dict(hook.DEFAULTS)), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'detect_worker_stopped', return_value=True), \
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
             patch.object(hook, 'fetch_diff_stat', return_value=[]), \
             patch.object(hook, 'current_branch', return_value="autonomous-test"), \
             patch.object(hook, 'fetch_issues', return_value=[]), \
             patch.object(hook, 'fetch_commits', return_value=[]), \
             patch.object(hook, 'read_keychain', return_value="sk-test"), \
             patch.object(hook, 'load_system_prompt', return_value="test prompt"), \
             patch.object(hook, 'ENABLED_FLAG', new=MagicMock(exists=MagicMock(return_value=True))), \
             patch('sys.stdin', MagicMock(read=MagicMock(return_value=json.dumps({
                 "session_id": "s1",
                 "cwd": "/Users/main/supervisor",
                 "transcript_path": "/tmp/test.jsonl",
             })))):
            try:
                hook.main()
            except SystemExit:
                pass

        self.assertEqual(call_count, 2)
        mock_block.assert_called_once()


class TestRequiresHumanPresenceGate(unittest.TestCase):
    """v0.4.1: requires_human_presence gate — silent_exit with GATE_FAIL."""

    def test_requires_human_presence_true_gates_dispatch(self):
        """When dispatcher returns requires_human_presence=true,
        the hook must silent_exit with reason=requires_human_presence."""

        def fake_call(*, key, cfg, system_prompt, user_message):
            return {
                "next_task_proposal": "Run the physical-world trial...",
                "justification": "Live trial is the last blocker.",
                "confidence": "high",
                "selected_path": "continue_branch",
                "requires_human_presence": True,
            }

        exit_reasons = []
        def fake_silent_exit(reason):
            exit_reasons.append(reason)
            raise SystemExit(0)

        with patch.object(hook, 'call_dispatcher', side_effect=fake_call), \
             patch.object(hook, 'silent_exit', side_effect=fake_silent_exit), \
             patch.object(hook, 'load_config', return_value=dict(hook.DEFAULTS)), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'detect_worker_stopped', return_value=True), \
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
             patch.object(hook, 'fetch_diff_stat', return_value=[]), \
             patch.object(hook, 'current_branch', return_value="autonomous-test"), \
             patch.object(hook, 'fetch_issues', return_value=[]), \
             patch.object(hook, 'fetch_commits', return_value=[]), \
             patch.object(hook, 'read_keychain', return_value="sk-test"), \
             patch.object(hook, 'load_system_prompt', return_value="test prompt"), \
             patch.object(hook, 'ENABLED_FLAG', new=MagicMock(exists=MagicMock(return_value=True))), \
             patch('sys.stdin', MagicMock(read=MagicMock(return_value=json.dumps({
                 "session_id": "s1",
                 "cwd": "/Users/main/supervisor",
                 "transcript_path": "/tmp/test.jsonl",
             })))):
            try:
                hook.main()
            except SystemExit:
                pass

        self.assertTrue(len(exit_reasons) > 0, "silent_exit must be called")
        self.assertIn("GATE_FAIL", exit_reasons[-1])
        self.assertIn("requires_human_presence", exit_reasons[-1])

    def test_requires_human_presence_false_does_not_gate(self):
        """When requires_human_presence is explicitly false,
        high-confidence dispatch proceeds normally (emit_block)."""

        def fake_call(*, key, cfg, system_prompt, user_message):
            return {
                "next_task_proposal": "Continue the work.",
                "justification": "Mechanical follow-on.",
                "confidence": "high",
                "selected_path": "continue_branch",
                "requires_human_presence": False,
            }

        with patch.object(hook, 'call_dispatcher', side_effect=fake_call), \
             patch.object(hook, 'emit_block') as mock_block, \
             patch.object(hook, 'load_config', return_value=dict(hook.DEFAULTS)), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'detect_worker_stopped', return_value=True), \
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
             patch.object(hook, 'fetch_diff_stat', return_value=[]), \
             patch.object(hook, 'current_branch', return_value="autonomous-test"), \
             patch.object(hook, 'fetch_issues', return_value=[]), \
             patch.object(hook, 'fetch_commits', return_value=[]), \
             patch.object(hook, 'read_keychain', return_value="sk-test"), \
             patch.object(hook, 'load_system_prompt', return_value="test prompt"), \
             patch.object(hook, 'ENABLED_FLAG', new=MagicMock(exists=MagicMock(return_value=True))), \
             patch('sys.stdin', MagicMock(read=MagicMock(return_value=json.dumps({
                 "session_id": "s1",
                 "cwd": "/Users/main/supervisor",
                 "transcript_path": "/tmp/test.jsonl",
             })))):
            try:
                hook.main()
            except SystemExit:
                pass

        mock_block.assert_called_once()


class TestParseDispatcherResponse(unittest.TestCase):
    """Unit tests for the _parse_dispatcher_response helper."""

    def test_valid_response_parses(self):
        raw = json.dumps({
            "choices": [{
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": json.dumps({
                                "next_task_proposal": "Do X.",
                                "justification": "Because Y.",
                                "confidence": "high",
                                "selected_path": "continue_branch",
                            })
                        }
                    }]
                }
            }]
        })
        result = hook._parse_dispatcher_response(raw)
        self.assertIsNotNone(result)
        self.assertEqual(result["confidence"], "high")

    def test_malformed_json_returns_none(self):
        result = hook._parse_dispatcher_response('{"choices": [{"message":')
        self.assertIsNone(result)

    def test_truncated_arguments_returns_none(self):
        raw = json.dumps({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": '{"next_task_proposal": "unterminated string'
                        }
                    }]
                }
            }]
        })
        result = hook._parse_dispatcher_response(raw)
        self.assertIsNone(result)

    def test_truncated_args_logs_finish_reason_and_raw_head(self):
        """When args_raw is truncated JSON (max_tokens hit), the log
        must include finish_reason and the first 300 chars of args."""
        log_lines = []
        truncated_args = '{"next_task_proposal": "Pick up Issue #9. Do the AX investigation per'

        raw = json.dumps({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": truncated_args
                        }
                    }]
                }
            }],
            "usage": {"completion_tokens": 1024, "prompt_tokens": 5000}
        })

        with patch.object(hook, 'log', side_effect=lambda msg: log_lines.append(msg)):
            result = hook._parse_dispatcher_response(raw)

        self.assertIsNone(result)
        # Find the parse error log line
        error_lines = [l for l in log_lines if "deepseek_parse_error" in l]
        self.assertEqual(len(error_lines), 1)
        line = error_lines[0]
        self.assertIn("finish_reason=length", line)
        self.assertIn("RAW_RESPONSE", line)
        self.assertIn("Pick up Issue #9", line)

    def test_no_tool_call_logs_finish_reason(self):
        """When no tool_calls in response (e.g. refusal or length),
        finish_reason must appear in the log."""
        log_lines = []

        raw = json.dumps({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "content": "I apologize, but I cannot"
                }
            }]
        })

        with patch.object(hook, 'log', side_effect=lambda msg: log_lines.append(msg)):
            result = hook._parse_dispatcher_response(raw)

        self.assertIsNone(result)
        no_tool_lines = [l for l in log_lines if "deepseek_no_tool_call" in l]
        self.assertEqual(len(no_tool_lines), 1)
        self.assertIn("finish_reason=length", no_tool_lines[0])

    def test_success_logs_parse_ok_with_tokens(self):
        """Successful parse must log PARSE_OK with finish_reason
        and output_tokens for ceiling monitoring."""
        log_lines = []

        raw = json.dumps({
            "choices": [{
                "finish_reason": "stop",
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": json.dumps({
                                "next_task_proposal": "Do X.",
                                "justification": "Because Y.",
                                "confidence": "high",
                                "selected_path": "continue_branch",
                            })
                        }
                    }]
                }
            }],
            "usage": {"completion_tokens": 487, "prompt_tokens": 5000}
        })

        with patch.object(hook, 'log', side_effect=lambda msg: log_lines.append(msg)):
            result = hook._parse_dispatcher_response(raw)

        self.assertIsNotNone(result)
        ok_lines = [l for l in log_lines if "PARSE_OK" in l]
        self.assertEqual(len(ok_lines), 1)
        self.assertIn("finish_reason=stop", ok_lines[0])
        self.assertIn("output_tokens=487", ok_lines[0])


class TestFetchDiffStat(unittest.TestCase):
    """Issue #10: fetch_diff_stat returns git diff --stat lines."""

    def test_parses_normal_diff_stat(self):
        sample = (
            " Sources/SupervisorCore/Triage/TriageEngine.swift | 8 ++++++++\n"
            " Tests/SupervisorCoreTests/TriageEngineTests.swift | 24 ++++++++++\n"
            " Tools/dispatch-loop-hook/dispatch_loop_hook.py    | 8 ++++++++\n"
            " 3 files changed, 40 insertions(+)\n"
        )
        with patch.object(hook, 'run', return_value=(0, sample, "")):
            result = hook.fetch_diff_stat("/fake", "autonomous-test", 10)
        self.assertEqual(len(result), 4)  # 3 file lines + 1 summary
        self.assertIn("TriageEngine.swift", result[0])
        self.assertIn("3 files changed", result[-1])

    def test_empty_on_failure(self):
        with patch.object(hook, 'run', return_value=(1, "", "fatal")):
            result = hook.fetch_diff_stat("/fake", "autonomous-test", 10)
        self.assertEqual(result, [])

    def test_truncates_to_30_files(self):
        file_lines = [f" file{i}.swift | {i} +\n" for i in range(40)]
        sample = "".join(file_lines) + " 40 files changed, 100 insertions(+)\n"
        with patch.object(hook, 'run', return_value=(0, sample, "")):
            result = hook.fetch_diff_stat("/fake", "autonomous-test", 10)
        # 30 file lines + 1 summary = 31
        self.assertEqual(len(result), 31)
        self.assertIn("40 files changed", result[-1])


class TestBuildUserMessageDiffStat(unittest.TestCase):
    """Issue #10: recent_files_changed appears in the dispatcher user message."""

    def test_diff_stat_in_user_message(self):
        msg = hook.build_user_message(
            session_id="s1",
            cwd="/Users/main/supervisor",
            branch="autonomous-test",
            recent_turns=[],
            issues=[],
            commits=[{"sha": "abc12345", "subject": "test commit", "body": ""}],
            recent_files_changed=[
                "Sources/SupervisorCore/Triage/TriagePrompt.swift | 10 ++++",
                "Sources/SupervisorCore/Triage/HardcodedRubric.swift | 5 +++",
                "2 files changed, 15 insertions(+)",
            ],
            prior_count=0,
            principles_text="# Test principles",
        )
        self.assertIn("# Recent files changed on this branch", msg)
        self.assertIn("TriagePrompt.swift", msg)
        self.assertIn("HardcodedRubric.swift", msg)
        self.assertIn("2 files changed", msg)

    def test_empty_diff_stat_shows_placeholder(self):
        msg = hook.build_user_message(
            session_id="s1",
            cwd="/Users/main/supervisor",
            branch="autonomous-test",
            recent_turns=[],
            issues=[],
            commits=[],
            recent_files_changed=[],
            prior_count=0,
            principles_text="# Test principles",
        )
        self.assertIn("(none — either fresh branch, or git diff failed)", msg)


class TestSystemPromptContainsDiffStatGuidance(unittest.TestCase):
    """Issue #10: dispatcher system prompt teaches about recent_files_changed."""

    def test_system_prompt_mentions_recent_files_changed(self):
        prompt = hook.load_system_prompt()
        self.assertIn("recent_files_changed", prompt)
        self.assertIn("authoritative signal", prompt)

    def test_system_prompt_warns_against_partial_completion_inference(self):
        prompt = hook.load_system_prompt()
        self.assertIn("Before inferring partial completion", prompt)


class TestDetectWorkerStopped(unittest.TestCase):
    """Gate 4 replacement: detect worker stopped via absence of tool_use blocks."""

    def _write_jsonl(self, lines: list[dict]) -> str:
        import tempfile
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False)
        for obj in lines:
            f.write(json.dumps(obj) + "\n")
        f.close()
        return f.name

    def test_gate_passes_when_assistant_ends_with_text_only(self):
        path = self._write_jsonl([
            {"type": "user", "message": {"content": "do the thing"}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "All tests pass. Pushed."}
            ]}},
        ])
        self.assertTrue(hook.detect_worker_stopped(path))
        os.unlink(path)

    def test_gate_blocks_when_assistant_ends_with_tool_use(self):
        path = self._write_jsonl([
            {"type": "user", "message": {"content": "do the thing"}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Running tests now."},
                {"type": "tool_use", "name": "Bash", "id": "t1", "input": {"command": "swift test"}},
            ]}},
        ])
        self.assertFalse(hook.detect_worker_stopped(path))
        os.unlink(path)

    def test_gate_blocks_when_last_block_is_tool_use_after_text(self):
        path = self._write_jsonl([
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Let me check that."},
            ]}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Looking at the file."},
                {"type": "tool_use", "name": "Read", "id": "t2", "input": {"file_path": "/tmp/x"}},
            ]}},
        ])
        self.assertFalse(hook.detect_worker_stopped(path))
        os.unlink(path)

    def test_gate_handles_empty_transcript_gracefully(self):
        import tempfile
        f = tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False)
        f.close()
        self.assertFalse(hook.detect_worker_stopped(f.name))
        os.unlink(f.name)

    def test_gate_handles_no_assistant_messages_gracefully(self):
        path = self._write_jsonl([
            {"type": "user", "message": {"content": "hello"}},
        ])
        self.assertFalse(hook.detect_worker_stopped(path))
        os.unlink(path)


if __name__ == "__main__":
    unittest.main()
