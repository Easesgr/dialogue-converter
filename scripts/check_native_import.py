#!/usr/bin/env python3
"""Exercise the installed Codex importer in isolated homes, with synthetic text."""
import argparse
from pathlib import Path
import sys
import tempfile
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge
import native_sessions as native


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex-binary')
    args = parser.parse_args()
    binary = native.find_codex(args.codex_binary)
    with tempfile.TemporaryDirectory(prefix='converter-native-check-') as temporary:
        root = Path(temporary)
        project = root / 'project with spaces'
        project.mkdir()
        app = bridge.Bridge(root/'state', root/'codex', root/'claude', root/'cowork')
        source = root/'source.jsonl'
        messages = [{'role':'user','content':'原始要求：中文与长任务历史。'},
                    {'role':'assistant','content':'实施计划\n' + '完整文字 🧩。' * 4000},
                    {'role':'user','content':'补充要求：验证完成后交回。'},
                    {'role':'assistant','content':'已记录补充要求。'}]
        bridge.atomic_write(source, native.jsonl(native.claude_records(messages,str(uuid.uuid4()),str(project),'原生导入隔离检查')))
        original = source.read_bytes()
        request = {'source_path':str(source),'target_provider':'gpt','project':str(project)}
        prepared = native.prepare(app, request)['conversion']
        imported = native.perform_import(app, {'conversion_id':prepared['id'],'codex_binary':str(binary)})['conversion']
        assert imported['state'] == 'imported'
        assert native.native_messages(app.load_document(imported['target_path'])) == messages
        assert source.read_bytes() == original
        assert native.perform_import(app, {'conversion_id':prepared['id'],'codex_binary':str(binary)})['conversion']['target_id'] == imported['target_id']
        assert native.dispatch(app, {'action':'native_verify','conversion_id':prepared['id'],
                                     'codex_binary':str(binary)})['conversion']['state'] == 'imported'
        reverse = native.prepare(app, {'source_path':imported['target_path'],'target_provider':'claude'})['conversion']
        with zipfile.ZipFile(reverse['artifact_path']) as archive:
            transcript, = [name for name in archive.namelist() if name.endswith('.jsonl')]
            assert native.native_messages(bridge.parse_text(archive.read(transcript).decode())) == messages
        with native.AppServer(binary,app.codex,Path(prepared['artifact_path']).parents[3]) as server:
            resumed = server.call('thread/resume',{'threadId':imported['target_id']})
            assert resumed['thread']['id'] == imported['target_id']
        print('PASS: isolated native import, exact role/text readback, idempotence, reverse Cowork ZIP, and native thread resume.')
        print('No turn/start or model generation request was sent. Real user profiles were not used.')


if __name__ == '__main__':
    main()
