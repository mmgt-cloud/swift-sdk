"""Require complete, warning-free DocC diagnostics for the eight SDK products."""
MODULES = frozenset(('MMGTCore', 'MMGTAuth', 'MMGTBilling', 'MMGTRealtime', 'MMGTSync', 'MMGTSyncSQLite', 'MMGTAI', 'MMGTSwiftUI'))


def inspect_diagnostics(directory):
    import json
    owned, dependencies = {}, []
    for file in sorted(directory.glob('*/Debug-iphonesimulator/*/*-diagnostics.json')):
        module = file.name.removesuffix('-diagnostics.json')
        value = json.loads(file.read_text())
        diagnostics = value.get('diagnostics')
        if not isinstance(diagnostics, list):
            raise ValueError('Malformed DocC diagnostics: ' + module)
        issues = [item for item in diagnostics if item.get('severity') in ('warning', 'error')]
        if module.startswith('MMGT'):
            if module in owned:
                raise ValueError('Ambiguous duplicate module diagnostics: ' + module)
            owned[module] = issues
        elif issues:
            dependencies.append(dict(module=module, diagnostics=issues))
    return owned, dependencies, set(owned) == MODULES and not any(owned.values())
