#!/usr/bin/env python3
"""Check authored UI copy and interpolation coverage without touching user data.

Swift comments and nested interpolation strings are parsed so translated keys,
stable route raw values and the bilingual language picker are distinguished.
Run from the repository root: python3 script/audit_localization.py.
"""
import re,json
from pathlib import Path
han=re.compile('[\u3400-\u9fff]')
def scan(s):
    i=0
    while i<len(s):
        if s.startswith('//',i):
            j=s.find('\n',i);i=len(s) if j<0 else j+1
        elif s.startswith('/*',i):
            j=s.find('*/',i+2);i=len(s) if j<0 else j+2
        elif s[i]=='"':
            a=i;i+=1;parts=[''];args=[]
            if s.startswith('""',i):
                j=s.find('"""',i+2);i=j+3;continue
            while i<len(s):
                if s.startswith('\\(',i):
                    b=i+2;j=b;depth=1
                    while depth:
                        if s[j]=='"':
                            # nested Swift literal; consume its interpolation recursively
                            sub=next(scan(s[j:]));j+=sub[1];continue
                        if s[j]=='(':depth+=1
                        if s[j]==')':depth-=1
                        j+=1
                    args.append(s[b:j-1]);parts.append('');i=j
                elif s[i]=='\\':parts[-1]+=s[i:i+2];i+=2
                elif s[i]=='"':i+=1;break
                else:parts[-1]+=s[i];i+=1
            key=''.join(p+('{'+str(k)+'}' if k<len(args) else '') for k,p in enumerate(parts))
            yield a,i,key,args
        else:i+=1

def audit():
    root = Path(__file__).resolve().parents[1]
    catalog = json.loads((root / "Sources/SlateSyncUI/Resources/English.json").read_text())
    errors = []
    count = 0
    def inspect(source, path):
        nonlocal count
        for a, b, key, args in scan(source):
            for arg in args:
                inspect(arg, path)
            if not han.search(key):
                continue
            prefix = source[max(0, a-100):a]
            if re.search(r"L10n\.tr\(\s*$", prefix):
                count += 1
                if key not in catalog:
                    errors.append(f"{path}: missing English key: {key}")
            elif re.search(r"case\s+\w+\s*=\s*$", prefix):
                # WorkspaceSection raw values are persisted navigation identity.
                continue
            elif path.name == "SettingsRootView.swift" and key in {"语言 / Language", "简体中文"}:
                continue
            elif path.name == "HelpModel.swift" and key in catalog:
                # Resource-load errors are localized by the status presentation.
                continue
            else:
                errors.append(f"{path}: unlocalized UI literal: {key}")
    for directory in ["Sources/SlateSyncUI", "SlateSyncApp/App"]:
        for path in (root / directory).rglob("*.swift"):
            if "Localization" not in path.parts:
                inspect(path.read_text(), path.relative_to(root))
    for key, value in catalog.items():
        if sorted(re.findall(r"\{\d+\}", key)) != sorted(re.findall(r"\{\d+\}", value)):
            errors.append(f"Placeholder mismatch: {key}")
    print(json.dumps({"translatedCallSites": count, "catalogEntries": len(catalog), "errors": errors}, ensure_ascii=False, indent=2))
    return bool(errors)

if __name__ == "__main__":
    raise SystemExit(audit())
