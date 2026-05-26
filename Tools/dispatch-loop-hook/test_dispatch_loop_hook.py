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
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done. Ready for next task.", "ts": ""}
             ]), \
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
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
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
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
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
             patch.object(hook, 'read_recent_turns', return_value=[
                 {"role": "assistant", "text": "All done.", "ts": ""}
             ]), \
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


class TestStopShapePhrases(unittest.TestCase):
    """Gate-4 stop-shape detection: each phrase must fire, negatives must not."""

    # -- Original 8 phrases (regression) --
    def test_original_ready_for_next(self):
        self.assertEqual(hook.has_stop_shape("Ready for next task."), "ready for next")

    def test_original_done(self):
        self.assertEqual(hook.has_stop_shape("I'm done with the refactor."), "done")

    def test_original_complete(self):
        self.assertEqual(hook.has_stop_shape("Migration complete."), "complete")

    # -- New phrases --
    def test_pushed(self):
        self.assertEqual(hook.has_stop_shape("5 commits pushed."), "pushed")

    def test_shipped(self):
        self.assertEqual(hook.has_stop_shape("v0.4.2 shipped."), "shipped")

    def test_blocked_on(self):
        self.assertEqual(hook.has_stop_shape("Blocked on AX permissions."), "blocked on")

    def test_open_issues_remaining(self):
        self.assertEqual(hook.has_stop_shape("3 open issues remaining."), "open issues remaining")

    def test_tests_pass(self):
        self.assertEqual(hook.has_stop_shape("All tests pass."), "tests pass")

    def test_tests_passing(self):
        self.assertEqual(hook.has_stop_shape("Tests passing on CI."), "tests passing")

    def test_no_further_action(self):
        self.assertEqual(hook.has_stop_shape("No further action needed."), "no further action")

    def test_no_remaining(self):
        self.assertEqual(hook.has_stop_shape("No remaining work on this branch."), "no remaining")

    def test_session_summary(self):
        self.assertEqual(hook.has_stop_shape("Session summary: 4 issues closed."), "session summary")

    # -- Negative cases --
    def test_tests_alone_does_not_fire(self):
        self.assertIsNone(hook.has_stop_shape("I ran the tests and found failures."))

    def test_push_without_ed_does_not_fire(self):
        # "push" is not "pushed"
        self.assertIsNone(hook.has_stop_shape("Let me push the changes next."))

    def test_block_without_on_does_not_fire(self):
        # "blocked" alone is not "blocked on"
        self.assertIsNone(hook.has_stop_shape("The PR was blocked by review."))

    def test_empty_string(self):
        self.assertIsNone(hook.has_stop_shape(""))

    def test_none_input(self):
        self.assertIsNone(hook.has_stop_shape(None))

    def test_case_insensitive(self):
        self.assertEqual(hook.has_stop_shape("ALL TESTS PASS ON MAIN"), "tests pass")


if __name__ == "__main__":
    unittest.main()
