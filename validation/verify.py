from pathlib import Path
import datetime
import json
import re
import subprocess

workspace = Path(__file__).resolve().parent.parent
repo = workspace / "CWLog_Utils_Claude"
tool = str(workspace / "validation/shellcheck.exe")
results = []
tick = chr(96)
fence = tick * 3


def run(args, cwd=repo, input=None):
    return subprocess.run(args, cwd=cwd, input=input, text=True, encoding="utf-8",
                          capture_output=True)


def check(label, condition, detail=""):
    results.append({"check": label, "passed": bool(condition), "detail": detail})
    if not condition:
        raise AssertionError(label + ": " + detail)
    print("PASS:", label)


before = run([tool, "--external-sources", "--format=json", "cwlog"],
             workspace / "validation/baseline")
after = run([tool, "--external-sources", "--format=json", "cwlog"])
check("ShellCheck main diagnostics identical to baseline",
      json.loads(before.stdout) == json.loads(after.stdout), after.stdout)
syntax = run([tool, "--external-sources", "--severity=error",
              "cwlog", "lib/logs.sh", "tests/message_time_test.sh"])
check("ShellCheck error-level analysis", syntax.returncode == 0,
      syntax.stdout + syntax.stderr)
for label, args, cwd in [
    ("git diff --check", ["git", "diff", "--check"], repo),
    ("patch applies to original files",
     ["git", "apply", "--check", str(workspace / "message-time-fix.patch")],
     workspace / "validation/baseline"),
    ("patch reverses against modified files",
     ["git", "apply", "--reverse", "--check", str(workspace / "message-time-fix.patch")], repo),
]:
    result = run(args, cwd)
    check(label, result.returncode == 0, result.stdout + result.stderr)

logs = (repo / "lib/logs.sh").read_text(encoding="utf-8")
program = re.search(r"""--arg explicit "[^"]*" '([\s\S]*?)'\s+"\$out" """.strip(), logs).group(1)
streams = {"logStreams": [
    {"logStreamName": "outside", "firstEventTimestamp": 4000, "lastEventTimestamp": 5000},
    {"logStreamName": "inside", "firstEventTimestamp": 1000, "lastEventTimestamp": 1500},
]}
for explicit, expected in [("2026-10-26", "outside"), ("", "inside")]:
    result = run(["jq", "-r", "--argjson", "s", "1000", "--argjson", "e", "2000",
                  "--arg", "explicit", explicit, program], input=json.dumps(streams))
    check("actual jq stream selector: " + ("message" if explicit else "legacy"),
          result.returncode == 0 and result.stdout.strip() == expected, result.stderr)

test = (repo / "tests/message_time_test.sh").read_text(encoding="utf-8")
fixture_program = re.search(r"'(\{events: \[[\s\S]*?\]\})' > \"\$fixture\"", test).group(1)
start = int(datetime.datetime(2026, 10, 26, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)
end = start + 3600000
result = run(["jq", "-n", "--argjson", "s", str(start), "--argjson", "e", str(end), fixture_program])
check("regression fixture compiles and contains 10 events",
      result.returncode == 0 and len(json.loads(result.stdout)["events"]) == 10, result.stderr)
check("15 regression cases are present", len(re.findall(r"^pass '", test, re.M)) == 15)

manual = (repo / "MANUAL_FIX.md").read_text(encoding="utf-8")
for snippet in re.findall(fence + r"json\n(.*?)\n" + fence, manual, re.S):
    json.loads(snippet)
check("manual JSON examples parse", True)
reconstructed = {
    name: subprocess.check_output(["git", "show", "HEAD:" + name], cwd=repo).decode("utf-8")
    for name in ["cwlog", "lib/config.sh", "lib/logs.sh"]
}
step_pattern = (r"\*\*5-\d+\. " + tick + "([^" + tick + "]+)" + tick
                + r"\*\*.*?変更前：[^\n]+\n\n" + fence + r"bash\n(.*?)\n" + fence
                + r".*?変更後：[^\n]+\n\n" + fence + r"bash\n(.*?)\n" + fence)
steps = re.findall(step_pattern, manual, re.S)
for file, old, new in steps:
    old, new = old + "\n", new + "\n"
    check("manual anchor unique: " + file, reconstructed[file].count(old) == 1)
    reconstructed[file] = reconstructed[file].replace(old, new, 1)
check("all 8 manual steps reproduce the exact implementation",
      len(steps) == 8 and all(text.encode("utf-8") == (repo / f).read_bytes()
                             for f, text in reconstructed.items()))
for file in ["cwlog", "lib/config.sh", "lib/logs.sh", "cwlog.sample.conf",
             "README.md", "MANUAL_FIX.md", "tests/message_time_test.sh"]:
    data = (repo / file).read_bytes()
    data.decode("utf-8")
    check("UTF-8 without BOM; LF only: " + file,
          not data.startswith(b"\xef\xbb\xbf") and b"\r" not in data
          and b"\xef\xbf\xbd" not in data)
    check("no trailing whitespace: " + file,
          all(line.rstrip(b" \t") == line for line in data.splitlines()))

(workspace / "validation/results.json").write_text(
    json.dumps({"checks": results, "not_run": [
        "Bash execution: signal pipe Win32 error 5",
        "WSL execution: E_ACCESSDENIED",
        "15 Bash regression cases, AWS live calls, Excel application rendering"
    ]}, ensure_ascii=False, indent=2), encoding="utf-8")
print("No Bash regression test or AWS live test was executed.")
