#!/usr/bin/env python3
"""Check that large files stop growing and that import boundaries hold.

    python3 tools/check_structure.py [--root PATH] [--config PATH] [--staged]
                                     [--update] [--baseline] [--report]

Copy this file into the repository with a structure.json next to it (or pass
--config). It uses only the Python standard library. The config lists the
files to measure (`include`, `exclude`), the line limit (`maxLines`), the
growth a recorded large file may still take (`growth`), those recorded sizes
(`sizes`), and boundary `rules` (a forbidden regex per set of files).

The default check reads the files Git tracks or would add
(`git ls-files --cached --others --exclude-standard`), from the work tree.
--staged reads only the staged files and the staged config, so an unstaged
edit cannot loosen the check. It also compares the staged config with
HEAD's and fails when the change loosens it: a recorded size added or raised,
an allow entry added, a rule removed or its files or forbid changed, maxLines
or growth raised, or fewer files checked (an exclude pattern added or changed,
an include pattern removed or changed). Only the orchestrator or the user commits such a change,
with STRUCTURE_ALLOW_CONFIG_CHANGE=1 in the environment and the reason in the
commit message. A rename of a recorded file (staged, or made with git mv) carries its size.
--staged also fails when the config is deleted or untracked in the commit while HEAD has it,
and reports an invalid HEAD config as a problem the same opt-in allows.
--update only ratchets the config down: it lowers or removes recorded sizes
(moving a size to the new path of a file renamed since HEAD; after a plain mv it keeps
the size and asks you to stage the rename first) and drops allow
entries that no longer apply. It never adds or raises, so any worker may run it.
--baseline is for setup, run by the orchestrator or the user. It records
files over the limit that have no recorded size and rule violations not yet
allowed. It never changes an existing size; raising one is the orchestrator's
or the user's decision.
--report prints large files and allow lists and judges nothing.

Exit status: 0 when the structure holds, 1 when there are problems, 2 when
the check cannot run.
"""
import argparse
import functools
import json
import os
import re
import subprocess
import sys


class CheckError(Exception):
    pass


def git(root, *args, check=True):
    try:
        return subprocess.run(['git', '-C', root, *args], capture_output=True, check=check)
    except FileNotFoundError as error:
        raise CheckError(f'git is unavailable: {error.strerror}') from None
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise CheckError(f'git {args[0]} failed in {root}: {detail[-1] if detail else error.returncode}') from None


@functools.lru_cache(maxsize=None)
def glob_regex(pattern):
    parts = pattern.split('/')
    out = []
    for i, part in enumerate(parts):
        last = i == len(parts) - 1
        if part == '**':
            out.append('.*' if last else '(?:[^/]+/)*')
            continue
        out.append(''.join('[^/]*' if c == '*' else '[^/]' if c == '?' else re.escape(c) for c in part))
        if not last:
            out.append('/')
    return re.compile(''.join(out) + r'\Z')


def matches(path, patterns):
    return any(glob_regex(p).match(path) for p in patterns)


def load_config(text):
    try:
        raw = json.loads(text, object_pairs_hook=dict)
    except ValueError as error:
        raise CheckError(f'config is not valid JSON: {error}') from None
    if not isinstance(raw, dict):
        raise CheckError('config must be a JSON object')

    def need(key, kind, default=None, nonempty=False):
        if key not in raw:
            if default is None:
                raise CheckError(f'config needs "{key}"')
            return default
        value = raw[key]
        ok = isinstance(value, kind) and not isinstance(value, bool)
        if not ok or (nonempty and not value):
            raise CheckError(f'config "{key}" must be a {"non-empty " if nonempty else ""}{kind.__name__}')
        return value

    def strings(owner, key, nonempty=False):
        value = owner.get(key, [])
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value) or (nonempty and not value):
            raise CheckError(f'"{key}" must be a {"non-empty " if nonempty else ""}list of strings')

    need('include', list, nonempty=True)
    for key in ('include', 'exclude'):
        strings(raw, key)
    if need('maxLines', int) < 1:
        raise CheckError('config "maxLines" must be a positive integer')
    if need('growth', int, 50) < 0:
        raise CheckError('config "growth" must be an integer of 0 or more')
    need('map', str, 'the architecture map')
    sizes = need('sizes', dict, {})
    if not all(isinstance(v, int) and not isinstance(v, bool) for v in sizes.values()):
        raise CheckError('config "sizes" must map paths to integers')
    rules = need('rules', list, [])
    for rule in rules:
        if not isinstance(rule, dict):
            raise CheckError('each rule must be an object')
        for key in ('name', 'forbid', 'why', 'fix'):
            if not isinstance(rule.get(key), str):
                raise CheckError(f'each rule needs a string "{key}"')
        strings(rule, 'files', nonempty=True)
        strings(rule, 'allow')
        try:
            re.compile(rule['forbid'])
        except re.error as error:
            raise CheckError(f'rule "{rule["name"]}" has an invalid regex: {error}') from None
    names = [rule['name'] for rule in rules]
    if len(set(names)) != len(names):
        raise CheckError('rule names must be unique: the comparison with HEAD matches rules by name')
    return raw


def config_rel(root, config_path):
    return os.path.relpath(os.path.realpath(config_path), os.path.realpath(root)).replace(os.sep, '/')


def read_config(root, config_path, staged):
    rel = config_rel(root, config_path)
    if staged and not rel.startswith('../'):
        shown = git(root, 'show', f':{rel}', check=False)
        if shown.returncode == 0:
            return shown.stdout.decode('utf-8', 'replace')
        in_head = git(root, 'cat-file', '-e', f'HEAD:{rel}', check=False).returncode == 0
        if in_head and os.environ.get('STRUCTURE_ALLOW_CONFIG_CHANGE') != '1':
            raise CheckError(f'the structure config {rel} is deleted or untracked in this commit, so the staged '
                             f'check has nothing to compare; restore it with git add, or {ASK}')
    try:
        with open(config_path, encoding='utf-8') as handle:
            return handle.read()
    except FileNotFoundError:
        raise CheckError(f'no structure config at {config_path}; ask the orchestrator or the user to set up code-structure') from None
    except OSError as error:
        raise CheckError(f'cannot read {config_path}: {error.strerror}') from None
    except UnicodeDecodeError:
        raise CheckError(f'cannot read {config_path}: not valid UTF-8') from None


def has_head(root):
    return git(root, 'rev-parse', '--verify', '-q', 'HEAD', check=False).returncode == 0


def renames(root, staged):
    """Return {new path: old path} for files renamed in the index (staged) or in the work tree, against HEAD."""
    if not has_head(root):
        return {}
    out = git(root, 'diff', '--cached' if staged else 'HEAD', '-M', '--name-status', '-z', '--diff-filter=R').stdout
    tokens = out.decode('utf-8', 'replace').split('\0')
    return {new: old for old, new in zip(tokens[1::3], tokens[2::3])}


def list_files(root, staged):
    if staged:
        if has_head(root):
            out = git(root, 'diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR').stdout
        else:
            out = git(root, 'ls-files', '-z', '--cached').stdout
    else:
        out = git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard').stdout
    return sorted({n for n in out.decode('utf-8', 'replace').split('\0') if n})


def read_lines(root, path, staged):
    """Return the file's lines, or None when it is missing or binary."""
    if staged:
        shown = git(root, 'show', f':{path}', check=False)
        data = shown.stdout if shown.returncode == 0 else None
    else:
        try:
            with open(os.path.join(root, path), 'rb') as handle:
                data = handle.read()
        except OSError:
            data = None
    if data is None or b'\0' in data:
        return None
    # Split on newlines only, as `wc -l` does; splitlines() also breaks at form feeds and U+2028.
    lines = data.decode('utf-8', 'replace').split('\n')
    if lines[-1] == '':
        lines.pop()
    return lines


def relevant(cfg, path):
    return included(cfg, path) or any(matches(path, rule['files']) for rule in cfg.get('rules', []))


def scan(root, cfg, staged):
    """Return {path: lines} for each readable file that a size limit or a rule covers."""
    paths = [p for p in list_files(root, staged) if relevant(cfg, p)]
    return {p: lines for p in paths if (lines := read_lines(root, p, staged)) is not None}


def included(cfg, path):
    return matches(path, cfg['include']) and not matches(path, cfg.get('exclude', []))


def violations(rule, lines):
    pattern = re.compile(rule['forbid'])
    return [n for n, line in enumerate(lines, 1) if pattern.search(line)]


ASK = ('ask the orchestrator or the user; they commit the change with '
       'STRUCTURE_ALLOW_CONFIG_CHANGE=1 and give the reason.')


def loosening(cfg, old, moved):
    """Return (what changed, what to do instead) for each way cfg is looser than old, the config at HEAD."""
    found = []
    old_sizes = old.get('sizes', {})
    for path, size in cfg.get('sizes', {}).items():
        origin = moved.get(path)
        if path in old_sizes and size > old_sizes[path]:
            found.append((f'recorded size for {path} raised from {old_sizes[path]} to {size}.', 'Move code out instead.'))
        elif path not in old_sizes and not (origin in old_sizes and origin not in cfg.get('sizes', {}) and size <= old_sizes[origin]):
            found.append((f'recorded size for {path} added ({size} lines).', 'Move code out instead of recording a size.'))
    old_rules = {rule['name']: rule for rule in old.get('rules', [])}
    new_rules = {rule['name']: rule for rule in cfg.get('rules', [])}
    for name, rule in old_rules.items():
        if name not in new_rules:
            found.append((f'rule "{name}" removed.', 'Keep the rule.'))
        elif any(new_rules[name][key] != rule[key] for key in ('files', 'forbid')):
            found.append((f'rule "{name}" changed its files or forbid.', 'Keep the rule as it was.'))
    for name, rule in new_rules.items():
        for path in rule.get('allow', []):
            if path not in old_rules.get(name, {}).get('allow', []):
                found.append((f'rule "{name}" now allows {path}.', 'Fix the violation instead.'))
    for pattern in cfg.get('exclude', []):
        if pattern not in old.get('exclude', []):
            found.append((f'exclude pattern {pattern} added or changed, so fewer files are checked.', 'Keep the checked set as it was.'))
    for pattern in old['include']:
        if pattern not in cfg['include']:
            found.append((f'include pattern {pattern} removed or changed, so fewer files are checked.', 'Keep the checked set as it was.'))
    for key, default in (('maxLines', None), ('growth', 50)):
        if cfg.get(key, default) > old.get(key, default):
            found.append((f'{key} raised from {old.get(key, default)} to {cfg.get(key, default)}.', f'Keep {key} as it was.'))
    return found


def config_findings(root, config_path, cfg, moved):
    """Compare the staged config with HEAD's. Return (problems, notes)."""
    rel = config_rel(root, config_path)
    if rel.startswith('../'):
        return [], []
    origin = rel if git(root, 'cat-file', '-e', f'HEAD:{rel}', check=False).returncode == 0 else moved.get(rel)
    head = git(root, 'show', f'HEAD:{origin}', check=False) if origin else None
    if head is None or head.returncode != 0:
        return [], [f'{rel} is new in this commit. From the next commit its sizes, allow lists and limits may only go down.']
    allowed = os.environ.get('STRUCTURE_ALLOW_CONFIG_CHANGE') == '1'
    try:
        found = loosening(cfg, load_config(head.stdout.decode('utf-8', 'replace')), moved)
    except CheckError as error:
        found = [(f"HEAD's structure config {origin} is invalid ({error}); compare by hand.", '')]
    if allowed:
        return [], [f'{rel}: {what} Allowed by STRUCTURE_ALLOW_CONFIG_CHANGE=1; the commit message must give the reason.' for what, _ in found]
    return [(rel, 0, ' '.join(filter(None, [f'{rel}: {what}', instead, f'If the change is needed, {ASK}']))) for what, instead in found], []


def check(root, cfg, staged, config_path=None):
    files = scan(root, cfg, staged)
    limit, growth, sizes, map_name = cfg['maxLines'], cfg.get('growth', 50), cfg.get('sizes', {}), cfg.get('map', 'the architecture map')
    problems, notes = [], []
    moved = renames(root, staged)
    if staged and config_path:
        problems, notes = config_findings(root, config_path, cfg, moved)
    for path, lines in files.items():
        count = len(lines)
        if included(cfg, path):
            recorded = sizes.get(path, sizes.get(moved.get(path)))
            if recorded is None and count > limit:
                problems.append((path, 0, f'{path}: {count} lines, over the {limit}-line limit. Split it by what each part '
                                 f'owns; see {map_name}. Do not add a recorded size yourself; if the file should stay whole, ask the orchestrator or the user.'))
            elif recorded is not None and count > recorded + growth:
                where = f' (recorded for {moved[path]})' if path not in sizes else ''
                problems.append((path, 0, f'{path}: {count} lines, {count - recorded} past its recorded size of {recorded}{where} '
                                 f'(at most {growth} allowed). Put the new code in its own file or move code out of this one; see {map_name}. '
                                 f'Do not raise the recorded size; if the file should stay whole, ask the orchestrator or the user.'))
        for rule in cfg.get('rules', []):
            if matches(path, rule['files']) and path not in rule.get('allow', []):
                for n in violations(rule, lines):
                    problems.append((path, n, f'{path}:{n}: {rule["name"]}. {rule["why"]} Fix: {rule["fix"]}'))
    if not staged:
        for path, size in sizes.items():
            if path not in files:
                notes.append(f'{path} is in sizes but no longer exists or is no longer covered. Run --update.')
            elif len(files[path]) <= limit:
                notes.append(f'{path} is in sizes but is now at or under {limit} lines. Run --update.')
            elif len(files[path]) < size:
                notes.append(f'{path} shrank below its recorded size of {size}. Run --update.')
        for rule in cfg.get('rules', []):
            for path in rule.get('allow', []):
                if path not in files or not violations(rule, files[path]):
                    notes.append(f'{path} is allowed by "{rule["name"]}" but no longer violates it. Run --update.')
    for _, _, message in sorted(problems, key=lambda p: (p[0], p[1])):
        print(message)
    if problems:
        print(f'Structure check failed: {len(problems)} problem(s). See {map_name}.')
    else:
        print('Structure follows the map.')
    for note in notes:
        print(f'note: {note}')
    return 1 if problems else 0


def write_config(path, cfg):
    with open(path, 'w', encoding='utf-8') as handle:
        json.dump(cfg, handle, indent=2)
        handle.write('\n')


def update(root, cfg, config_path):
    files = scan(root, cfg, False)
    now_at = {old: new for new, old in renames(root, False).items()}
    limit, sizes, changes, notes = cfg['maxLines'], cfg.get('sizes', {}), [], []
    # A plain mv leaves the new file untracked, where Git cannot see a rename: keep the size until it is staged.
    untracked = {p for p in git(root, 'ls-files', '-z', '--others', '--exclude-standard').stdout.decode('utf-8', 'replace').split('\0')
                 if p in files and included(cfg, p) and p not in sizes}
    for path, size in list(sizes.items()):
        new = now_at.get(path)
        if path not in files and new in files and included(cfg, new):
            del sizes[path]
            count = len(files[new])
            if count <= limit:
                changes.append(f'removed size for {path}: moved to {new}, {count} lines, at or under {limit}')
            elif new not in sizes:
                sizes[new] = min(size, count)
                changes.append(f'moved size for {path} to {new}: {sizes[new]}')
        elif path not in files and untracked:
            notes.append(f'{path} is gone but untracked files are covered: if one is its move, stage the rename '
                         f'(git add), then run --update again. Its size is kept for now.')
        elif path not in files:
            del sizes[path]
            changes.append(f'removed size for {path}: file no longer exists or is no longer covered')
        elif len(files[path]) <= limit:
            del sizes[path]
            changes.append(f'removed size for {path}: {len(files[path])} lines, at or under {limit}')
        elif len(files[path]) < size:
            sizes[path] = len(files[path])
            changes.append(f'lowered size for {path}: {size} to {len(files[path])}')
    for rule in cfg.get('rules', []):
        for path in list(rule.get('allow', [])):
            if path not in files or not violations(rule, files[path]):
                rule['allow'].remove(path)
                changes.append(f'removed {path} from allow of "{rule["name"]}"')
    return finish(config_path, cfg, changes, notes)


def baseline(root, cfg, config_path):
    files = scan(root, cfg, False)
    sizes, changes = cfg.setdefault('sizes', {}), []
    for path, lines in files.items():
        if included(cfg, path) and len(lines) > cfg['maxLines'] and path not in sizes:
            changes.append(f'recorded size for {path}: {len(lines)}')
            sizes[path] = len(lines)
        for rule in cfg.get('rules', []):
            allow = rule.setdefault('allow', [])
            if matches(path, rule['files']) and path not in allow and violations(rule, lines):
                allow.append(path)
                allow.sort()
                changes.append(f'allowed {path} in "{rule["name"]}"')
    return finish(config_path, cfg, changes)


def finish(config_path, cfg, changes, notes=()):
    if changes:
        write_config(config_path, cfg)
    print('\n'.join(changes) if changes else 'Nothing to update.')
    for note in notes:
        print(f'note: {note}')
    return 0


def report(root, cfg):
    files = scan(root, cfg, False)
    sizes, growth = cfg.get('sizes', {}), cfg.get('growth', 50)
    print(f'Files over {cfg["maxLines"]} lines:')
    for path, lines in sorted(files.items(), key=lambda kv: -len(kv[1])):
        if included(cfg, path) and len(lines) > cfg['maxLines']:
            if path in sizes:
                room = max(0, sizes[path] + growth - len(lines))
                print(f'  {path}: {len(lines)} lines, recorded {sizes[path]}, {room} lines of growth left')
            else:
                print(f'  {path}: {len(lines)} lines, no recorded size')
    for rule in cfg.get('rules', []):
        print(f'Allowed for "{rule["name"]}":')
        for path in rule.get('allow', []):
            print(f'  {path}')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--root', help='repository work tree (default: git top level of the current folder)')
    parser.add_argument('--config', help='config file (default: structure.json beside this script)')
    parser.add_argument('--staged', action='store_true', help='check only staged files and the staged config')
    parser.add_argument('--update', action='store_true', help='lower recorded sizes and shorten allow lists; follows renames')
    parser.add_argument('--baseline', action='store_true', help='setup only: record large files and violations not yet recorded')
    parser.add_argument('--report', action='store_true', help='print large files and allow lists')
    args = parser.parse_args()
    modes = [m for m in ('update', 'baseline', 'report') if getattr(args, m)]
    if len(modes) > 1 or (modes and args.staged):
        parser.error('use only one of --update, --baseline, --report, and --staged only with the default check')
    try:
        root = args.root
        if root is None:
            top = git('.', 'rev-parse', '--show-toplevel').stdout.decode().strip()
            root = top
        config_path = args.config or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'structure.json')
        cfg = load_config(read_config(root, config_path, args.staged))
        if modes == ['update']:
            return update(root, cfg, config_path)
        if modes == ['baseline']:
            return baseline(root, cfg, config_path)
        if modes == ['report']:
            return report(root, cfg)
        return check(root, cfg, args.staged, config_path)
    except CheckError as error:
        print(f'check_structure: {error}', file=sys.stderr)
        return 2
    except OSError as error:
        print(f'check_structure: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
