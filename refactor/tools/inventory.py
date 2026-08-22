#!/usr/bin/env python3
"""Symbol inventory for mux: every top-level and nested declaration in Rust and
Swift, with line spans, plus per-file comment/blank/code counts and a
cross-file reference count per symbol name. Output: inventory.json + a
markdown table. Uses ast-grep for parsing (no regex guessing at structure)."""
import json, subprocess, re, sys, os, collections
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get('INVENTORY_OUT', '/tmp')
os.chdir(ROOT)

def files(ext):
    out = subprocess.run(['fd', '-e', ext, '.', '--exclude', '.build', '--exclude', 'target',
                          '--exclude', '.worktrees', '--exclude', 'GhosttyKit'], capture_output=True, text=True).stdout.split()
    return sorted(f for f in out if 'scripts/make-icon' not in f)

RUST_KINDS = {
    'function_item': 'fn', 'struct_item': 'struct', 'enum_item': 'enum', 'trait_item': 'trait',
    'impl_item': 'impl', 'mod_item': 'mod', 'const_item': 'const', 'static_item': 'static',
    'type_item': 'type', 'macro_definition': 'macro',
}
SWIFT_KINDS = {
    'class_declaration': 'class', 'protocol_declaration': 'protocol', 'function_declaration': 'func',
    'property_declaration': 'var', 'init_declaration': 'init', 'deinit_declaration': 'deinit',
    'typealias_declaration': 'typealias', 'enum_entry': 'case',
}


def sg_kind(lang, kind, path):
    rule = json.dumps({'id': 'x', 'language': lang, 'rule': {'kind': kind}})
    r = subprocess.run(['ast-grep', 'scan', '--inline-rules', rule, '--json=compact', path],
                       capture_output=True, text=True)
    if r.returncode not in (0, 1):
        print(r.stderr, file=sys.stderr)
    return json.loads(r.stdout or '[]')

NAME_RE = {
    'rust': re.compile(r'^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+|extern\s+"C"\s+)*(?:fn|struct|enum|trait|mod|const|static|type|macro_rules!)\s+([A-Za-z_][A-Za-z0-9_]*)'),
    'impl': re.compile(r'^\s*(?:unsafe\s+)?impl(?:<[^>]*>)?\s+(.+?)\s*(?:\{|where)', re.S),
    'swift': re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|override|class|weak|lazy|required|convenience|indirect|mutating|@objc|@MainActor)\s+)*(?:class|struct|enum|protocol|extension|func|var|let|init|deinit|typealias|case)\s+([A-Za-z_][A-Za-z0-9_]*)?'),
}

def count_lines(path, lang):
    code = comment = blank = 0
    in_block = False
    for line in open(path, encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s: blank += 1; continue
        if in_block:
            comment += 1
            if '*/' in s: in_block = False
            continue
        if s.startswith('/*'):
            comment += 1
            if '*/' not in s: in_block = True
            continue
        if s.startswith('//') or (lang == 'python' and s.startswith('#')):
            comment += 1; continue
        code += 1
    return code, comment, blank

inv = {'files': {}, 'symbols': []}
for lang, ext, kinds in (('rust', 'rs', RUST_KINDS), ('swift', 'swift', SWIFT_KINDS)):
    for f in files(ext):
        code, comment, blank = count_lines(f, lang)
        inv['files'][f] = {'lang': lang, 'code': code, 'comment': comment, 'blank': blank,
                           'total': code + comment + blank}
        for kind, label in kinds.items():
            for m in sg_kind(lang, kind, f):
                text = m['text']
                first = text.split('\n', 1)[0]
                if lang == 'rust':
                    if kind == 'impl_item':
                        mm = NAME_RE['impl'].match(text); name = (mm.group(1) if mm else first).strip()
                    else:
                        mm = NAME_RE['rust'].match(first); name = mm.group(1) if mm else first[:40]
                else:
                    mm = NAME_RE['swift'].match(first); name = (mm.group(1) if mm and mm.group(1) else first[:40])
                    if kind == 'property_declaration':
                        mm2 = re.search(r'(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)', first); name = mm2.group(1) if mm2 else name
                    if kind == 'class_declaration':
                        mm2 = re.search(r'(class|struct|enum|extension|actor)\s+([A-Za-z_][A-Za-z0-9_.]*)', first)
                        if mm2: label, name = mm2.group(1), mm2.group(2)
                s, e = m['range']['start']['line'] + 1, m['range']['end']['line'] + 1
                inv['symbols'].append({'file': f, 'kind': label, 'name': name, 'start': s, 'end': e,
                                       'lines': e - s + 1, 'lang': lang,
                                       'pub': first.lstrip().startswith('pub') if lang == 'rust' else not re.match(r'^\s*(?:@\w+\s+)*(?:private|fileprivate)', first)})

# reference counts: how many files mention each symbol name (excluding its own file), names >= 4 chars
names = collections.defaultdict(set)
for s in inv['symbols']:
    if s['kind'] in ('fn', 'func', 'struct', 'enum', 'trait', 'class', 'protocol', 'const', 'static', 'type', 'var', 'init') and len(s['name']) >= 4 and s['name'] not in ('main', 'init', 'new', 'layout', 'render'):
        names[s['name']].add(s['file'])
srcs = files('rs') + files('swift')
text = {f: open(f, encoding='utf-8', errors='replace').read() for f in srcs}
refs = {}
for n, defs in names.items():
    pat = re.compile(r'\b' + re.escape(n) + r'\b')
    total = 0; other = 0
    for f, t in text.items():
        c = len(pat.findall(t))
        total += c
        if f not in defs: other += c
    refs[n] = {'total': total, 'other_files': other, 'defined_in': sorted(defs)}
inv['refs'] = refs
json.dump(inv, open(OUT + '/inventory.json', 'w'), indent=1)

# markdown summary
out = []
out.append('| file | code | comment | blank | comment% | symbols |')
out.append('|---|---:|---:|---:|---:|---:|')
for f, d in sorted(inv['files'].items(), key=lambda kv: -kv[1]['total']):
    n = sum(1 for s in inv['symbols'] if s['file'] == f)
    pct = 100 * d['comment'] / max(1, d['code'] + d['comment'])
    out.append(f"| {f} | {d['code']} | {d['comment']} | {d['blank']} | {pct:.0f}% | {n} |")
open(OUT + '/files.md', 'w').write('\n'.join(out))
tot = collections.Counter()
for d in inv['files'].values():
    tot[d['lang'] + '_code'] += d['code']; tot[d['lang'] + '_comment'] += d['comment']
print(dict(tot))
print(len(inv['symbols']), 'symbols;', len(refs), 'named refs')
