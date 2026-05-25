#!/usr/bin/env python3
"""
Erzeugt einen HTML-Coverage-Report aus einem Xcode-`.xcresult`-Bundle.

Ausgabe:
    build/coverage/index.html                  – Übersicht
    build/coverage/<file>.html                 – Zeilen-Detail je Quelldatei
    build/coverage/cobertura.xml               – Cobertura-XML (für CI / Sonar)
    build/coverage/sonarqube-generic-coverage.xml – SonarQube Generic Test Coverage

Aufruf:
    python3 scripts/render_coverage.py build/Test.xcresult build/coverage
"""

import json
import os
import re
import subprocess
import sys
from collections import OrderedDict
from html import escape
from xml.sax.saxutils import escape as xml_escape


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 and not result.stdout:
        print(f"WARN: {cmd} failed: {result.stderr}", file=sys.stderr)
    return result.stdout


def parse_xccov_per_line(xcresult_path, source_path):
    """Returns list of (line_no, executed_count_or_None, branches) for an executable source file.
    `branches` is a list of (column, false_hits, true_hits) tuples or empty list."""
    out = run(['xcrun', 'xccov', 'view', '--archive', '--file', source_path, xcresult_path])
    lines = []
    current_line = None
    for raw in out.splitlines():
        m = re.match(r'^\s*(\d+):\s+(\*|\d+)(\s+\[)?$', raw)
        if m:
            ln = int(m.group(1))
            val = m.group(2)
            has_branches = m.group(3) is not None
            count = None if val == '*' else int(val)
            current_line = {'line': ln, 'count': count, 'branches': []}
            lines.append(current_line)
            continue
        m2 = re.match(r'^\((\d+),\s*(\d+),\s*(\d+)\)\s*$', raw.strip())
        if m2 and current_line is not None:
            current_line['branches'].append({
                'column': int(m2.group(1)),
                'false_hits': int(m2.group(2)),
                'true_hits': int(m2.group(3)),
            })
        # ignore `]` end markers
    return lines


def coverage_color(pct):
    if pct >= 90: return '#28a745'
    if pct >= 75: return '#5cb85c'
    if pct >= 50: return '#f0ad4e'
    if pct >= 25: return '#fd7e14'
    return '#dc3545'


def render_index(summary, app_target, files_meta, out_dir, project_name):
    overall_pct = summary['lineCoverage'] * 100
    app_pct = app_target['coveredLines'] / app_target['executableLines'] * 100 if app_target['executableLines'] else 0

    rows = []
    for f in sorted(files_meta, key=lambda x: -x['coverage']):
        pct = f['coverage']
        color = coverage_color(pct)
        cov_lines = int(round(pct / 100 * f['executable']))
        link = f"{f['html']}"
        rows.append(f"""
        <tr>
          <td><a href="{escape(link)}">{escape(f['rel_path'])}</a></td>
          <td style="text-align:right">{f['executable']}</td>
          <td style="text-align:right">{cov_lines}</td>
          <td style="text-align:right">
            <span class="bar"><span class="bar-fill" style="width:{pct:.1f}%; background:{color}"></span></span>
            <span class="pct">{pct:.1f}%</span>
          </td>
        </tr>""")

    html = f"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>Coverage Report – {project_name}</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 1100px; margin: 30px auto; padding: 0 20px; color: #222; }}
  h1 {{ border-bottom: 2px solid #ddd; padding-bottom: 8px; }}
  .summary {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin: 20px 0; }}
  .stat {{ background: #f6f8fa; border: 1px solid #ddd; border-radius: 8px; padding: 18px; text-align: center; }}
  .stat .value {{ font-size: 36px; font-weight: 600; }}
  .stat .label {{ color: #666; font-size: 14px; }}
  table {{ width: 100%; border-collapse: collapse; margin-top: 20px; font-size: 14px; }}
  th, td {{ padding: 8px 10px; border-bottom: 1px solid #eee; }}
  th {{ background: #f6f8fa; text-align: left; font-weight: 600; }}
  td a {{ color: #0366d6; text-decoration: none; font-family: SF Mono, Menlo, monospace; }}
  td a:hover {{ text-decoration: underline; }}
  .bar {{ display: inline-block; width: 80px; height: 10px; background: #eee; border-radius: 5px; overflow: hidden; vertical-align: middle; margin-right: 6px; }}
  .bar-fill {{ display: block; height: 100%; }}
  .pct {{ display: inline-block; min-width: 50px; text-align: right; font-variant-numeric: tabular-nums; }}
  .meta {{ color: #666; font-size: 13px; margin-bottom: 20px; }}
</style>
</head>
<body>
<h1>Coverage Report – {project_name}</h1>
<p class="meta">Erzeugt aus Xcode <code>.xcresult</code>-Bundle · xccov + render_coverage.py</p>

<div class="summary">
  <div class="stat">
    <div class="value" style="color:{coverage_color(app_pct)}">{app_pct:.1f}%</div>
    <div class="label">App-Target Line Coverage<br>({app_target['coveredLines']}/{app_target['executableLines']} ausführbare Zeilen)</div>
  </div>
  <div class="stat">
    <div class="value">{len(files_meta)}</div>
    <div class="label">analysierte Quelldateien</div>
  </div>
  <div class="stat">
    <div class="value" style="color:{coverage_color(overall_pct)}">{overall_pct:.1f}%</div>
    <div class="label">Gesamt-Coverage (inkl. Frameworks)<br>({summary['coveredLines']}/{summary['executableLines']} Zeilen)</div>
  </div>
</div>

<table>
  <thead>
    <tr>
      <th>Datei</th>
      <th style="text-align:right">Ausführbar</th>
      <th style="text-align:right">Abgedeckt</th>
      <th style="text-align:right">Coverage</th>
    </tr>
  </thead>
  <tbody>{''.join(rows)}
  </tbody>
</table>
</body>
</html>"""
    with open(os.path.join(out_dir, 'index.html'), 'w') as f:
        f.write(html)


def render_file_detail(file_meta, source_root, xcresult_path, out_dir):
    abs_src = os.path.join(source_root, file_meta['rel_path'])
    if not os.path.exists(abs_src):
        return
    with open(abs_src, 'r', encoding='utf-8') as fh:
        source_lines = fh.readlines()

    cov = parse_xccov_per_line(xcresult_path, abs_src)
    cov_by_line = {c['line']: c for c in cov}

    rows = []
    for idx, line in enumerate(source_lines, start=1):
        info = cov_by_line.get(idx)
        css_class = 'unrelated'
        count_text = ''
        branch_text = ''
        if info and info['count'] is not None:
            count = info['count']
            css_class = 'hit' if count > 0 else 'miss'
            count_text = str(count)
            if info['branches']:
                bits = []
                for br in info['branches']:
                    f_hits = br['false_hits']
                    t_hits = br['true_hits']
                    full = (f_hits > 0 and t_hits > 0)
                    if full:
                        css_class = 'hit-branch-full'
                    else:
                        css_class = 'hit-branch-partial'
                    bits.append(f"col {br['column']}: T={t_hits} F={f_hits}")
                branch_text = ' · '.join(bits)
        rows.append(f"""
        <tr class="{css_class}">
          <td class="lineno">{idx}</td>
          <td class="count">{count_text}</td>
          <td class="src"><pre>{escape(line.rstrip())}</pre></td>
          <td class="branch">{escape(branch_text)}</td>
        </tr>""")

    pct = file_meta['coverage']
    color = coverage_color(pct)
    html = f"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>{escape(file_meta['rel_path'])} – Coverage</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; color: #222; }}
  h2 {{ border-bottom: 1px solid #ddd; padding-bottom: 8px; }}
  .meta {{ color: #666; font-size: 13px; margin-bottom: 14px; }}
  .pct {{ display: inline-block; padding: 4px 10px; border-radius: 4px; color: #fff; background: {color}; font-weight: 600; }}
  table {{ width: 100%; border-collapse: collapse; font-family: 'SF Mono', Menlo, monospace; font-size: 13px; }}
  td {{ padding: 1px 8px; vertical-align: top; }}
  pre {{ margin: 0; white-space: pre; }}
  .lineno {{ color: #aaa; text-align: right; user-select: none; width: 50px; }}
  .count  {{ color: #888; text-align: right; width: 60px; }}
  .branch {{ color: #888; font-size: 11px; }}
  tr.hit            {{ background: #e6ffed; }}
  tr.miss           {{ background: #ffeef0; }}
  tr.hit-branch-full    {{ background: #d4f0d8; }}
  tr.hit-branch-partial {{ background: #fff4cf; }}
  tr.hit-branch-partial .branch {{ color: #b08000; }}
  a {{ color: #0366d6; text-decoration: none; }}
</style>
</head>
<body>
<p><a href="index.html">← Übersicht</a></p>
<h2>{escape(file_meta['rel_path'])} <span class="pct">{pct:.1f}%</span></h2>
<p class="meta">{file_meta['executable']} ausführbare Zeilen · Tipp: Branch-Spalte zeigt T/F-Trefferzahlen pro Verzweigung (relevant für C1/C3).</p>
<table>{''.join(rows)}
</table>
</body>
</html>"""
    out_path = os.path.join(out_dir, file_meta['html'])
    with open(out_path, 'w') as f:
        f.write(html)


def render_cobertura(app_target, files_meta, source_root, xcresult_path, out_path):
    """Erzeugt minimales Cobertura-XML (für CI-Reports)."""
    lines_valid = app_target['executableLines']
    lines_covered = app_target['coveredLines']
    line_rate = lines_covered / lines_valid if lines_valid else 0
    packages_xml = []
    classes_by_pkg = {}
    for f in files_meta:
        abs_src = os.path.join(source_root, f['rel_path'])
        if not os.path.exists(abs_src):
            continue
        pkg = os.path.dirname(f['rel_path']).replace('/', '.') or 'root'
        cov = parse_xccov_per_line(xcresult_path, abs_src)
        line_entries = []
        for c in cov:
            if c['count'] is None: continue
            hits = c['count']
            line_entries.append(f'        <line number="{c["line"]}" hits="{hits}"/>')
        cls = (f"      <class name=\"{xml_escape(os.path.basename(f['rel_path']))}\" "
               f"filename=\"{xml_escape(f['rel_path'])}\" "
               f"line-rate=\"{f['coverage']/100:.4f}\" branch-rate=\"0\">\n"
               f"        <methods/>\n"
               f"        <lines>\n" + '\n'.join(line_entries) + "\n        </lines>\n"
               f"      </class>")
        classes_by_pkg.setdefault(pkg, []).append(cls)

    for pkg, classes in classes_by_pkg.items():
        packages_xml.append(
            f'  <package name="{xml_escape(pkg)}" line-rate="0" branch-rate="0">\n'
            f'    <classes>\n' + '\n'.join(classes) + '\n    </classes>\n'
            f'  </package>'
        )

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<coverage line-rate="{line_rate:.4f}" branch-rate="0" lines-covered="{lines_covered}" lines-valid="{lines_valid}" version="1.0">
  <sources><source>{xml_escape(source_root)}</source></sources>
  <packages>
{chr(10).join(packages_xml)}
  </packages>
</coverage>
"""
    with open(out_path, 'w') as f:
        f.write(xml)


def render_sonarqube(files_meta, source_root, xcresult_path, out_path):
    """Erzeugt SonarQube Generic Test Coverage XML."""
    file_blocks = []
    for f in files_meta:
        abs_src = os.path.join(source_root, f['rel_path'])
        if not os.path.exists(abs_src):
            continue
        cov = parse_xccov_per_line(xcresult_path, abs_src)
        lines_xml = []
        for c in cov:
            if c['count'] is None: continue
            covered = 'true' if c['count'] > 0 else 'false'
            lines_xml.append(f'    <lineToCover lineNumber="{c["line"]}" covered="{covered}"/>')
        if lines_xml:
            file_blocks.append(
                f'  <file path="{xml_escape(f["rel_path"])}">\n' +
                '\n'.join(lines_xml) +
                '\n  </file>'
            )

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<coverage version="1">
{chr(10).join(file_blocks)}
</coverage>
"""
    with open(out_path, 'w') as f:
        f.write(xml)


def main():
    if len(sys.argv) < 3:
        print("Usage: render_coverage.py <xcresult> <out_dir>")
        sys.exit(1)
    xcresult = sys.argv[1]
    out_dir = sys.argv[2]
    source_root = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
    project_name = "Toernberechnung"

    os.makedirs(out_dir, exist_ok=True)

    raw = run(['xcrun', 'xccov', 'view', '--report', '--json', xcresult])
    summary = json.loads(raw)

    # App-Target wählen (nicht das Test-Target)
    app_target = next(
        (t for t in summary['targets'] if t['buildProductPath'].endswith(f'{project_name}.app/{project_name}')),
        summary['targets'][0]
    )

    files_meta = []
    for f in app_target['files']:
        rel = os.path.relpath(f['path'], source_root)
        # Nur Quelldateien aus dem Projekt selbst rendern (keine Frameworks)
        if rel.startswith('..'):
            continue
        files_meta.append({
            'rel_path': rel,
            'executable': f['executableLines'],
            'coverage': f['lineCoverage'] * 100,
            'html': rel.replace('/', '__') + '.html',
        })

    print(f"Rendering {len(files_meta)} files ...")
    for f in files_meta:
        render_file_detail(f, source_root, xcresult, out_dir)

    render_index(summary, app_target, files_meta, out_dir, project_name)

    print("Cobertura XML ...")
    render_cobertura(app_target, files_meta, source_root, xcresult,
                     os.path.join(out_dir, 'cobertura.xml'))

    print("SonarQube Generic Coverage XML ...")
    render_sonarqube(files_meta, source_root, xcresult,
                     os.path.join(out_dir, 'sonarqube-generic-coverage.xml'))

    print(f"\nBerichte unter: {out_dir}/")
    print(f"  → open {out_dir}/index.html")


if __name__ == '__main__':
    main()
