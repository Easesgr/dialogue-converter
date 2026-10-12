# Native transcript bridge

bridge.py is a Python standard-library command-line bridge. It reads one UTF-8 JSON request from stdin, emits one response with ok: true or ok: false, and exits 1 on failure. It never starts a model, contacts a service, sends a message, controls a native app, or writes native app data.

## Request interface

- list: returns sessions and warnings. Each session has id, provider, title, cwd, path, updated_at, complete, and message_count. Up to 100 recent file candidates per provider are inspected; child-agent sessions are excluded.
- probe: accepts source_path and optional source_provider; returns source, source_complete, and warnings. It reads only a bounded head/tail for large JSONL, creates no packet, and does not save delivery state.
- load: accepts file_path and optional source_provider; returns visible formatted text, native session when identifiable, and warnings.
- prepare: accepts either source_path or text, optional source_provider, optional target_path, required target_provider (claude or gpt), intent (implement, review, or continue), and optional project. Returns packet_id, preview, full_text, source, target, message_count, new_message_count, characters, artifact_path, warnings, and source_complete. characters counts Python Unicode code points in the preview; it is not a token estimate.
- mark: accepts packet_id after the user confirms delivery in the native app. Returns marked, already_marked, and delivered_until. Preparing, copying, or opening a native app must never call this action automatically.
- status: accepts packet_id; returns persisted acknowledgement, generation validity, source/target metadata, artifact path, and delivered cursor. valid reflects the saved generation; source history is revalidated by prepare/mark.

message_count: -1 means the large transcript was sampled and the full count is unknown. Show “待加载” or omit the count. Full source loading and preparation return exact counts. Native metadata IDs take precedence; native JSONL with no metadata ID may use a trailing canonical UUID from its filename. An unrecognisable filename without native metadata ID cannot identify a target. Pair identity is provider plus native ID, so moving a native file to the archive does not silently bind another session.

## Formats and filtering

Codex rollouts: session_meta, response_item visible user/assistant message records, legacy event_msg user/agent message records, current event_msg/item_completed UserMessage/AgentMessage, and CLI thread.started / item.completed streams. Mirrored event/response messages are deduplicated, while repeated user requests are preserved.

Claude Code: user / assistant envelope records with message.content; visible text blocks are retained, message blocks sharing a native message ID are combined. Sidechains, metadata-only messages, tool results, tool use, thinking, and API internals are excluded.

Other imports: plain UTF-8 text/Markdown, messages arrays, {messages:[...]}, and {dialogue:{messages:[...]}} converter exports. Structured imports allow only visible text and user/assistant/context roles. No system/developer records, private reasoning, tool schemas/outputs, compaction replacements, or encrypted content are transferred. Invalid JSONL lines are skipped with a warning and force incomplete status; malformed JSON-shaped input is never downgraded into raw text that could leak filtered fields. Bracketed Markdown speaker labels remain plain text.

Completion uses explicit final-answer phases or successful completion events for Codex; Claude requires an assistant end_turn / stop_sequence without API error markers. New input, ongoing reasoning/tool calls, starts, aborts, errors, malformed lines, or concurrent source writes clear completion. No idle-time guess is used.

## Incremental handoffs

With target_path, each source/target pair has its own delivery cursor. All pending messages remain pending until explicit mark. A subsequent preparation includes any messages still unacknowledged. Overlapping acknowledgements advance only the contiguous delivered range, so marking an older packet cannot move the cursor backward or skip a gap. History snapshots use byte hashes plus visible-message fingerprints; edited or truncated sources reset the pair with a warning and invalidate old-generation packets. Acknowledgement checks the source prefix again.

Without target_path, each preparation creates a distinct unbound new-target scope. It never guesses which native target received the prompt. After creating a new native chat, select its actual transcript for subsequent pair-specific handoffs; the first explicitly paired transfer may repeat context because the earlier unbound transfer cannot be safely inferred.

The first preview prioritizes all user/context messages and the latest substantive assistant reply; the complete visible reference includes all pending messages. Long previews include excerpts and an explicit exact local-file reference. If the target app cannot read local files, the user must attach that file or paste the full reference; the converter does not claim the target received a referenced file merely because a prompt was copied. An exact converter prompt that was marked delivered is omitted only when returning to its original source session, avoiding a recursive handoff echo. Transfers to a third target retain that context.

State and packets live in ~/Library/Application Support/DialogueConverter. Directories use 0700 and files 0600. Files are written with unique temporary names, fsync, atomic rename, and directory fsync; a process lock serializes source snapshot reads and state mutations. State failures stop delivery changes rather than pretending success.

## Handoff history and protocol settings

`history` returns the latest 100 packet metadata records by default (limit 1–500), including direction, created time, validity and explicit acknowledgement. It does not change delivery progress. `read_packet` reopens a packet and verifies the full artifact's digest before returning copyable content. A packet whose history generation has changed can still be viewed but cannot acknowledge the new generation. Old version 0.2 packets are supported using their persisted source identities.

The CLI accepts optional `data_dir`, `codex_home` and `claude_home` directory paths. Defaults remain the application-support directory, `CODEX_HOME` or `~/.codex`, and `CLAUDE_CONFIG_DIR` or `~/.claude`. The native application exposes provider directory settings; its demo mode uses an isolated temporary data directory.

## Known limits

No complete readable Claude Desktop/Cowork transcript was discovered in the local application data. Automatic native discovery supports Claude Code and Codex files; Claude Desktop/Cowork requires an exported or pasted visible transcript. Plain pasted text has no reliable native session identity or completion signal. Changed pasted content is treated as a different import rather than risking a cursor against unrelated content.

Large JSONL listing/probes are bounded; preparing/loading the actual source still streams the entire source file to obtain complete visible messages and a verifiable snapshot. Images/audio and non-text attachments are not converted. Native applications retain ownership of their original conversations and tool access.
