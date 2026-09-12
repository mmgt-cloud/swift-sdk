#!/usr/bin/env python3
"""Keep DocC examples byte-identical to Swift sources compiled by both test hosts."""
import argparse
import pathlib
import re
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--write", action="store_true", help="Explicitly regenerate DocC excerpts after reviewing source examples")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "Tests/MMGTTests/CompiledQuickstarts.swift").read_text()
snippets = re.findall(r"// snippet: (MMGT\w+)\n(.*?)// end-snippet", source, re.S)
assert len(snippets) == 8 and len({x[0] for x in snippets}) == 8
imports = {
    "MMGTCore": ["Foundation", "MMGTCore"],
    "MMGTAuth": ["MMGTCore", "MMGTAuth", "MMGTAI"],
    "MMGTBilling": ["MMGTCore", "MMGTAuth", "MMGTBilling"],
    "MMGTRealtime": ["MMGTRealtime"],
    "MMGTSync": ["Foundation", "MMGTSync"],
    "MMGTSyncSQLite": ["Foundation", "MMGTCore", "MMGTAuth", "MMGTSync", "MMGTSyncSQLite"],
    "MMGTAI": ["MMGTAI"],
    "MMGTSwiftUI": ["SwiftUI", "MMGTAuth", "MMGTSwiftUI"],
}
failures = []
for module, body in snippets:
    path = root / "Sources" / module / (module + ".docc") / (module + ".md")
    content = path.read_text()
    block = "<!-- compiled-quickstart -->\n## Compiled quickstart\n\n```swift\n" + "\n".join("import " + x for x in imports[module]) + "\n\n" + body.rstrip() + "\n```\n<!-- end-compiled-quickstart -->\n"
    old = re.search(r"<!-- compiled-quickstart -->.*?<!-- end-compiled-quickstart -->\n", content, re.S)
    if old and old.group() == block:
        continue
    if not args.write:
        failures.append(module)
    else:
        if old:
            content = content[:old.start()] + block + content[old.end():]
        elif "## Topics" in content:
            content = content.replace("## Topics", block + "\n## Topics", 1)
        else:
            content = content.rstrip() + "\n\n" + block
        path.write_text(content)
if failures:
    print("Stale or missing DocC excerpts: " + ", ".join(failures), file=sys.stderr)
    sys.exit(1)
print("PASS: eight DocC quickstarts match compiled Swift source")
