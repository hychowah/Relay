#!/usr/bin/env python3
"""Check that agent records stay in their places and inside their limits.

    python3 tools/check_records.py [--root PATH] [--staged] [--inventory]

The rules are in docs/records-policy.md. This uses only the Python standard
library. It reads the files that Git tracks or would add
(`git ls-files --cached --others --exclude-standard`), so it also sees
uncommitted work.

--staged reads only the files in the index, which is what the next commit
holds. Stage the whole change first. Untracked files outside the change then
cannot fail the check. /smart-commit uses it after staging.

--inventory prints counts and bytes by area and the state of each initiative.
It does not judge anything and always exits 0.

Exit status: 0 when the records follow the policy, 1 when there are problems,
2 when the check cannot run.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from urllib.parse import unquote

# ---- Policy constants. Keep them in step with docs/records-policy.md. ----
PLANS_ROOT = 'docs/plans'                 # plan workspace root
SCRATCH_DIR = 'tmp'                       # ignored scratch; never tracked, never linked
STANDING_DOCS = ('AGENTS.md', 'CLAUDE.md')
STANDING_MAX_WORDS = 3000
PLANS_ROOT_FILES = ('README.md',)         # files allowed directly under PLANS_ROOT
MASTER_PLAN = 'master-plan.md'
PHASE_DIR = r'phase-\d{2}'                # phase folder name under phases/
DECISION_FILE = r'\d{4}-[a-z0-9]+(?:-[a-z0-9]+)*\.md'
WORD_LIMITS = {
    'active master plan': 3000,
    'complete master plan': 1000,
    'contract doc': 3000,
    'plans index': 3000,
    'phase README': 900,
    'decision record': 700,
    'working note': 3000,
}
WORKING_JSON_MAX_BYTES = 64 * 1024
LARGE_FILE_BYTES = 1024 * 1024            # cap for any tracked file; None skips
LARGE_FILE_ALLOW = ()                     # fnmatch patterns allowed above the cap
BANNED_SUFFIXES = ('.log',)               # never tracked anywhere
SCAN_EXCLUDE = ()                         # fnmatch patterns of Markdown not scanned for links
# ---- End of policy constants. ----

KEPT_WHEN_COMPLETE = {'master plan', 'contract doc', 'decision record'}
STATUS_LINE = re.compile(r'Status: (active|complete)')
NEXT_HEADING = re.compile(r'^(?:[ \t]{0,3}#{1,6}[ \t]+|\*\*)Next\b', re.M | re.I)
COPY_NAME = re.compile(r'(?:^|[-_.])(?:(?:attempt|retry|addendum|clarification|copy|old)[-_]?\d*|v\d+)\Z',
                       re.I)
FENCE = re.compile(r'^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?^[ \t]*\1[ \t]*$', re.M | re.S)
INLINE_CODE = re.compile(r'`[^`\n]*`')
INLINE_LINK = re.compile(r'\]\(\s*<?([^)\s>]+)>?[^)\n]*\)')
REF_LINK = re.compile(r'^[ \t]{0,3}\[[^\]\n]+\]:[ \t]*<?([^\s>]+)', re.M)
URL_SCHEME = re.compile(r'[A-Za-z][A-Za-z0-9+.-]*:')
HEADING = re.compile(r'^[ \t]{0,3}#{1,6}[ \t]+(.*)$', re.M)
MONTH = (r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?'
         r'|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)')
DATE = re.compile(r'\b\d{4}-\d{2}-\d{2}\b'
                  r'|\b\d{1,2}(?:st|nd|rd|th)? ' + MONTH + r'\.?,? \d{4}\b'
                  r'|\b' + MONTH + r'\.? (?:\d{1,2}(?:st|nd|rd|th)?,? )?\d{4}\b', re.I)
CHRONOLOGY = re.compile(r'\b(?:resum(?:e|es|ed|ing|ption)|change ?log|as of|status update'
                        r'|progress log|handoff|session \d+|phase \d+ (?:complete|completed|done|started))\b', re.I)
DATED_LINE = re.compile(r'^[ \t]*[*_]*(?:last updated|updated|as of)\b.*$', re.M | re.I)
PLACEHOLDER = re.compile(r'N{2,}|X{2,}')


class CheckError(Exception):
    """The check cannot run here."""


def git(root, *args, check=True):
    try:
        return subprocess.run(['git', '-C', root, *args], capture_output=True, check=check)
    except OSError as error:
        raise CheckError(f'git is unavailable: {error.strerror}') from None
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise CheckError(f'git {args[0]} failed in {root}: {detail[-1] if detail else error.returncode}') from None


def list_files(root, staged=False):
    """Files that Git tracks or would add, as POSIX paths relative to root.

    With staged=True, only the files in the index: the content of the next commit.
    """
    scope = ('--cached',) if staged else ('--cached', '--others', '--exclude-standard')
    out = git(root, 'ls-files', *scope, '-z').stdout
    names = out.decode('utf-8', 'surrogateescape').split('\0')
    return sorted({n for n in names if n and (staged or os.path.isfile(os.path.join(root, n)))})


def scratch_ignored(root, files, staged=False):
    args = ('check-ignore', '-q', '--no-index', f'{SCRATCH_DIR}/records-probe')
    if not staged:
        return git(root, *args, check=False).returncode == 0
    git_dir = git(root, 'rev-parse', '--absolute-git-dir').stdout.decode().strip()
    with tempfile.TemporaryDirectory(prefix='records-ignore-') as snapshot:
        for path in files:
            if posixpath.basename(path) == '.gitignore':
                full = os.path.join(snapshot, path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, 'wb') as handle:
                    handle.write(git(root, 'show', f':{path}').stdout)
        return git(root, '--git-dir', git_dir, '--work-tree', snapshot,
                   *args, check=False).returncode == 0


def ancestors(files):
    dirs = set()
    for path in files:
        parent = posixpath.dirname(path)
        while parent and parent not in dirs:
            dirs.add(parent)
            parent = posixpath.dirname(parent)
    return dirs


def under(path, top):
    return bool(top) and (path == top or path.startswith(top.rstrip('/') + '/'))


def file_size(root, path, staged=False):
    if staged:
        return int(git(root, 'cat-file', '-s', f':{path}').stdout)
    return os.path.getsize(os.path.join(root, path))


def read_text(root, path, limit=4 * 1024 * 1024, staged=False):
    if staged:
        if file_size(root, path, staged=True) > limit:
            return None
        data = git(root, 'show', f':{path}').stdout
        return None if b'\0' in data[:8192] else data.decode('utf-8', 'replace')
    full = os.path.join(root, path)
    try:
        if os.path.getsize(full) > limit:
            return None
        with open(full, 'rb') as handle:
            data = handle.read()
    except OSError:
        return None
    if b'\0' in data[:8192]:
        return None
    return data.decode('utf-8', 'replace')


def words(text):
    return len(text.split())


def size_text(count):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if count < 1024 or unit == 'GB':
            return f'{count:.0f} {unit}' if unit == 'B' else f'{count:.1f} {unit}'
        count /= 1024


def classify_plan(rel):
    """Return (initiative, kind) for a path relative to PLANS_ROOT. kind None means not allowed."""
    parts = rel.split('/')
    if len(parts) == 1:
        return None, ('plans index' if parts[0] in PLANS_ROOT_FILES else None)
    initiative = parts[0]
    if len(parts) == 2:
        if parts[1] == MASTER_PLAN:
            return initiative, 'master plan'
        return initiative, ('contract doc' if parts[1].endswith('.md') else None)
    if parts[1] == 'phases' and len(parts) >= 4 and re.fullmatch(PHASE_DIR, parts[2]):
        tail = parts[3:]
        if tail == ['README.md']:
            return initiative, 'phase README'
        if len(tail) == 2 and tail[0] == 'decisions' and re.fullmatch(DECISION_FILE, tail[1]):
            return initiative, 'decision record'
        if len(tail) >= 2 and tail[0] == 'working':
            if tail[-1].endswith('.md'):
                return initiative, 'working note'
            if tail[-1].endswith('.json'):
                return initiative, 'working data'
    return initiative, None


def master_status(text):
    """Return (status, problem) for a master plan."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or not lines[0].startswith('# '):
        return None, 'must start with a "# " title line.'
    match = STATUS_LINE.fullmatch(lines[1]) if len(lines) > 1 else None
    if not match:
        return None, 'needs "Status: active" or "Status: complete" as the first line after the title.'
    return match.group(1), None


def link_targets(text):
    prose = INLINE_CODE.sub('', FENCE.sub('', text))
    return INLINE_LINK.findall(prose) + REF_LINK.findall(prose)


def check_link(path, target, present, dirs):
    """Return a problem message for one Markdown link target, or None."""
    if target.startswith(('#', '//')) or URL_SCHEME.match(target):
        return None
    local = unquote(target.split('#', 1)[0].split('?', 1)[0])
    if not local:
        return None
    if local == '/tmp' or local.startswith('/tmp/'):
        return f'links to scratch {target}. Nobody else can open it. Quote the result instead.'
    if local.startswith('/'):
        resolved = posixpath.normpath(local.lstrip('/'))
    else:
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), local))
    if resolved == '..' or resolved.startswith('../'):
        return f'links outside the repository: {target}.'
    if under(resolved, SCRATCH_DIR):
        return f'links to scratch {target}. Nobody else can open it. Quote the result instead.'
    if resolved in present or resolved in dirs or resolved == '.':
        return None
    return f'broken link {target}.'


def mention_regex():
    alternatives = re.escape(PLANS_ROOT.strip('/'))
    return re.compile(r'(?<![\w./-])(?:\.\.?/)*((?:' + alternatives + r')/[\w.@+-]+(?:/[\w.@+-]+)*/?)')


def missing_mentions(text, present, dirs, pattern):
    """Yield plan paths named in text that do not exist."""
    for match in pattern.finditer(text):
        following = text[match.end():match.end() + 1]
        name = match.group(1).rstrip('./')
        if (following and following in '<*{[$%') or PLACEHOLDER.search(name):
            continue
        if name not in present and name not in dirs:
            yield name


def check(root, staged=False):
    files = list_files(root, staged)
    present = set(files)
    dirs = ancestors(files)
    problems = []

    def problem(path, message):
        problems.append(f'{path}: {message}')

    # Repository-wide: scratch, banned types and large files.
    scratch_tracked = [p for p in files if under(p, SCRATCH_DIR)]
    for path in scratch_tracked:
        problem(path, f'is inside scratch {SCRATCH_DIR}/ but tracked or not ignored. '
                      f'Run git rm --cached on it and ignore {SCRATCH_DIR}/.')
    if SCRATCH_DIR and not scratch_tracked:
        if not scratch_ignored(root, files, staged):
            problem('.gitignore', f'does not ignore {SCRATCH_DIR}/. Add the line /{SCRATCH_DIR}/.')
    for path in files:
        if under(path, SCRATCH_DIR):
            continue
        if path.lower().endswith(BANNED_SUFFIXES):
            problem(path, 'has a banned file type. Keep it in scratch and quote the result in the commit message.')
        size = file_size(root, path, staged)
        if LARGE_FILE_BYTES and size > LARGE_FILE_BYTES and not any(
                fnmatch.fnmatch(path, pattern) for pattern in LARGE_FILE_ALLOW):
            problem(path, f'is {size_text(size)}, over the {size_text(LARGE_FILE_BYTES)} cap for tracked files. '
                          'Git keeps it forever. Move it to scratch or build it locally.')

    # Standing docs.
    seen = set()
    for name in STANDING_DOCS:
        full = os.path.join(root, name)
        if (name not in present if staged else not os.path.isfile(full)) or os.path.realpath(full) in seen:
            continue
        seen.add(os.path.realpath(full))
        text = read_text(root, name, staged=staged) or ''
        count = words(text)
        if count > STANDING_MAX_WORDS:
            problem(name, f'{count} words exceeds {STANDING_MAX_WORDS}. Move specs to docs/ and '
                          'status to the master plan. Keep rules and permissions only.')
        prose = FENCE.sub('', text)
        for heading in HEADING.findall(prose):
            if DATE.search(heading) or CHRONOLOGY.search(heading):
                problem(name, f'heading "{heading.strip()}" is dated chronology. '
                              'Edit the standing rule in place. Put status in the master plan.')
        for line in DATED_LINE.findall(prose):
            if DATE.search(line):
                problem(name, f'dated status line "{line.strip()[:60]}". Standing docs carry no dates.')

    # Plan workspace.
    initiatives = defaultdict(dict)
    for path in files:
        if not under(path, PLANS_ROOT) or path == PLANS_ROOT:
            continue
        rel = path[len(PLANS_ROOT.rstrip('/')) + 1:]
        initiative, kind = classify_plan(rel)
        if initiative:
            initiatives[initiative][path] = kind
        stem = posixpath.splitext(posixpath.basename(path))[0]
        if kind != 'decision record' and COPY_NAME.search(stem):
            problem(path, 'looks like an attempt, retry, addendum or version copy. '
                          'Replace the stale file in place. Git keeps the old version.')
        if kind is None:
            problem(path, 'is not an allowed plan record. Allowed: master-plan.md, contract docs, '
                          'phases/<phase>/README.md, decisions/NNNN-title.md and working/*.md or *.json.')
            continue
        if kind == 'working data':
            size = file_size(root, path, staged)
            if size > WORKING_JSON_MAX_BYTES:
                problem(path, f'is {size_text(size)}, over the {size_text(WORKING_JSON_MAX_BYTES)} '
                              'limit for working JSON. Keep large data in scratch.')
            continue
        text = read_text(root, path, staged=staged) or ''
        if kind == 'master plan':
            status, issue = master_status(text)
            if issue:
                problem(path, issue)
            limit_name = 'complete master plan' if status == 'complete' else 'active master plan'
            if status != 'complete' and not NEXT_HEADING.search(text):
                problem(path, 'an active master plan needs a Next section.')
        else:
            limit_name = kind
            if kind == 'phase README' and not NEXT_HEADING.search(text):
                problem(path, 'a phase README needs a Next section.')
        count = words(text)
        if count > WORD_LIMITS[limit_name]:
            problem(path, f'{count} words exceeds the {WORD_LIMITS[limit_name]}-word limit for a {limit_name}.')

    for initiative, records in sorted(initiatives.items()):
        top = f'{PLANS_ROOT.rstrip("/")}/{initiative}'
        master = f'{top}/{MASTER_PLAN}'
        if master not in records:
            problem(top + '/', f'has no {MASTER_PLAN}. Every initiative needs one with a Status line.')
            continue
        status, _ = master_status(read_text(root, master, staged=staged) or '')
        if status == 'complete':
            for path, kind in sorted(records.items()):
                if kind not in KEPT_WHEN_COMPLETE:
                    problem(path, 'is in a complete initiative. Close-out keeps only the master plan, '
                                  'contract docs and decision records in force. Delete it.')

    # Links and mentions in Markdown.
    markdown = [p for p in files if p.lower().endswith('.md')
                and not any(fnmatch.fnmatch(p, pattern) for pattern in SCAN_EXCLUDE)]
    texts = {p: read_text(root, p, staged=staged) or '' for p in markdown}
    pattern = mention_regex()
    for path, text in texts.items():
        for target in link_targets(text):
            issue = check_link(path, target, present, dirs)
            if issue:
                problem(path, issue)
        for name in sorted(set(missing_mentions(text, present, dirs, pattern))):
            problem(path, f'names {name}, which does not exist. Point to the record that holds it now.')

    return problems


def inventory(root):
    files = list_files(root)
    sizes = {path: os.path.getsize(os.path.join(root, path)) for path in files}
    print(f'{len(files)} files, {size_text(sum(sizes.values()))} (tracked or addable)')
    areas = defaultdict(lambda: [0, 0])
    for path, size in sizes.items():
        key = '/'.join(path.split('/')[:-1][:2]) or '(top level)'
        areas[key][0] += size
        areas[key][1] += 1
    print('\nLargest areas (top two folder levels):')
    for key, (size, count) in sorted(areas.items(), key=lambda item: -item[1][0])[:20]:
        print(f'  {size_text(size):>10}  {count:6d} files  {key}')
    print('\nLargest files:')
    for path, size in sorted(sizes.items(), key=lambda item: -item[1])[:15]:
        print(f'  {size_text(size):>10}  {path}')
    initiatives = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    for path in files:
        if under(path, PLANS_ROOT) and path != PLANS_ROOT:
            initiative, kind = classify_plan(path[len(PLANS_ROOT.rstrip('/')) + 1:])
            entry = initiatives[initiative or '(plans root)'][kind or 'not allowed']
            entry[0] += 1
            entry[1] += sizes[path]
    if initiatives:
        print(f'\nInitiatives under {PLANS_ROOT}:')
    for initiative, kinds in sorted(initiatives.items()):
        master = f'{PLANS_ROOT.rstrip("/")}/{initiative}/{MASTER_PLAN}'
        status = master_status(read_text(root, master) or '')[0] if master in sizes else None
        total = sum(count for count, _ in kinds.values()), sum(size for _, size in kinds.values())
        print(f'  {initiative}: status {status or "unknown"}, {total[0]} files, {size_text(total[1])}')
        for kind, (count, size) in sorted(kinds.items()):
            print(f'      {count:6d}  {size_text(size):>10}  {kind}')
    objects = git(root, 'count-objects', '-vH', check=False).stdout.decode('utf-8', 'replace')
    pack = [line for line in objects.splitlines() if line.startswith(('size-pack', 'size:'))]
    if pack:
        print('\nGit object store: ' + ', '.join(pack))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--root', help='repository work tree (default: the Git top level of the current folder)')
    parser.add_argument('--staged', action='store_true', help='check only the files in the index (the next commit)')
    parser.add_argument('--inventory', action='store_true', help='print counts and bytes by area, then exit 0')
    args = parser.parse_args(argv)
    try:
        root = args.root or git(os.getcwd(), 'rev-parse', '--show-toplevel').stdout.decode().strip()
        root = os.path.abspath(root)
        if args.inventory:
            inventory(root)
            return 0
        problems = check(root, args.staged)
    except CheckError as error:
        print(f'check_records: {error}', file=sys.stderr)
        return 2
    for line in problems:
        print(line)
    if problems:
        print(f'{len(problems)} record problem(s). See docs/records-policy.md.', file=sys.stderr)
        return 1
    print('Records follow the policy.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
