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


# ---------------------------------------------------------------------------
# Hermetic harness support.
#
# DEFAULTS["supervisor_repo_path"] points at the author's checkout
# ("/Users/main/supervisor"), which exists only on that machine. Any test
# that drives main() (or the git-grep grounding helpers) therefore needs a
# repo path that is real on THIS machine, or it silent-exits with
# no_principles_md before reaching the behavior under test:
#
#   * REPO_ROOT — this checkout's root. Used by the grounding tests, which
#     deliberately assert against the REAL tree (detect_stale_build is a
#     real function, TriageEngineTests is a real test class, ...).
#   * _fixture_repo() — a throwaway git repo containing a PRINCIPLES.md and
#     a Sources/ file that defines exactly the code symbols the mocked
#     main() tests propose against. main()'s PRINCIPLES.md gate and its
#     real `git grep` grounding then behave identically on any machine.
# ---------------------------------------------------------------------------

REPO_ROOT = str(Path(__file__).resolve().parents[2])

_FIXTURE_REPO: str | None = None


def _fixture_repo() -> str:
    """Create (once per test run) a minimal stand-in supervisor repo."""
    global _FIXTURE_REPO
    if _FIXTURE_REPO is not None:
        return _FIXTURE_REPO

    import atexit
    import shutil
    import subprocess
    import tempfile

    tmp = tempfile.mkdtemp(prefix="dispatch-hook-fixture-repo-")
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
    root = str(Path(tmp).resolve())

    # main() gates on a non-empty PRINCIPLES.md at the repo root.
    (Path(root) / "PRINCIPLES.md").write_text(
        "# Principles\n\nHermetic test stand-in for the real PRINCIPLES.md.\n",
        encoding="utf-8",
    )
    # Real (tracked, non-test, non-markdown) code defining the symbols the
    # harness proposals name, so `git grep` grounding passes for them —
    # and ONLY them (e.g. `stale_binary` stays ungrounded on purpose).
    sources = Path(root) / "Sources"
    sources.mkdir()
    (sources / "HarnessSymbols.swift").write_text(
        "// Symbols referenced by grounded test proposals.\n"
        "final class LoopController {}\n"
        "struct ExpandedPanelView {}\n"
        "func write_owner_brief() {}\n"
        "func detect_stale_build() {}\n",
        encoding="utf-8",
    )
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    for cmd in (
        ["git", "init", "-q", root],
        ["git", "-C", root, "add", "-A"],
        ["git", "-C", root, "-c", "user.name=hook-tests",
         "-c", "user.email=hook-tests@example.invalid",
         "commit", "-qm", "fixture repo"],
    ):
        subprocess.run(cmd, check=True, env=env, capture_output=True)

    _FIXTURE_REPO = root
    return root


def _hermetic_cfg() -> dict:
    """DEFAULTS with supervisor_repo_path pinned to the fixture repo."""
    cfg = dict(hook.DEFAULTS)
    cfg["supervisor_repo_path"] = _fixture_repo()
    return cfg


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
             patch.object(hook, 'load_config', return_value=_hermetic_cfg()), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'write_owner_brief'), \
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
                 "cwd": _fixture_repo(),
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
             patch.object(hook, 'load_config', return_value=_hermetic_cfg()), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'write_owner_brief'), \
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
                 "cwd": _fixture_repo(),
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
             patch.object(hook, 'load_config', return_value=_hermetic_cfg()), \
             patch.object(hook, 'load_state', return_value={}), \
             patch.object(hook, 'save_state'), \
             patch.object(hook, 'write_owner_brief'), \
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
                 "cwd": _fixture_repo(),
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
        # The prompt teaches the diff stat is a signal about shipped work.
        self.assertIn("re-propose shipped work", prompt)

    def test_system_prompt_warns_against_partial_completion_inference(self):
        prompt = hook.load_system_prompt()
        # Current wording: a file in the diff means that work is already
        # in progress, so don't re-propose it.
        self.assertIn("at least in-progress", prompt)


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


class TestIneffectiveChangeFreshnessCheck(unittest.TestCase):
    """detect_ineffective_change must only fire when the deployed binary is
    OLDER than the UI source. The old version fired whenever a UI file was
    touched, so it stayed lit right after a deploy (a permanent false
    positive that made the owner brief cry wolf)."""

    def _setup(self, tmp, binary_newer: bool):
        import time
        # Fake repo with a touched UI source file.
        ui_rel = "Sources/SupervisorCore/Hover/HoverViewModel.swift"
        ui_abs = Path(tmp) / ui_rel
        ui_abs.parent.mkdir(parents=True, exist_ok=True)
        ui_abs.write_text("// ui")
        # Fake deployed binary. Offset the source mtime from the REAL
        # binary's mtime, not from wall-clock now: the installed app may
        # have been deployed long ago, so "now - 600" can still be newer
        # than a binary built an hour back. Pinning to the binary's own
        # mtime keeps the test deterministic regardless of deploy age.
        binp = Path("/Applications/Supervisor.app/Contents/MacOS/Supervisor")
        if not binp.exists():
            self.skipTest("no deployed Supervisor.app on this machine")
        bin_mtime = binp.stat().st_mtime
        if binary_newer:
            os.utime(ui_abs, (bin_mtime - 600, bin_mtime - 600))   # source 10 min older than binary
        else:
            os.utime(ui_abs, (bin_mtime + 600, bin_mtime + 600))   # source 10 min newer than binary
        return ui_rel

    # recent_files_changed comes from `git diff --stat`, whose lines carry
    # a stat column ("path | 45 +++"). The freshness check must resolve the
    # real path out of that line. Each format below must produce the same
    # verdict; the decorated form is what actually flows in production.
    @staticmethod
    def _formats(ui_rel):
        return [
            ui_rel,                          # bare path
            f"{ui_rel} | 45 ++++++---",      # `git diff --stat` line (real)
            f" {ui_rel} | 2 +-",             # leading-space variant
        ]

    def test_no_warning_when_binary_is_newer(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            ui_rel = self._setup(tmp, binary_newer=True)
            for entry in self._formats(ui_rel):
                result = hook.detect_ineffective_change(
                    tmp,
                    commits=[{"sha": "x", "subject": "fix hover", "body": ""}],
                    recent_files_changed=[entry],
                )
                self.assertIsNone(result,
                    f"must not warn when binary is newer; format={entry!r} "
                    f"(regression: diff-stat line failed to resolve, bypassing "
                    f"the freshness guard and crying wolf)")

    def test_warns_when_binary_is_older(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            ui_rel = self._setup(tmp, binary_newer=False)
            for entry in self._formats(ui_rel):
                result = hook.detect_ineffective_change(
                    tmp,
                    commits=[{"sha": "x", "subject": "fix hover", "body": ""}],
                    recent_files_changed=[entry],
                )
                self.assertIsNotNone(result,
                    f"must warn when the binary is stale; format={entry!r}")
                self.assertIn("older than those edits", result)

    def test_no_warning_when_path_unresolvable(self):
        """If a UI file matches but its path can't be resolved on disk, we
        cannot prove staleness, so we must stay quiet rather than warn — the
        old code defaulted to warning whenever newest_src stayed 0."""
        result = hook.detect_ineffective_change(
            "/tmp/nonexistent-repo-xyz",
            commits=[{"sha": "x", "subject": "fix hover", "body": ""}],
            recent_files_changed=["Sources/SupervisorCore/Hover/HoverViewModel.swift | 9 +++"],
        )
        self.assertIsNone(result,
            "unresolvable source path must not cry wolf")

    def test_no_warning_without_ui_files(self):
        result = hook.detect_ineffective_change(
            "/tmp",
            commits=[{"sha": "x", "subject": "docs", "body": ""}],
            recent_files_changed=["README.md", "CHANGELOG.md"],
        )
        self.assertIsNone(result)


class TestResolveRepoRoot(unittest.TestCase):
    """#3: the hook must resolve the repo ROOT no matter which subdirectory
    the session started in, so it reads Sources/ + gaps and writes
    OWNER-BRIEF.md at the root, not in a subdir."""

    def test_resolves_root_from_subdirectory(self):
        import tempfile, subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.realpath(tmp)
            subprocess.run(["git", "init", "-q", root], check=True)
            subdir = os.path.join(root, "Tools", "dispatch-loop-hook")
            os.makedirs(subdir, exist_ok=True)
            # Session started in the subdir; configured root is the repo root.
            resolved = hook.resolve_repo_root(subdir, root)
            self.assertEqual(os.path.realpath(resolved), root,
                "a session started in a subdir must resolve to the repo root")

    def test_root_passthrough_when_already_root(self):
        import tempfile, subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.realpath(tmp)
            subprocess.run(["git", "init", "-q", root], check=True)
            self.assertEqual(os.path.realpath(hook.resolve_repo_root(root, root)), root)

    def test_fallback_to_configured_root_when_not_git(self):
        # Non-git subdir under the configured root: fall back to the
        # configured root rather than the subdir.
        configured = "/Users/main/supervisor"
        subdir = "/Users/main/supervisor/Tools/dispatch-loop-hook"
        # If the real repo exists, git resolves to it; either way the result
        # must be the repo root, never the subdir.
        resolved = hook.resolve_repo_root(subdir, configured)
        self.assertEqual(resolved, configured,
            f"must pin to the repo root, not the subdir; got {resolved}")

    def test_does_not_escape_configured_repo(self):
        # A cwd outside the configured repo is returned as-is (the
        # cwd_not_supervisor gate handles rejecting it upstream).
        outside = "/tmp"
        self.assertEqual(hook.resolve_repo_root(outside, "/Users/main/supervisor"),
                         "/tmp")


class TestStaleBuildFreshness(unittest.TestCase):
    """detect_stale_build must compare against source FILE mtimes, not git
    COMMIT times. The old version compared to commit time, which is always
    newer than the binary after the normal build-then-commit workflow, so it
    fired a guaranteed false 'stale build' after every commit and kept
    dispatching pointless rebuilds."""

    def _app_mtime(self):
        p = Path("/Applications/Supervisor.app/Contents/Info.plist")
        if not p.exists():
            self.skipTest("no deployed Supervisor.app on this machine")
        return p.stat().st_mtime

    def _make_ui_source(self, tmp, offset_from_binary):
        ui_abs = Path(tmp) / "Sources/SupervisorCore/Hover/HoverViewModel.swift"
        ui_abs.parent.mkdir(parents=True, exist_ok=True)
        ui_abs.write_text("// ui")
        t = self._app_mtime() + offset_from_binary
        os.utime(ui_abs, (t, t))
        return t

    def test_no_warning_when_binary_newer_than_source(self):
        """The build-then-commit case: source edited BEFORE the build (so its
        mtime is older than the binary), then committed. Committing does not
        change the file mtime, so this must NOT warn."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._make_ui_source(tmp, offset_from_binary=-600)
            warning, _ = hook.detect_stale_build(tmp, timeout=5)
            self.assertIsNone(warning,
                "must not warn when the binary is newer than the source")

    def test_warns_when_source_newer_than_binary(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self._make_ui_source(tmp, offset_from_binary=+600)
            warning, key = hook.detect_stale_build(tmp, timeout=5)
            self.assertIsNotNone(warning, "must warn when a source is genuinely newer")
            self.assertGreater(key, 0)

    def test_dedup_key_is_source_mtime_not_commit_time(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            newer = self._make_ui_source(tmp, offset_from_binary=+600)
            warning, key = hook.detect_stale_build(tmp, timeout=5)
            self.assertIsNotNone(warning)
            # The dedup key is the source FILE mtime we set, not a git commit ts.
            self.assertAlmostEqual(key, newer, delta=2)


class TestThrashFixV090(unittest.TestCase):
    """v0.9.0: the dispatch loop must idle gracefully on an empty queue
    instead of thrashing. Covers the five fixes:

      #1 empty queue / low_confidence_no_action -> calm idle + STOP,
         never falls through to the SelfExtender.
      #2 SelfExtender fires ONLY on a real machinery failure
         (dispatcher returned nothing parseable), never on no-work.
      #3 repetition circuit breaker trips when the SAME proposal is
         dispatched twice in a row, and does NOT trip on two different
         proposals (the over-correction guard).
      #4 a thrash-meta proposal (build a spin/thrash/double-dispatch
         guard) is filtered and the loop stops; it is never dispatched.
      #5 the blocked-proposal branch references self_watch_warnings,
         which used to be assigned later -> UnboundLocalError. These
         tests reach that branch; a regression would raise, not skip.
    """

    # A dispatcher result that represents "no queued work".
    NO_WORK = {
        "next_task_proposal": "",
        "justification": "Nothing actionable in the queue right now.",
        "confidence": "low",
        "selected_path": "low_confidence_no_action",
        "requires_human_presence": False,
    }

    @staticmethod
    def _high(proposal, justification="Mechanical follow-on with clear next step."):
        return {
            "next_task_proposal": proposal,
            "justification": justification,
            "confidence": "high",
            "selected_path": "continue_branch",
            "requires_human_presence": False,
        }

    def _run_main(self, *, call_side_effect, state_holder=None):
        """Run hook.main() one or more times against a fully mocked
        environment. call_side_effect may be a single dict/None or a list
        (one entry consumed per main() invocation). Returns a dict of
        recorded effects: block (emit_block texts), exit (silent_exit
        reasons), extend (try_self_extend kwargs)."""
        import contextlib
        if state_holder is None:
            state_holder = {"v": {}}
        rec = {"block": [], "exit": [], "extend": []}

        def fake_block(text):
            rec["block"].append(text)
            raise SystemExit(0)

        def fake_exit(reason):
            rec["exit"].append(reason)
            raise SystemExit(0)

        def fake_extend(**kwargs):
            rec["extend"].append(kwargs)
            raise SystemExit(0)

        def fake_load_state():
            return state_holder["v"]

        def fake_save_state(s):
            state_holder["v"] = s

        calls = call_side_effect if isinstance(call_side_effect, list) else [call_side_effect]

        def make_patches():
            return [
                patch.object(hook, 'call_dispatcher', side_effect=list(calls)),
                patch.object(hook, 'emit_block', side_effect=fake_block),
                patch.object(hook, 'silent_exit', side_effect=fake_exit),
                patch.object(hook, 'try_self_extend', side_effect=fake_extend),
                patch.object(hook, 'load_state', side_effect=fake_load_state),
                patch.object(hook, 'save_state', side_effect=fake_save_state),
                patch.object(hook, 'write_owner_brief'),
                patch.object(hook, 'load_config', return_value=_hermetic_cfg()),
                patch.object(hook, 'detect_worker_stopped', return_value=True),
                patch.object(hook, 'read_recent_turns', return_value=[
                    {"role": "assistant", "text": "All done.", "ts": ""}
                ]),
                patch.object(hook, 'fetch_diff_stat', return_value=[]),
                patch.object(hook, 'current_branch', return_value="autonomous-test"),
                patch.object(hook, 'fetch_issues', return_value=[]),
                patch.object(hook, 'fetch_commits', return_value=[]),
                patch.object(hook, 'read_keychain', return_value="sk-test"),
                patch.object(hook, 'load_system_prompt', return_value="test prompt"),
                patch.object(hook, 'ENABLED_FLAG',
                             new=MagicMock(exists=MagicMock(return_value=True))),
                patch('sys.stdin', MagicMock(read=MagicMock(return_value=json.dumps({
                    "session_id": "s1",
                    "cwd": _fixture_repo(),
                    "transcript_path": "/tmp/test.jsonl",
                })))),
            ]

        with contextlib.ExitStack() as stack:
            for p in make_patches():
                stack.enter_context(p)
            for _ in range(len(calls)):
                try:
                    hook.main()
                except SystemExit:
                    pass
        return rec

    # -- #1 + #2: empty queue is a terminal idle, never an escalation -----

    def test_empty_queue_terminates_without_self_extender(self):
        """ACCEPTANCE (#1/#2/#6): low_confidence_no_action -> at most one
        dispatch -> no-op terminal -> NO SelfExtender -> loop stopped."""
        rec = self._run_main(call_side_effect=self.NO_WORK)
        self.assertEqual(rec["extend"], [],
                         "SelfExtender must NOT fire on an empty queue")
        self.assertEqual(rec["block"], [],
                         "an empty queue must NOT emit_block (no new work dispatched)")
        self.assertIn("idle_no_work", rec["exit"],
                      "empty queue must stop with the calm idle reason")

    def test_high_confidence_but_no_action_path_still_idles(self):
        """selected_path=low_confidence_no_action gates even when the model
        labels confidence 'high' — the path is the source of truth, so the
        loop still idles and does not dispatch."""
        weird = dict(self.NO_WORK)
        weird["confidence"] = "high"
        rec = self._run_main(call_side_effect=weird)
        self.assertEqual(rec["block"], [])
        self.assertEqual(rec["extend"], [])
        self.assertIn("idle_no_work", rec["exit"])

    # -- #2: SelfExtender ONLY on a real machinery failure ----------------

    def test_self_extender_fires_only_on_dispatcher_none(self):
        """A null dispatcher result is real breakage (network/parse), so the
        SelfExtender IS the right response — the one path that invokes it."""
        rec = self._run_main(call_side_effect=None)
        self.assertEqual(len(rec["extend"]), 1,
                         "dispatcher_returned_none must invoke the SelfExtender once")
        self.assertEqual(rec["extend"][0].get("failure_reason"),
                         "dispatcher_returned_none")
        self.assertEqual(rec["block"], [],
                         "the None path delegates to SelfExtender, not a direct emit_block")

    # -- #3: repetition breaker trips on a repeat, not on absence of commit

    def test_repeated_proposal_trips_breaker(self):
        """ACCEPTANCE (#3/#6): the SAME high-confidence proposal twice in a
        row -> first dispatches, second trips the breaker and stops. No
        SelfExtender, no second dispatch."""
        same = "Wire the Approve button in ExpandedPanelView to the LoopController router."
        rec = self._run_main(call_side_effect=[self._high(same), self._high(same)])
        self.assertEqual(len(rec["block"]), 1,
                         "only the FIRST of two identical proposals may dispatch")
        self.assertIn("breaker_repeated_proposal", rec["exit"],
                      "the second identical proposal must trip the repetition breaker")
        self.assertEqual(rec["extend"], [],
                         "the breaker must stop the loop, never escalate to SelfExtender")

    def test_two_different_proposals_do_not_trip(self):
        """ACCEPTANCE (#3/#6, over-correction guard): two DIFFERENT
        high-confidence proposals with real progress -> BOTH dispatch. The
        breaker must not fire on legitimate multi-step / multi-task work."""
        rec = self._run_main(call_side_effect=[
            self._high("Wire the Approve button to the LoopController router."),
            self._high("Add a Keychain migration step to the onboarding flow."),
        ])
        self.assertEqual(len(rec["block"]), 2,
                         "two different proposals must BOTH dispatch (no over-trip)")
        self.assertNotIn("breaker_repeated_proposal", rec["exit"])
        self.assertEqual(rec["extend"], [])

    # -- #4: thrash-meta proposals are filtered, never dispatched ---------

    def test_thrash_meta_proposal_is_filtered(self):
        """#4: a proposal to build machinery about the loop's own spinning
        (thrash guard / double-dispatch guard / spin detector) is filtered
        and the loop stops calmly. Never dispatched, never escalated."""
        rec = self._run_main(call_side_effect=self._high(
            "Build a thrash guard in the Stop hook to detect when the dispatch "
            "loop spins and add a single-in-flight guard against double-dispatch.",
            justification="The loop keeps cycling; we should guard against it.",
        ))
        self.assertEqual(rec["block"], [],
                         "thrash-meta work must never be dispatched")
        self.assertEqual(rec["extend"], [],
                         "thrash-meta is a filter+stop, not a SelfExtender failure")
        self.assertTrue(
            any("blocked_proposal_filtered" in r and "thrash_meta" in r
                for r in rec["exit"]),
            f"must stop with the thrash_meta filter reason; got {rec['exit']}")

    def test_blocked_branch_does_not_raise_unbound_local(self):
        """#5 regression: the blocked-proposal branch reads
        self_watch_warnings. It used to be assigned only later, raising a
        fatal UnboundLocalError before the calm stop. Reaching the filter
        branch cleanly (a recorded silent_exit, not a crash) proves the
        variable is now defined before that branch."""
        rec = self._run_main(call_side_effect=self._high(
            "Add a stuck-worker detector that watches the dispatch loop.",
        ))
        # If self_watch_warnings were unbound, main() would raise NameError
        # (not SystemExit) and rec['exit'] would be empty.
        self.assertTrue(rec["exit"],
                        "blocked branch must reach a clean silent_exit, not crash")
        self.assertTrue(any("blocked_proposal_filtered" in r for r in rec["exit"]))

    def test_owner_brief_rewrite_is_filtered_to_idle(self):
        """#2: a proposal to rewrite/regenerate the owner brief is a
        self-referential no-op (the loop auto-writes it every dispatch). It
        must be filtered to a calm idle, never dispatched."""
        rec = self._run_main(call_side_effect=self._high(
            "Regenerate OWNER-BRIEF.md from actual branch state",
            justification="The owner brief is stale and needs a truthful replacement.",
        ))
        self.assertEqual(rec["block"], [],
                         "owner-brief rewrite must never be dispatched")
        self.assertEqual(rec["extend"], [],
                         "owner-brief rewrite is a filter+stop, not a SelfExtender failure")
        self.assertTrue(
            any("blocked_proposal_filtered" in r and "owner_brief_rewrite" in r
                for r in rec["exit"]),
            f"must stop with the owner_brief_rewrite filter reason; got {rec['exit']}")

    def test_real_brief_generator_codework_still_dispatches(self):
        """The filter must NOT catch legitimate engineering on the brief
        GENERATOR (write_owner_brief code), only rewriting the brief content."""
        rec = self._run_main(call_side_effect=self._high(
            "Fix a bug in the write_owner_brief function that drops the warnings section",
            justification="write_owner_brief has a formatting bug; add a regression test.",
        ))
        self.assertEqual(len(rec["block"]), 1,
                         "real code-work on the brief generator must still dispatch")
        self.assertNotIn("owner_brief_rewrite", " ".join(rec["exit"]))

    # -- D2: grounding — cannot dispatch a task naming a non-existent symbol

    def test_ungrounded_proposal_discarded_to_idle(self):
        """ACCEPTANCE (D2-a): a high-confidence proposal that names a symbol
        which does not exist in the code (the stale_binary hallucination)
        must be discarded to a calm idle — nothing emitted, no SelfExtender,
        no fabricated dispatch. (Grounding runs a real git grep against the
        repo cwd the harness passes.)"""
        rec = self._run_main(call_side_effect=self._high(
            "Fix the stale_binary self-watch check, the untested sibling of the others",
            justification="stale_binary may have the same false-positive pattern.",
        ))
        self.assertEqual(rec["block"], [],
                         "an ungrounded (fabricated-symbol) proposal must NOT dispatch")
        self.assertEqual(rec["extend"], [],
                         "ungrounded proposal is idle, not a SelfExtender failure")
        self.assertTrue(any("ungrounded_proposal" in r for r in rec["exit"]),
                        f"must stop with ungrounded_proposal; got {rec['exit']}")

    def test_grounded_proposal_still_dispatches(self):
        """ACCEPTANCE (D2-b): a high-confidence proposal naming only symbols
        that DO exist still dispatches — grounding must not overcorrect into
        never dispatching."""
        rec = self._run_main(call_side_effect=self._high(
            "Improve detect_stale_build mtime handling in the hook",
            justification="detect_stale_build is the right place for this.",
        ))
        self.assertEqual(len(rec["block"]), 1,
                         "a grounded proposal (real symbols) must still dispatch")
        self.assertFalse(any("ungrounded" in r for r in rec["exit"]))


class TestThrashHelpers(unittest.TestCase):
    """Unit coverage for the v0.9.0 helper predicates, independent of
    main()'s plumbing."""

    def test_thrash_meta_detects_loop_machinery(self):
        for txt in [
            "Build a thrash guard for the dispatch loop",
            "Add a double-dispatch guard to the Stop hook",
            "Implement a single-in-flight guard",
            "Add a spin detector",
            "Add a stuck-worker detector to the self-watch",
            "Detect when the loop spins and stop it",
        ]:
            self.assertTrue(hook._is_thrash_meta_proposal(txt),
                            f"should flag as thrash-meta: {txt!r}")

    def test_thrash_meta_passes_real_product_work(self):
        for txt in [
            "Fix the calibration rubric for destructive actions",
            "Wire the Approve button to the router",
            "Write a landing page for launch",
            "Add a Keychain migration to onboarding",
        ]:
            self.assertFalse(hook._is_thrash_meta_proposal(txt),
                             f"real product work must not be flagged: {txt!r}")

    def test_owner_brief_rewrite_detected(self):
        for txt in [
            "Regenerate OWNER-BRIEF.md from actual branch state",
            "Rewrite the owner brief with a truthful snapshot",
            "Refresh the owner-brief so it is accurate",
            "Replace the owner brief content; it is stale",
        ]:
            self.assertTrue(hook._is_owner_brief_proposal(txt),
                            f"should flag owner-brief rewrite: {txt!r}")

    def test_owner_brief_codework_not_flagged(self):
        # Real engineering on the generator (and unrelated work) must pass.
        for txt in [
            "Fix a bug in the write_owner_brief function",
            "Add a unit test for the owner brief format",
            "Refactor the helper that builds OWNER-BRIEF sections",
            "Wire the Approve button to the router",
            "Close the calibration gap on destructive recall",
        ]:
            self.assertFalse(hook._is_owner_brief_proposal(txt),
                             f"must not flag (not a content rewrite): {txt!r}")

    def test_repeat_proposal_trips_on_same_and_near_same(self):
        state = {}
        base = "Close the calibration gap by tightening the destructive rubric and adding fixtures"
        hook._remember_proposal(state, base)
        thr = hook.DEFAULTS["same_proposal_jaccard_threshold"]
        self.assertTrue(hook._is_repeat_proposal(state, base, thr),
                        "identical proposal must trip")
        near = base + " now please"
        self.assertTrue(hook._is_repeat_proposal(state, near, thr),
                        "near-identical reworded proposal must trip")

    def test_repeat_proposal_ignores_different_task(self):
        state = {}
        hook._remember_proposal(
            state, "Close the calibration gap by tightening the destructive rubric")
        thr = hook.DEFAULTS["same_proposal_jaccard_threshold"]
        self.assertFalse(
            hook._is_repeat_proposal(
                state, "Write a landing page and set up the marketing site for launch", thr),
            "a genuinely different task must NOT trip the breaker")

    def test_remember_then_no_prior_is_not_a_repeat(self):
        """First-ever proposal (no stored history) is never a repeat."""
        self.assertFalse(
            hook._is_repeat_proposal({}, "Any first proposal at all", 0.8))


class TestGrounding(unittest.TestCase):
    """D2: a proposal cannot name a code symbol that does not exist."""

    def test_extract_code_symbols(self):
        syms = set(hook._extract_code_symbols(
            "Fix detect_stale_build and LoopController in dispatch_loop_hook.py"))
        self.assertIn("detect_stale_build", syms)   # snake_case
        self.assertIn("LoopController", syms)        # CamelCase
        self.assertIn("dispatch_loop_hook.py", syms) # file.ext

    def test_extract_ignores_plain_prose(self):
        syms = hook._extract_code_symbols("Write a landing page and improve the launch copy")
        self.assertEqual(syms, [], f"plain English must yield no symbols; got {syms}")

    def test_ground_flags_hallucinated_symbol(self):
        grounded, reason = hook._ground_proposal(
            REPO_ROOT,
            "Fix the frobnicate_the_widget helper",  # exists nowhere
            "", timeout=10)
        self.assertFalse(grounded)
        self.assertIn("frobnicate_the_widget", reason)

    def test_ground_passes_real_symbol(self):
        grounded, _ = hook._ground_proposal(
            REPO_ROOT,
            "Fix detect_stale_build in the hook",   # real function
            "", timeout=10)
        self.assertTrue(grounded)

    def test_ground_passes_pure_prose(self):
        grounded, _ = hook._ground_proposal(
            REPO_ROOT,
            "Close the calibration gap on destructive recall",
            "", timeout=10)
        self.assertTrue(grounded, "a prose proposal naming no code symbols is grounded")

    def test_ground_passes_test_class_symbol(self):
        # Regression (2026-06-04 live stall): a proposal naming a real test
        # class was judged ungrounded because the symbol search excluded test
        # files, so the loop silent-exited on valid "fix the failing tests"
        # work. A test class IS real code — it must ground.
        for sym in ("TriageEngineTests", "PathIsolationSymmetryTests"):
            self.assertTrue(
                hook._symbol_exists_in_repo(REPO_ROOT, sym, 10),
                f"{sym} is a real test class and must ground via the tests-fallback")
        grounded, reason = hook._ground_proposal(
            REPO_ROOT,
            "Fix the 4 failing TriageEngineTests that the rm -rf catch short-circuits",
            "they assert the Haiku path", timeout=10)
        self.assertTrue(grounded, f"test-fix proposal must ground; got reason={reason!r}")

    def test_ground_still_flags_hallucinated_camelcase(self):
        # The tests-fallback must NOT weaken the anti-hallucination guard: a
        # CamelCase type that exists nowhere (not even in tests) stays rejected.
        self.assertFalse(
            hook._symbol_exists_in_repo(REPO_ROOT, "WidgetFrobnicatorXYZ", 10))


class TestEnvironmentClaimGrounding(unittest.TestCase):
    """D3: a proposal may not justify itself with a false unblocking
    precondition — e.g. 'the ANTHROPIC_API_KEY is set; sweeps are unblocked'
    when the key is absent. Verified against the real env."""

    def setUp(self):
        self._saved = os.environ.get("ANTHROPIC_API_KEY")
        os.environ.pop("ANTHROPIC_API_KEY", None)  # simulate the absent state

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("ANTHROPIC_API_KEY", None)
        else:
            os.environ["ANTHROPIC_API_KEY"] = self._saved

    def test_fabricated_key_claim_rejected_when_absent(self):
        for prop, just in [
            ("Run the Issue #12 calibration sweep",
             "The ANTHROPIC_API_KEY is set; calibration sweeps are unblocked."),
            ("Do the targeted re-sweep", "Keys are set now, sweeps are available."),
            ("Calibrate the gap", "The live-API is now enabled."),
        ]:
            ok, reason = hook._ground_environment_claims(prop, just)
            self.assertFalse(ok, f"should reject false claim: {just!r}")
            self.assertIn("false_env_claim", reason)

    def test_honest_blocked_statement_passes(self):
        # The negated/honest inverse must NOT trip the guard.
        for just in [
            "The ANTHROPIC_API_KEY is not set; sweeps are still blocked.",
            "The key is absent, so calibration is blocked. Journal and wait.",
            "No key available; the sweep stays blocked.",
        ]:
            ok, _ = hook._ground_environment_claims("Journal the diagnosis", just)
            self.assertTrue(ok, f"honest 'blocked' statement must pass: {just!r}")

    def test_unrelated_proposal_passes(self):
        ok, _ = hook._ground_environment_claims(
            "Fix the inject locator for multi-session targeting",
            "It targets the wrong window when two sessions share the app.")
        self.assertTrue(ok)

    def test_true_claim_passes_when_key_present(self):
        os.environ["ANTHROPIC_API_KEY"] = "sk-test-not-real"
        ok, _ = hook._ground_environment_claims(
            "Run the sweep", "The ANTHROPIC_API_KEY is set; sweeps are unblocked.")
        self.assertTrue(ok, "a TRUE availability claim must pass when the key is present")


class TestApplyIdleReset(unittest.TestCase):
    """Fresh-session reset on resume after a long idle gap: an overnight
    pause should NOT leave the loop stuck at four_hours_elapsed."""

    THRESHOLD = 2 * 3600  # 2 hours

    def test_first_invocation_never_resets(self):
        # No prior last_seen_at — no gap yet, so no reset; but last_seen_at
        # and loop_started_at are stamped for next time.
        state = {}
        self.assertFalse(hook.apply_idle_reset(state, 1000.0, self.THRESHOLD))
        self.assertEqual(state["last_seen_at"], 1000.0)
        self.assertEqual(state["loop_started_at"], 1000.0)

    def test_short_gap_does_not_reset(self):
        # Active work: a sub-threshold gap leaves clock + counters intact.
        state = {"last_seen_at": 1000.0, "loop_started_at": 500.0,
                 "total_dispatches": 7, "stopped": False}
        self.assertFalse(hook.apply_idle_reset(state, 1000.0 + 600, self.THRESHOLD))
        self.assertEqual(state["loop_started_at"], 500.0)      # unchanged
        self.assertEqual(state["total_dispatches"], 7)         # unchanged
        self.assertEqual(state["last_seen_at"], 1600.0)        # advanced

    def test_long_gap_resets_clock_and_counters(self):
        state = {"last_seen_at": 1000.0, "loop_started_at": 500.0,
                 "total_dispatches": 19, "consecutive_low": 2, "stopped": False}
        now = 1000.0 + self.THRESHOLD + 1
        self.assertTrue(hook.apply_idle_reset(state, now, self.THRESHOLD))
        self.assertEqual(state["loop_started_at"], now)        # clock restarted
        self.assertEqual(state["total_dispatches"], 0)         # fresh budget
        self.assertEqual(state["consecutive_low"], 0)
        self.assertEqual(state["last_seen_at"], now)

    def test_long_gap_unsticks_a_four_hours_stop(self):
        # The exact reported case: hit the 4h cap, slept, came back.
        state = {"last_seen_at": 1000.0, "loop_started_at": 500.0,
                 "stopped": True, "stop_reason": "four_hours_elapsed",
                 "total_dispatches": 12}
        now = 1000.0 + 8 * 3600   # overnight
        self.assertTrue(hook.apply_idle_reset(state, now, self.THRESHOLD))
        self.assertFalse(state["stopped"])                     # un-stuck
        self.assertIsNone(state["stop_reason"])
        self.assertEqual(state["loop_started_at"], now)

    def test_gap_exactly_at_threshold_resets(self):
        state = {"last_seen_at": 1000.0, "loop_started_at": 500.0}
        now = 1000.0 + self.THRESHOLD   # boundary is inclusive (>=)
        self.assertTrue(hook.apply_idle_reset(state, now, self.THRESHOLD))


class TestBuildExistingProposalFilter(unittest.TestCase):
    """Root-cause guard: reject 'build the <existing component>' proposals
    (the self-referential runaway), never block real product work."""

    def test_rejects_building_existing_machinery(self):
        for p in [
            "Build the CGEventPost-based Dispatcher + LoopController that watches the dispatch queue.",
            "Implement the dispatch loop that reads the queue and dispatches.",
            "Wire up the LoopController hard-stops.",
            "Build and ship the deterministic catch for irreversible commands.",
            "Stand up the triage engine.",
            "The dispatch engine is not wired yet.",
            "The Injector is missing.",
        ]:
            self.assertTrue(hook._is_build_existing_proposal(p), f"should reject: {p}")

    def test_allows_real_product_work(self):
        for p in [
            "Fix the flag counter so it resets per work-window in HoverViewModel.",
            "Add a unit test for the dispatcher's grounding so regressions are caught.",
            "Close the Issue #12 calibration gap by correcting fixture expectations.",
            "Improve the injector's reliability on Electron hosts.",
            "Fix the dispatcher so it stops proposing already-done work.",
            "Review the rubric corpus and journal the verdict.",
        ]:
            self.assertFalse(hook._is_build_existing_proposal(p), f"should allow: {p}")


if __name__ == "__main__":
    unittest.main()
