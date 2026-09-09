#!/usr/bin/env python3
"""Generate the example project locally without overwriting application configuration."""
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
example = root / "Examples/MMGTExample"
configuration = example / "Configuration.json"
if not configuration.exists():
    shutil.copyfile(example / "Configuration.sample.json", configuration)
    print("Created ignored Configuration.json with synthetic placeholders; configure before live sign-in.")
subprocess.run(["xcodegen", "generate", "--spec", str(example / "project.yml")], check=True, cwd=root)
