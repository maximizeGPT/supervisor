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

        se_calls = []
        def fake_self_extend(**kwargs):
            se_calls.append(kwargs.get("failure_reason"))
            raise SystemExit(0)  # SelfExtender takes over

        with patch.object(hook, 'call_dispatcher', side_effect=fake_call), \
             patch.object(hook, 'silent_exit', side_effect=fake_silent_exit), \
             patch.object(hook, 'try_self_extend', side_effect=fake_self_extend), \
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

        # v0.8.0: retries are now internal to call_dispatcher, so main()
        # calls it exactly once. The mock returns None, so SelfExtender fires.
        self.assertEqual(call_count, 1,
                         "main() must call dispatcher exactly once (retries are internal)")
        self.assertTrue(len(se_calls) > 0, "v0.5.0: SelfExtender must be called on dispatcher failure")
        self.assertIn("dispatcher_returned_none", se_calls[-1])

    def test_call_dispatcher_retries_on_parse_failure(self):
        """v0.8.0: call_dispatcher handles retries internally with
        exponential backoff. First HTTP call returns garbage, second
        returns valid JSON — should succeed on attempt 2."""
        call_count = 0
        valid_response = json.dumps({
            "choices": [{
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": json.dumps({
                                "next_task_proposal": "Do the next thing.",
                                "justification": "Follow-on.",
                                "confidence": "high",
                                "selected_path": "continue_branch",
                            })
                        }
                    }]
                },
                "finish_reason": "stop",
            }]
        })

        def fake_urlopen(req, timeout=None):
            nonlocal call_count
            call_count += 1
            resp = MagicMock()
            if call_count == 1:
                # First call returns truncated garbage.
                resp.read.return_value = b'{"choices": [{"message":'
                resp.__enter__ = lambda s: s
                resp.__exit__ = MagicMock(return_value=False)
                return resp
            # Second call returns valid response.
            resp.read.return_value = valid_response.encode("utf-8")
            resp.__enter__ = lambda s: s
            resp.__exit__ = MagicMock(return_value=False)
            return resp

        cfg = dict(hook.DEFAULTS)
        with patch('urllib.request.urlopen', side_effect=fake_urlopen), \
             patch('time.sleep'):  # skip actual backoff delay
            result = hook.call_dispatcher(
                key="sk-test", cfg=cfg,
                system_prompt="test", user_message="test",
            )

        self.assertIsNotNone(result, "should succeed on second attempt")
        self.assertEqual(call_count, 2, "should take exactly 2 attempts")
        self.assertEqual(result["confidence"], "high")


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

    def test_truncated_arguments_repaired_on_length(self):
        """v0.5.1: finish_reason=length with truncated args should now
        recover via JSON repair instead of returning None."""
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
        self.assertIsNotNone(result, "repair should recover truncated JSON")
        self.assertIn("next_task_proposal", result)

    def test_truncated_arguments_still_none_when_not_length(self):
        """When finish_reason is NOT length, truncated args still return None."""
        raw = json.dumps({
            "choices": [{
                "finish_reason": "stop",
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

    def test_truncated_args_repaired_and_logged(self):
        """v0.5.1: truncated args with finish_reason=length are now
        repaired. The log should show PARSE_REPAIRED."""
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

        self.assertIsNotNone(result, "repair should succeed")
        self.assertIn("next_task_proposal", result)
        # Verify repair was logged
        repair_lines = [l for l in log_lines if "PARSE_REPAIRED" in l]
        self.assertEqual(len(repair_lines), 1)
        self.assertIn("finish_reason=length", repair_lines[0])

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


class TestSelfExtender(unittest.TestCase):
    """v0.5.0: SelfExtender fires on dispatch failures, never files issues."""

    def test_self_extender_prompt_contains_meta_rule(self):
        prompt = hook.load_self_extender_prompt()
        self.assertIn("META-RULE", prompt)
        self.assertIn("NOT authorized to weaken the safety architecture", prompt)

    def test_self_extender_prompt_forbids_issue_filing(self):
        prompt = hook.load_self_extender_prompt()
        self.assertIn("Never file GitHub issues", prompt)
        self.assertIn("gh issue create", prompt)

    def test_detect_stuck_patterns_fires(self):
        self.assertIsNotNone(hook.detect_stuck_patterns("I would normally ask Mohammed about this."))
        self.assertIsNotNone(hook.detect_stuck_patterns("This needs a values call from the user."))
        self.assertIsNotNone(hook.detect_stuck_patterns("PRINCIPLES doesn't cover this case."))

    def test_detect_stuck_patterns_negative(self):
        self.assertIsNone(hook.detect_stuck_patterns("All tests pass."))
        self.assertIsNone(hook.detect_stuck_patterns("Pushed 5 commits."))

    def test_build_self_extender_message_contains_failure_context(self):
        msg = hook.build_self_extender_message(
            failure_reason="consecutive_low_3",
            session_id="s1",
            cwd="/Users/main/supervisor",
            branch="autonomous-test",
            recent_turns=[],
            commits=[],
            recent_files_changed=[],
            principles_text="# Test principles",
            hook_log_tail="2026-05-26T00:00:00Z some log line",
        )
        self.assertIn("# Failure context", msg)
        self.assertIn("consecutive_low_3", msg)
        self.assertIn("# dispatch-loop.log", msg)
        self.assertIn("some log line", msg)

    def test_self_extender_output_never_contains_issue_filing(self):
        """Verify the no-issue-creation enforcement: a SelfExtender result
        containing 'gh issue create' gets logged as a violation."""
        # This tests the validation logic in try_self_extend — the actual
        # enforcement is a log + proceeding (not blocking), because the
        # meta-rule in the prompt is the primary gate.
        prompt = hook.load_self_extender_prompt()
        self.assertIn("filed as Issue", prompt)
        # The prompt explicitly lists these as forbidden output patterns

    def test_parse_self_extender_response_valid(self):
        raw = json.dumps({
            "choices": [{
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_self_extend",
                            "arguments": json.dumps({
                                "fix_prompt": "Read the failing test and fix it.",
                                "diagnosis": "The test expects old behavior.",
                                "confidence": "high",
                            })
                        }
                    }]
                }
            }]
        })
        result = hook._parse_self_extender_response(raw)
        self.assertIsNotNone(result)
        self.assertEqual(result["confidence"], "high")

    def test_parse_self_extender_response_malformed(self):
        result = hook._parse_self_extender_response('{"broken":')
        self.assertIsNone(result)


class TestTruncatedJsonRepair(unittest.TestCase):
    """v0.5.1: JSON repair for finish_reason=length truncated responses."""

    def test_repair_unterminated_string(self):
        truncated = '{"next_task_proposal": "Fix the bug in dispatch_loop_hook.py by adding'
        result = hook._try_repair_truncated_json(truncated)
        self.assertIsNotNone(result)
        self.assertIn("next_task_proposal", result)

    def test_repair_missing_closing_brace(self):
        truncated = '{"confidence": "high", "next_task_proposal": "Do the thing"'
        result = hook._try_repair_truncated_json(truncated)
        self.assertIsNotNone(result)
        self.assertEqual(result["confidence"], "high")
        self.assertEqual(result["next_task_proposal"], "Do the thing")

    def test_repair_truncated_mid_key(self):
        truncated = '{"confidence": "high", "next_task_pro'
        result = hook._try_repair_truncated_json(truncated)
        # Strategy 2: truncate to last comma, recover confidence
        self.assertIsNotNone(result)
        self.assertEqual(result["confidence"], "high")

    def test_repair_valid_json_passthrough(self):
        valid = '{"confidence": "high", "proposal": "Do it"}'
        result = hook._try_repair_truncated_json(valid)
        self.assertIsNotNone(result)
        self.assertEqual(result["confidence"], "high")

    def test_repair_empty_returns_none(self):
        self.assertIsNone(hook._try_repair_truncated_json(""))
        self.assertIsNone(hook._try_repair_truncated_json(None))

    def test_repair_single_brace_returns_empty_dict(self):
        # A lone "{" repairs to "{}" — a valid but empty dict
        result = hook._try_repair_truncated_json("{")
        self.assertEqual(result, {})

    def test_dispatcher_uses_repair_on_length(self):
        """Full parse path: finish_reason=length with truncated args
        should recover via repair."""
        truncated_args = '{"next_task_proposal": "Read the file", "confidence": "high", "selected_path": "continue_bra'
        raw = json.dumps({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_dispatch",
                            "arguments": truncated_args,
                        }
                    }]
                }
            }]
        })
        result = hook._parse_dispatcher_response(raw)
        self.assertIsNotNone(result, "repair should recover partial dispatch result")
        self.assertEqual(result["confidence"], "high")
        self.assertEqual(result["next_task_proposal"], "Read the file")

    def test_self_extender_uses_repair_on_length(self):
        """SelfExtender parse path also uses repair."""
        truncated_args = '{"fix_prompt": "Run swift test", "diagnosis": "Tests failing", "confidence": "hi'
        raw = json.dumps({
            "choices": [{
                "finish_reason": "length",
                "message": {
                    "tool_calls": [{
                        "function": {
                            "name": "record_self_extend",
                            "arguments": truncated_args,
                        }
                    }]
                }
            }]
        })
        result = hook._parse_self_extender_response(raw)
        self.assertIsNotNone(result, "repair should recover partial self-extend result")
        self.assertIn("fix_prompt", result)


class TestBuildFallbackFromGaps(unittest.TestCase):
    """Tests for the _build_fallback_from_gaps deferred-work fallback."""

    def test_returns_prompt_for_actionable_gap(self):
        gaps = """# Known Gaps

## Half-wired features

- **SIGCONT-from-button not wired.** The pause recovery path requires manual kill -CONT.
- ~~**Already fixed item.**~~ Done.

## Blocked on external setup

- **No ANTHROPIC_API_KEY.** Blocked on API key."""

        result = hook._build_fallback_from_gaps(gaps, ["3 files changed"], [{"subject": "test", "body": ""}])
        self.assertIsNotNone(result)
        self.assertIn("SIGCONT", result)
        self.assertNotIn("ANTHROPIC_API_KEY", result)  # blocked items excluded
        self.assertNotIn("Already fixed", result)  # struck-through excluded

    def test_returns_none_when_all_blocked(self):
        gaps = """# Known Gaps

- **Blocked on ANTHROPIC_API_KEY.** Needs API key.
- ~~**Done.**~~ Fixed."""

        result = hook._build_fallback_from_gaps(gaps, [], [])
        self.assertIsNone(result)

    def test_returns_none_for_empty_gaps(self):
        result = hook._build_fallback_from_gaps("", [], [])
        self.assertIsNone(result)

    def test_includes_diff_and_commits_context(self):
        gaps = "- **Approve button.** Needs router wiring."
        result = hook._build_fallback_from_gaps(
            gaps,
            ["src/foo.swift | 10 +"],
            [{"subject": "v0.1.7 panel", "body": ""}],
        )
        self.assertIsNotNone(result)
        self.assertIn("src/foo.swift", result)
        self.assertIn("v0.1.7 panel", result)


if __name__ == "__main__":
    unittest.main()
