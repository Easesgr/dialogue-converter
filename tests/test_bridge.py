import concurrent.futures
import json
import multiprocessing
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'bridge.py'
sys.path.insert(0, str(MODULE.parent))
import bridge


def write_records(path, records, append=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a' if append else 'w', encoding='utf-8') as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + '\n')
    return path


def codex_meta(identifier):
    return {'type': 'session_meta', 'payload': {'id': identifier, 'cwd': '/project'}}


def codex_message(role, text, identifier=None, phase=None):
    payload = {'type': 'message', 'role': role, 'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}]}
    if identifier:
        payload['id'] = identifier
    if phase:
        payload['phase'] = phase
    return {'type': 'response_item', 'payload': payload}


def claude_message(role, text, identifier='c1', message_id=None, stop=None, **extra):
    message = {'role': role, 'content': [{'type': 'text', 'text': text}]}
    if message_id:
        message['id'] = message_id
    if stop:
        message['stop_reason'] = stop
    return {'type': role, 'sessionId': identifier, 'cwd': '/project', 'message': message, **extra}


def event(kind, **extra):
    return {'type': 'event_msg', 'payload': {'type': kind, **extra}}


def parallel_prepare(arguments):
    root, codex, claude, request = arguments
    return bridge.Bridge(root, codex, claude).prepare(request)['packet_id']


def parallel_mark(arguments):
    root, codex, claude, identifier = arguments
    return bridge.Bridge(root, codex, claude).mark({'packet_id': identifier})


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.app = bridge.Bridge(self.root / 'state', self.root / 'codex', self.root / 'claude')
        self.c = write_records(self.root / 'claude/projects/project/c.jsonl', [
            claude_message('user', '保留要求'),
            claude_message('assistant', '实施方案', message_id='a1', stop='end_turn'),
        ])
        self.g = write_records(self.root / 'codex/sessions/2026/01/01/g.jsonl', [
            codex_meta('g1'), codex_message('user', '原有目标上下文', 'u1'),
            codex_message('assistant', '目标已有结果', 'ga1', 'final_answer'), event('task_complete'),
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def request(self, reverse=False, target=True):
        request = {'source_path': str(self.g if reverse else self.c),
                   'target_provider': 'claude' if reverse else 'gpt', 'intent': 'implement'}
        if target:
            request['target_path'] = str(self.c if reverse else self.g)
        return request

    def test_bidirectional_explicit_delivery_and_incremental_delta(self):
        first = self.app.prepare(self.request())
        again = self.app.prepare(self.request())
        self.assertEqual(first['new_message_count'], 2)
        self.assertEqual(again['new_message_count'], 2)
        self.assertFalse(self.app.status({'packet_id': first['packet_id']})['marked'])
        self.app.mark({'packet_id': first['packet_id']})
        self.assertEqual(self.app.prepare(self.request())['new_message_count'], 0)
        write_records(self.c, [claude_message('user', '新增要求'), claude_message('assistant', '修订方案', message_id='a2', stop='end_turn')], True)
        delta = self.app.prepare(self.request())
        self.assertEqual(delta['new_message_count'], 2)
        self.assertNotIn('保留要求', delta['preview'])
        self.assertIn('修订方案', delta['preview'])
        reverse = self.app.prepare(self.request(reverse=True))
        self.assertEqual(reverse['new_message_count'], 2)
        self.app.mark({'packet_id': reverse['packet_id']})
        write_records(self.g, [codex_message('assistant', '实施完成', 'ga2', 'final_answer'), event('task_complete')], True)
        reverse_delta = self.app.prepare(self.request(reverse=True))
        self.assertEqual(reverse_delta['new_message_count'], 1)
        self.assertIn('实施完成', reverse_delta['preview'])

    def test_pending_and_out_of_order_marks_do_not_skip(self):
        early = self.app.prepare(self.request())
        write_records(self.c, [claude_message('user', '第三条')], True)
        later = self.app.prepare(self.request())
        self.assertEqual(later['new_message_count'], 3)
        self.app.mark({'packet_id': later['packet_id']})
        self.app.mark({'packet_id': early['packet_id']})
        self.assertEqual(self.app.status({'packet_id': early['packet_id']})['delivered_until'], 3)
        self.assertEqual(self.app.prepare(self.request())['new_message_count'], 0)
        write_records(self.c, [claude_message('user', '第四条')], True)
        pending = self.app.prepare(self.request())
        self.assertEqual(self.app.prepare(self.request())['new_message_count'], 1)
        self.assertFalse(self.app.status({'packet_id': pending['packet_id']})['marked'])

    def test_targets_and_unbound_new_targets_are_distinct(self):
        first = self.app.prepare(self.request())
        self.app.mark({'packet_id': first['packet_id']})
        other = write_records(self.root / 'other.jsonl', [codex_meta('g2')])
        req = self.request() | {'target_path': str(other)}
        self.assertEqual(self.app.prepare(req)['new_message_count'], 2)
        fresh = self.app.prepare(self.request(target=False))
        self.app.mark({'packet_id': fresh['packet_id']})
        self.assertEqual(self.app.prepare(self.request(target=False))['new_message_count'], 2)
        self.assertIsNone(fresh['target'])

    def test_modified_same_size_history_resets_and_old_packet_cannot_mark(self):
        first = self.app.prepare(self.request())
        self.app.mark({'packet_id': first['packet_id']})
        pending = self.app.prepare(self.request())
        self.c.write_text(self.c.read_text().replace('保留要求', '替换要求'))
        with self.assertRaisesRegex(ValueError, '源文件'):
            self.app.mark({'packet_id': pending['packet_id']})
        reset = self.app.prepare(self.request())
        self.assertEqual(reset['new_message_count'], 2)
        self.assertTrue(any('重置' in w for w in reset['warnings']))
        with self.assertRaisesRegex(ValueError, '已改变'):
            self.app.mark({'packet_id': pending['packet_id']})

    def test_truncation_invalidates_even_when_visible_messages_unchanged(self):
        write_records(self.c, [{'type': 'system', 'content': 'unused'}], True)
        first = self.app.prepare(self.request())
        self.app.mark({'packet_id': first['packet_id']})
        self.c.write_text('\n'.join(self.c.read_text().splitlines()[:-1]) + '\n')
        result = self.app.prepare(self.request())
        self.assertEqual(result['new_message_count'], 2)
        self.assertTrue(any('重置' in w for w in result['warnings']))

    def test_long_reference_keeps_exact_full_visible_text(self):
        long = '完整要求α\n' * 20000
        write_records(self.c, [claude_message('user', long), claude_message('assistant', '最新方案', stop='end_turn')])
        result = self.app.prepare(self.request())
        self.assertLessEqual(len(result['preview']), bridge.PREVIEW_LIMIT)
        self.assertIn(result['artifact_path'], result['preview'])
        self.assertIn(long, result['full_text'])
        self.assertEqual(Path(result['artifact_path']).read_text(), result['full_text'])
        self.assertIn('最新方案', result['preview'])
        exported = self.app.load({'file_path': str(Path(result['artifact_path']).with_name('messages.json'))})
        self.assertIn(long, exported['text'])

    def test_partial_or_malformed_jsonl_never_falls_back_to_raw(self):
        with self.c.open('a') as f:
            f.write('{"type":"assistant","private":"SECRET')
        doc = bridge.read_transcript(self.c)
        self.assertEqual(len(doc.messages), 2)
        self.assertFalse(doc.complete)
        self.assertTrue(doc.warnings)
        self.assertNotIn('SECRET', json.dumps(doc.messages))
        self.c.write_text('{"payload":{"secret":"private"')
        with self.assertRaisesRegex(ValueError, '未找到'):
            self.app.load({'file_path': str(self.c)})

    def test_visible_filter_dedupe_and_repeated_user_requests(self):
        records = [codex_meta('g1'), codex_message('system', 'SECRET'),
                   codex_message('developer', 'SECRET'), codex_message('assistant', 'SECRET', 'r1', 'analysis'),
                   {'type': 'response_item', 'payload': {'type': 'reasoning', 'content': [{'type': 'text', 'text': 'SECRET'}]}},
                   {'type': 'response_item', 'payload': {'type': 'function_call_output', 'output': 'SECRET'}},
                   codex_message('user', 'repeat', 'u1'),
                   event('item_completed', item={'type': 'UserMessage', 'id': 'ue1', 'content': [{'type': 'text', 'text': 'repeat'}]}),
                   codex_message('user', 'repeat', 'u2'),
                   event('item_completed', item={'type': 'UserMessage', 'id': 'ue2', 'content': [{'type': 'text', 'text': 'repeat'}]}),
                   event('item_completed', item={'type': 'AgentMessage', 'id': 'a1', 'phase': 'final_answer', 'content': [{'type': 'Text', 'text': 'visible'}]}),
                   codex_message('assistant', 'visible', 'a1', 'final_answer'), event('task_complete')]
        doc = bridge.parse_text('\n'.join(json.dumps(x) for x in records), force_jsonl=True)
        self.assertEqual([m['content'] for m in doc.messages], ['repeat', 'repeat', 'visible'])
        self.assertTrue(doc.complete)

    def test_claude_mixed_blocks_and_completion_errors(self):
        record = claude_message('assistant', 'answer', message_id='same', stop='end_turn')
        record['message']['content'].extend([{'type': 'thinking', 'thinking': 'SECRET'}, {'type': 'tool_use', 'input': {'SECRET': True}}])
        tool = claude_message('user', '')
        tool['message']['content'] = [{'type': 'tool_result', 'content': 'SECRET'}]
        doc = bridge.parse_text(json.dumps([claude_message('user', 'requirement'), record, tool]))
        self.assertEqual([m['content'] for m in doc.messages], ['requirement', 'answer'])
        self.assertFalse(doc.complete)
        failed = claude_message('assistant', 'API failure', stop='stop_sequence', isApiErrorMessage=True, error='unknown')
        self.assertFalse(bridge.parse_text(json.dumps([failed])).complete)
        chunks = [claude_message('assistant', 'part1', message_id='same'), claude_message('assistant', 'part2', message_id='same', stop='end_turn')]
        self.assertEqual(bridge.parse_text(json.dumps(chunks)).messages[0]['content'], 'part1\npart2')

    def test_completion_cleared_by_new_turn_or_error(self):
        for tail in (event('task_started'), event('turn_aborted'), event('task_complete', error='failed'), codex_message('user', 'new')):
            write_records(self.g, [codex_meta('g1'), codex_message('assistant', 'done', 'a1', 'final_answer'), event('task_complete'), tail])
            self.assertFalse(bridge.read_transcript(self.g).complete)

    def test_exact_acknowledged_prompt_echo_omitted_on_reverse(self):
        outgoing = self.app.prepare(self.request())
        self.app.mark({'packet_id': outgoing['packet_id']})
        write_records(self.g, [codex_message('user', outgoing['preview'], 'transfer'), codex_message('assistant', '实施结果', 'result', 'final_answer')], True)
        reverse = self.app.prepare(self.request(reverse=True))
        self.assertEqual(reverse['new_message_count'], 3)
        self.assertNotIn(outgoing['preview'], reverse['full_text'])
        self.assertIn('实施结果', reverse['full_text'])
        self.assertTrue(any('往返重复' in w for w in reverse['warnings']))

    def test_discovery_native_index_cache_and_large_probe(self):
        write_records(self.root / 'codex/session_index.jsonl', [{'id': 'g1', 'thread_name': 'Indexed title', 'updated_at': '2026-01-01'}])
        write_records(self.root / 'codex/archived_sessions/archive.jsonl', [codex_meta('g2'), codex_message('user', 'archived'), event('task_complete')])
        write_records(self.root / 'codex/sessions/sub.jsonl', [{'type': 'session_meta', 'payload': {'id': 'sub', 'parent_thread_id': 'g1'}}, codex_message('user', 'child')])
        write_records(self.g, [{'type': 'response_item', 'payload': {'type': 'function_call_output', 'output': 'x' * (bridge.PROBE_BYTES * 3)}}, event('task_complete')], True)
        result = self.app.list_sessions()
        sessions = {s['id']: s for s in result['sessions']}
        self.assertEqual(set(sessions), {'g1', 'g2', 'c1'})
        self.assertEqual(sessions['g1']['title'], 'Indexed title')
        self.assertEqual(sessions['g1']['message_count'], -1)
        self.assertTrue(sessions['g1']['complete'])
        self.assertEqual(result, self.app.list_sessions())
        write_records(self.g, [event('task_started')], True)
        sessions = {s['id']: s for s in self.app.list_sessions()['sessions']}
        self.assertFalse(sessions['g1']['complete'])

    def test_probe_is_bounded_and_creates_no_packets(self):
        write_records(self.g, [{'type': 'response_item', 'payload': {'type': 'function_call_output', 'output': 'x' * (bridge.PROBE_BYTES * 3)}}, event('task_complete')], True)
        request = {'action': 'probe', 'source_path': str(self.g), 'source_provider': 'gpt'}
        result = self.app.handle(request)
        self.assertTrue(result['source_complete'])
        self.assertEqual(result['source']['id'], 'g1')
        self.assertEqual(result['source']['message_count'], -1)
        self.assertFalse(self.app.root.exists())
        write_records(self.g, [event('task_started')], True)
        self.assertFalse(self.app.handle(request)['source_complete'])
        with self.g.open('a') as f:
            f.write('{"type":')
        self.assertFalse(self.app.handle(request)['source_complete'])

    def test_plain_text_messages_json_and_exported_converter_json(self):
        text = self.root / 'plain.txt'
        text.write_text('原始文本\n下一行')
        loaded = self.app.load({'file_path': str(text)})
        self.assertIsNone(loaded['session'])
        self.assertIn('原始文本\n下一行', loaded['text'])
        json_path = self.root / 'export.json'
        json_path.write_text(json.dumps({'dialogue': {'messages': [{'role': 'system', 'content': 'SECRET'}, {'role': 'user', 'content': 'requirement'}, {'role': 'assistant', 'content': [{'type': 'thinking', 'thinking': 'SECRET'}, {'type': 'text', 'text': 'answer'}]}]}}))
        loaded = self.app.load({'file_path': str(json_path)})
        self.assertNotIn('SECRET', loaded['text'])
        self.assertIn('answer', loaded['text'])
        result = self.app.prepare({'text': '原始文本', 'target_provider': 'claude'})
        self.assertFalse(result['source_complete'])
        bracketed = '[用户 · 消息 1]\n原始要求\n\n[助手 · 消息 2]\n计划'
        self.assertEqual(bridge.parse_text(bracketed).messages[0]['content'], bracketed)

    def test_text_file_crlf_and_bom_delivery_snapshot_uses_exact_bytes(self):
        text = self.root / 'windows.txt'
        text.write_bytes(b'\xef\xbb\xbfrequirements\r\nsecond line\r\n')
        result = self.app.prepare(self.request() | {'source_path': str(text), 'source_provider': 'claude'})
        marked = self.app.mark({'packet_id': result['packet_id']})
        self.assertEqual(marked['delivered_until'], 1)

    def test_forwarding_to_third_target_preserves_original_handoff(self):
        outgoing = self.app.prepare(self.request())
        self.app.mark({'packet_id': outgoing['packet_id']})
        write_records(self.g, [codex_message('user', outgoing['preview'], 'transfer')], True)
        third = write_records(self.root / 'third.jsonl', [claude_message('user', 'third target', identifier='c3')])
        onward = self.app.prepare(self.request(reverse=True) | {'target_path': str(third)})
        self.assertIn(outgoing['preview'], onward['full_text'])

    def test_parallel_processes_atomic_state_and_private_permissions(self):
        args = (str(self.app.root), str(self.app.codex), str(self.app.claude), self.request())
        context = multiprocessing.get_context('spawn')
        with concurrent.futures.ProcessPoolExecutor(max_workers=4, mp_context=context) as pool:
            packets = list(pool.map(parallel_prepare, [args] * 8))
            marks = list(pool.map(parallel_mark, [(args[0], args[1], args[2], p) for p in packets]))
        self.assertEqual(len(set(packets)), 8)
        self.assertTrue(all(mark['delivered_until'] == 2 for mark in marks))
        self.assertEqual(self.app.prepare(self.request())['new_message_count'], 0)
        for path in [self.app.root, *self.app.root.rglob('*')]:
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)
        self.assertFalse(list(self.app.root.rglob('.write-*')))

    def test_invalid_targets_corrupt_state_and_cli_failure_protocol(self):
        with self.assertRaisesRegex(ValueError, '目标'):
            self.app.prepare(self.request() | {'target_path': str(self.c)})
        self.app.root.mkdir(exist_ok=True)
        (self.app.root / 'state.json').write_text('{bad')
        with self.assertRaisesRegex(ValueError, '状态无法读取'):
            self.app.prepare(self.request())
        result = subprocess.run([sys.executable, str(MODULE)], input='{"action":"unknown"}', text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)['ok'])
        self.assertEqual(result.stderr, '')

    def test_history_reopens_exact_packets_without_advancing_delivery(self):
        pending = self.app.prepare(self.request())
        first = self.app.prepare(self.request(reverse=True))
        self.app.mark({'packet_id': first['packet_id']})
        history = self.app.handle({'action': 'history'})
        self.assertEqual(history['total'], 2)
        records = {p['packet_id']: p for p in history['history']}
        self.assertFalse(records[pending['packet_id']]['marked'])
        self.assertTrue(records[first['packet_id']]['marked'])
        self.assertEqual(records[first['packet_id']]['source_provider'], 'gpt')
        reopened = self.app.read_packet({'packet_id': pending['packet_id']})
        self.assertEqual(reopened['full_text'], pending['full_text'])
        self.assertEqual(reopened['preview'], pending['preview'])
        self.assertFalse(reopened['marked'])
        self.assertEqual(self.app.prepare(self.request())['new_message_count'], 2)

    def test_history_handles_invalidated_paste_and_corrupt_artifacts(self):
        first = self.app.prepare(self.request())
        self.c.write_text(self.c.read_text().replace('保留要求', '修订要求'))
        self.app.prepare(self.request())
        self.assertFalse(self.app.read_packet({'packet_id': first['packet_id']})['valid'])
        imported = self.app.prepare({'text': '导入要求', 'source_provider': 'gpt', 'target_provider': 'claude'})
        reopened = self.app.read_packet({'packet_id': imported['packet_id']})
        self.assertEqual('导入要求', reopened['text'])
        self.assertEqual(reopened['source_provider'], 'gpt')
        Path(imported['artifact_path']).write_text('tampered')
        with self.assertRaisesRegex(ValueError, '已修改或损坏'):
            self.app.read_packet({'packet_id': imported['packet_id']})
        with self.assertRaisesRegex(ValueError, '无效'):
            self.app.read_packet({'packet_id': '../state.json'})
        with self.assertRaisesRegex(ValueError, '整数'):
            self.app.history({'limit': True})

    def test_cli_custom_directories_are_isolated(self):
        request = {'action': 'list', 'data_dir': str(self.app.root),
                   'codex_home': str(self.app.codex), 'claude_home': str(self.app.claude)}
        result = subprocess.run([sys.executable, str(MODULE)], input=json.dumps(request), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({s['id'] for s in json.loads(result.stdout)['sessions']}, {'g1', 'c1'})


if __name__ == '__main__':
    unittest.main()
