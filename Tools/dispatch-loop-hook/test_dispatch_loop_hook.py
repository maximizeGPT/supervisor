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


if __name__ == "__main__":
    unittest.main()
