#!/usr/bin/env python3
#---------------------------------------------------------------------------
# record_prompt.py : keep Doc/PROMPT_J.md, the author's prompts and Claude
# Code's answers
#
#   record_prompt.py           UserPromptSubmit hook: append the prompt, with
#                              the time in JST, as the next numbered entry
#   record_prompt.py answer    Stop hook: put the last answer of the turn
#                              under the entry of the prompt it answers
#
# Both read the hook's JSON from stdin (.claude/settings.local.json).
# Messages of the system (task notifications, reminders) are skipped. A turn
# that is continued by a background job ends again later; its entry then
# gets the newer answer, so it always holds the last thing said for that
# prompt. Never blocks anything: any error is ignored.
# The English translation (Doc/PROMPT.md) is added by Claude Code itself: a
# prompt in the same turn, an answer at the start of the next turn (a hook
# cannot translate, and the answer is the last thing written in a turn).
#
# Also imported by the one-off backfill of the entries before the hooks.
#---------------------------------------------------------------------------
import datetime
import json
import os
import re
import sys
import zoneinfo

JST = zoneinfo.ZoneInfo('Asia/Tokyo')
HEADER = """# mmRISC-3 プロンプトと回答の記録

作者がClaude Codeに入力したプロンプトと、それへのClaude Codeの回答を、入力した日時(JST)の順に記録する。2026-10-23 23:23の最初のプロンプトから。

- プロンプト: 8番(2026-10-24 01:01)まではセッションの記録から書き起こし、それ以降はClaude Codeのフック(`.claude/hooks/record_prompt.py`)が入力のたびに追記する。本文は入力のまま(添付ファイルは`@パス`の形で残る)。システムからの通知(バックグラウンド処理の完了など)は含めない。
- 回答: そのプロンプトへのターンでClaude Codeが最後に書いた回答。13番まではセッションの記録から書き起こし、それ以降は同じスクリプトがターンの終わりに書き込む(Stopフック)。見出しは2段下げ、リンクはこのファイルからの相対パスに直してある。作業途中の短い経過報告やツールの出力は含めない。
- 「(ボタン)」は、Claude Codeが提示した次の作業の選択肢から送信したもの(文面はClaude Codeが用意したもの)。
- 英訳は`PROMPT.md`。プロンプトは同じターンのうちに、回答は次のターンの初めに、Claude Codeが訳して追記する。
"""
ANS_LABEL = '**Claude Codeの回答**'


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


def format_answer(text):
    """headings two levels down; links relative to Doc/ (answers link from the
    repository root, or from ../mmRISC-3/ when the session was in mmRISC-2)"""
    out, fence = [], False
    for line in text.rstrip().split('\n'):
        if line.lstrip().startswith('```'):
            fence = not fence
        elif not fence and re.match(r'#{1,4} ', line):
            line = '##' + line
        out.append(line)
    s = '\n'.join(out)

    def link(m):
        t = m.group(2)
        if re.match(r'(https?:|mailto:|#)', t):
            return m.group(0)
        t = re.sub(r'^\.\./mmRISC-3/', '', t)
        return f'{m.group(1)}(../{t})'
    return re.sub(r'(\[[^\]]*\])\(([^)\s]+)\)', link, s)


def entry_spans(s):
    """(number, start, end, prompt text) of every entry"""
    heads = [m for m in re.finditer(r'^## (\d+)\. ', s, flags=re.M)]
    spans = []
    for k, m in enumerate(heads):
        end = heads[k + 1].start() if k + 1 < len(heads) else len(s)
        body = s[m.start():end]
        pm = re.search(r'^(`{3,})text\n(.*?)\n\1$', body, flags=re.S | re.M)
        spans.append((int(m.group(1)), m.start(), end, pm.group(2) if pm else ''))
    return spans


def set_answer(path, prompt, answer):
    """put the answer under the latest entry whose prompt is `prompt`
    (replacing an earlier answer of the same entry)"""
    with open(path, encoding='utf-8') as f:
        s = f.read()
    want = prompt.strip()
    for num, a, b, p in reversed(entry_spans(s)):
        if p.strip() == want:
            break
    else:
        return False
    body = s[a:b]
    body = re.sub(r'\n<!-- answer -->.*?<!-- /answer -->\n', '\n', body, flags=re.S)
    body = body.rstrip('\n') + f'\n\n<!-- answer -->\n{ANS_LABEL}\n\n{format_answer(answer)}\n<!-- /answer -->\n'
    if b < len(s):
        body += '\n'
    with open(path, 'w', encoding='utf-8') as f:
        f.write(s[:a] + body + s[b:])
    return True


def last_turn(transcript):
    """the last prompt of the author in the transcript, and the last answer
    text after it"""
    prompt, answer = None, None
    with open(transcript, encoding='utf-8') as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            c = e.get('message', {}).get('content')
            if e.get('type') == 'user' and not e.get('isMeta'):
                texts = [c] if isinstance(c, str) else \
                    [b.get('text', '') for b in (c or []) if isinstance(b, dict) and b.get('type') == 'text']
                for t in texts:
                    if not skip(t):
                        prompt, answer = t, None
            elif e.get('type') == 'assistant' and prompt is not None:
                for b in (c or []):
                    if isinstance(b, dict) and b.get('type') == 'text' and b['text'].strip():
                        answer = b['text']
    return prompt, answer


def main():
    try:
        data = json.load(sys.stdin)
        root = os.environ.get('CLAUDE_PROJECT_DIR') or data.get('cwd') or '.'
        path = os.path.join(root, 'Doc', 'PROMPT_J.md')
        if len(sys.argv) > 1 and sys.argv[1] == 'answer':
            prompt, answer = last_turn(data['transcript_path'])
            if prompt and answer:
                set_answer(path, prompt, answer)
            return
        text = data.get('prompt') or ''
        if skip(text):
            return
        append_entry(path, datetime.datetime.now(JST), text)
    except Exception:
        pass


if __name__ == '__main__':
    main()
