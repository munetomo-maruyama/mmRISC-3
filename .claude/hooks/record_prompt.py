#!/usr/bin/env python3
#---------------------------------------------------------------------------
# record_prompt.py : append the author's prompt to Doc/PROMPT.md
#
# UserPromptSubmit hook of Claude Code (.claude/settings.local.json). Reads
# the hook's JSON from stdin and appends the prompt, with the time in JST,
# as the next numbered entry. Messages of the system (task notifications,
# reminders) are skipped. Never blocks the prompt: any error is ignored.
#
# Also imported by the one-off backfill of the prompts before the hook.
#---------------------------------------------------------------------------
import datetime
import json
import os
import re
import sys
import zoneinfo

JST = zoneinfo.ZoneInfo('Asia/Tokyo')
HEADER = """# mmRISC-3 プロンプト記録

作者がClaude Codeに入力したプロンプトを、入力した日時(JST)の順に記録する。2026-10-23 23:23の最初のプロンプトから。

- 8番(2026-10-24 01:01)まではセッションの記録から書き起こし、それ以降はClaude Codeのフック(`.claude/hooks/record_prompt.py`)が入力のたびに追記する。
- 本文は入力のまま(添付ファイルは`@パス`の形で残る)。システムからの通知(バックグラウンド処理の完了など)は含めない。
- 「(ボタン)」は、Claude Codeが提示した次の作業の選択肢から送信したもの(文面はClaude Codeが用意したもの)。
"""


def skip(text):
    t = text.lstrip()
    return not t or t.startswith('<task-notification>') or t.startswith('<system-reminder>') \
        or t.startswith('[Request interrupted')


def append_entry(path, when, text, note=''):
    if not os.path.exists(path):
        with open(path, 'w', encoding='utf-8') as f:
            f.write(HEADER)
    with open(path, encoding='utf-8') as f:
        n = len(re.findall(r'^## \d+\. ', f.read(), flags=re.M)) + 1
    fence = '```'
    while fence in text:
        fence += '`'
    stamp = when.astimezone(JST).strftime('%Y-%m-%d %H:%M:%S JST')
    with open(path, 'a', encoding='utf-8') as f:
        f.write(f'\n## {n}. {stamp}{note}\n\n{fence}text\n{text.rstrip()}\n{fence}\n')


def main():
    try:
        data = json.load(sys.stdin)
        text = data.get('prompt') or ''
        if skip(text):
            return
        root = os.environ.get('CLAUDE_PROJECT_DIR') or data.get('cwd') or '.'
        append_entry(os.path.join(root, 'Doc', 'PROMPT.md'),
                     datetime.datetime.now(JST), text)
    except Exception:
        pass


if __name__ == '__main__':
    main()
