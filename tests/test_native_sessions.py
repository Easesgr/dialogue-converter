import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

import bridge
import native_sessions as native


class NativeSessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.project = self.root / 'project with spaces'
        self.project.mkdir()
        self.app = bridge.Bridge(self.root / 'state', self.root / 'codex', self.root / 'claude', self.root / 'cowork')
        self.messages = [{'role': 'user', 'content': '保留完整要求：中文与 emoji 🧩'},
                         {'role': 'assistant', 'content': '计划\n' + '完整长文本。' * 5000},
                         {'role': 'user', 'content': '按计划实施，然后交回审查。'}]
        self.sid, self.cli = str(uuid.uuid4()), str(uuid.uuid4())
        self.session_root = self.root / 'cowork/local-agent-mode-sessions/account/org'
        self.metadata = self.session_root / ('local_' + self.sid + '.json')
        self.transcript = self.session_root / self.sid[:8] / '.claude/projects/session' / (self.cli + '.jsonl')
        bridge.atomic_write(self.transcript, native.jsonl(native.claude_records(self.messages, self.cli, '/private/engine', '合成任务')))
        bridge.write_json(self.metadata, {'sessionId': 'local_' + self.sid, 'cliSessionId': self.cli, 'title': '合成任务',
                                         'permissions': {'dangerous': True}, 'apiKey': 'fixture-only-secret'})

    def tearDown(self):
        self.temporary.cleanup()

    def test_cowork_discovery_alias_and_full_content(self):
        sessions, notices = native.discover_cowork(self.app)
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]['surface'], 'cowork')
        self.assertEqual(sessions[0]['cwd'], '')
        self.assertEqual(native.native_messages(native.read_cowork(self.metadata)), self.messages)
        self.assertEqual(notices, [])

    def test_active_chain_includes_history_before_compaction_and_excludes_branch(self):
        records = native.claude_records(self.messages[:2], self.cli, '/engine')
        original_leaf = records[-1]['uuid']
        abandoned = native.claude_records([{'role':'user','content':'abandoned retry'}], self.cli, '/engine')[0]
        abandoned['parentUuid'] = records[0]['uuid']
        boundary = {'uuid': str(uuid.uuid4()), 'type':'system', 'subtype':'compact_boundary',
                    'parentUuid':None, 'logicalParentUuid':original_leaf}
        summary = {'type':'user','uuid':str(uuid.uuid4()),'parentUuid':boundary['uuid'],'isCompactSummary':True,
                   'message':{'role':'user','content':'summary must not replace original'}}
        final = native.claude_records(self.messages[2:], self.cli, '/engine')[0]
        final['parentUuid'] = summary['uuid']
        bridge.atomic_write(self.transcript, native.jsonl([*records, abandoned, boundary, summary, final]))
        self.assertEqual(native.native_messages(native.read_cowork(self.metadata)), self.messages)
        boundary['logicalParentUuid'] = final['uuid']
        bridge.atomic_write(self.transcript, native.jsonl([*records, boundary, summary, final]))
        with self.assertRaisesRegex(ValueError, '消息链'):
            native.read_cowork(self.metadata)

    def test_cowork_zip_preserves_roles_text_and_excludes_private_settings(self):
        before = self.metadata.read_bytes(), self.transcript.read_bytes()
        source = self.root / 'codex.jsonl'
        records = [{'type':'session_meta','payload':{'id':str(uuid.uuid4()),'cwd':str(self.project)}}]
        records += [{'type':'response_item','payload':{'type':'message',**m}} for m in self.messages]
        records.append({'type':'response_item','payload':{'type':'reasoning','summary':[{'type':'text','text':'private reasoning'}]}})
        bridge.atomic_write(source, native.jsonl(records))
        conversion = native.prepare(self.app, {'source_path':str(source), 'target_provider':'claude'})['conversion']
        with zipfile.ZipFile(conversion['artifact_path']) as archive:
            names = archive.namelist()
            self.assertEqual(len(names), 3)
            manifest = json.loads(archive.read('claude-3p-export.json'))
            self.assertEqual(manifest['counts'], {'cowork':1,'code':0,'chat':0})
            transcript_name, = [n for n in names if n.endswith('.jsonl')]
            text = archive.read(transcript_name).decode()
            self.assertEqual(native.native_messages(bridge.parse_text(text)), self.messages)
            exported = [json.loads(line) for line in text.splitlines() if json.loads(line).get('type') in ('user','assistant')]
            self.assertIsNone(exported[0]['parentUuid'])
            self.assertEqual([r['parentUuid'] for r in exported[1:]], [r['uuid'] for r in exported[:-1]])
            self.assertEqual(len({r['uuid'] for r in exported}), len(exported))
            for name in names:
                content = archive.read(name).decode()
                self.assertNotIn('fixture-only-secret', content)
                self.assertNotIn('private reasoning', content)
                self.assertNotIn('permissions', content)
        self.assertEqual(before, (self.metadata.read_bytes(), self.transcript.read_bytes()))
        self.assertEqual(os.stat(conversion['artifact_path']).st_mode & 0o777, 0o600)

    def test_repeat_conversion_reuses_snapshot_and_changed_history_creates_new_one(self):
        request = {'source_path':str(self.metadata),'target_provider':'gpt','project':str(self.project)}
        first = native.prepare(self.app, request)['conversion']
        self.assertEqual(first['id'], native.prepare(self.app, request)['conversion']['id'])
        with patch.object(native, 'import_codex', side_effect=ValueError('simulated protocol failure')):
            with self.assertRaisesRegex(ValueError, 'simulated'):
                native.perform_import(self.app, {'conversion_id':first['id'], 'codex_binary':'/usr/bin/true'})
        self.assertEqual(native.receipt(self.app,first['id'])['state'], 'uncertain')
        with self.assertRaisesRegex(ValueError, '上次导入'):
            native.perform_import(self.app, {'conversion_id':first['id'], 'codex_binary':'/usr/bin/true'})
        changed = self.messages + [{'role':'assistant','content':'实施完成。'}]
        bridge.atomic_write(self.transcript, native.jsonl(native.claude_records(changed,self.cli,'/engine')))
        self.assertNotEqual(first['id'], native.prepare(self.app, request)['conversion']['id'])

    def test_broken_record_and_escaping_symlink_are_rejected(self):
        self.transcript.write_text(self.transcript.read_text() + '{broken')
        with self.assertRaisesRegex(ValueError, '写入|损坏'):
            native.prepare(self.app, {'source_path':str(self.metadata),'target_provider':'gpt','project':str(self.project)})
        external = self.root/'outside.jsonl';external.write_text('{}')
        self.transcript.unlink();self.transcript.symlink_to(external)
        with self.assertRaisesRegex(ValueError, '未找到'):
            native.read_cowork(self.metadata)

    def test_partial_codex_success_retains_target_and_can_verify_without_reimport(self):
        prepared = native.prepare(self.app, {'source_path':str(self.metadata),'target_provider':'gpt',
                                             'project':str(self.project)})['conversion']
        target = str(uuid.uuid4())
        def interrupted_import(*args, on_target):
            on_target(target)
            self.assertEqual(native.receipt(self.app, prepared['id'])['target_id'], target)
            raise ValueError('simulated readback interruption')
        with patch.object(native, 'import_codex', side_effect=interrupted_import):
            with self.assertRaisesRegex(ValueError, 'readback'):
                native.perform_import(self.app, {'conversion_id':prepared['id'],'codex_binary':'/usr/bin/true'})
        uncertain = native.receipt(self.app, prepared['id'])
        self.assertEqual((uncertain['state'], uncertain['target_id']), ('uncertain', target))
        items = [{'type':'userMessage','content':m['content']} if m['role'] == 'user' else
                 {'type':'agentMessage','text':m['content']} for m in self.messages]
        thread = {'id':target,'path':str(self.root/'persisted.jsonl'),'turns':[{'items':items}]}
        with patch.object(native, 'AppServer') as server_class:
            server = server_class.return_value
            server.__enter__.return_value = server
            server.call.return_value = {'thread':thread}
            verified = native.dispatch(self.app, {'action':'native_verify','conversion_id':prepared['id'],
                                                  'codex_binary':'/usr/bin/true'})['conversion']
            server.call.assert_called_once_with('thread/read', {'threadId':target,'includeTurns':True})
        self.assertEqual(verified['state'], 'imported')
        self.assertNotIn('error', verified)

    def test_cowork_verification_skips_unrelated_invalid_metadata_and_checks_full_prefix(self):
        source = self.root/'codex.jsonl'
        records = [{'type':'session_meta','payload':{'id':str(uuid.uuid4()),'cwd':str(self.project)}}]
        records += [{'type':'response_item','payload':{'type':'message',**m}} for m in self.messages]
        bridge.atomic_write(source, native.jsonl(records))
        conversion = native.prepare(self.app, {'source_path':str(source),'target_provider':'claude'})['conversion']
        imported_root = self.root/'imported'
        with zipfile.ZipFile(conversion['artifact_path']) as archive:
            archive.extractall(imported_root)
        metadata, = imported_root.glob('local-agent-mode-sessions/*/*/local_*.json')
        bridge.atomic_write(metadata.parent/'local_invalid.json', '{broken')
        bridge.atomic_write(metadata.parent/'local_array.json', '[]')
        self.app.cowork = imported_root
        imported_metadata = json.loads(metadata.read_text())
        bridge.write_json(metadata, {**imported_metadata,'cliSessionId':str(uuid.uuid4())})
        missing = native.verify_cowork(self.app, {'conversion_id':conversion['id']})
        self.assertEqual(missing['conversion']['state'], 'exported')
        self.assertTrue(any('部分 Cowork' in warning for warning in missing['warnings']))
        bridge.write_json(metadata, imported_metadata)
        verified = native.dispatch(self.app, {'action':'native_verify','conversion_id':conversion['id']})
        self.assertEqual(verified['conversion']['state'], 'imported')
        self.assertEqual(native.native_messages(native.read_cowork(verified['conversion']['target_path'])), self.messages)
        _, _, engine = native.cowork_metadata(metadata)
        engine.write_text(engine.read_text().replace(self.messages[0]['content'], 'changed user message'))
        with self.assertRaisesRegex(ValueError, '原文不同'):
            native.verify_cowork(self.app, {'conversion_id':conversion['id']})

    def test_tool_reasoning_and_meta_are_excluded_without_filtering_user_text(self):
        records = native.claude_records(self.messages,self.cli,'/engine')
        records[2]['message']['content'] += [{'type':'thinking','thinking':'secret-thought'},
                                           {'type':'tool_use','id':'t1','name':'tool','input':{'secret':'tool-data'}}]
        doc = bridge.parse_text(native.jsonl(records))
        self.assertEqual(native.native_messages(doc),self.messages)
        self.assertEqual(native.native_messages(bridge.Transcript(provider='gpt',messages=[
            {'role':'user','content':'<EXTERNAL SESSION IMPORTED>'},
            {'role':'assistant','content':'<EXTERNAL SESSION IMPORTED>'}])),[{'role':'user','content':'<EXTERNAL SESSION IMPORTED>'}])


if __name__ == '__main__':
    unittest.main()
