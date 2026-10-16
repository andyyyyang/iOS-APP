"""列出 TestFlight 回報的當機（App Store Connect API 的 betaFeedbackCrashSubmissions），印出當機的原因與當機執行緒的堆疊。

公開 repo 的 Actions 紀錄所有人都看得到：不輸出測試者的 email、留言與裝置識別碼，只輸出版本、機型、系統版本與堆疊。
App 本身的框架沒有符號時，把位移寫進 offsets.txt，由工作流程用同一個 commit 重新建置的 dSYM 解析。
"""

import json
import os
import re
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.andyyyyang.LocalOCR"
BINARY = "LocalOCR"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def get(path: str, params: dict | None = None) -> dict:
    response = requests.get(f"{API}{path}", params=params, headers={"Authorization": f"Bearer {token()}"}, timeout=60)
    if response.status_code >= 400:
        print(f"::warning::{path} → HTTP {response.status_code}")
        return {}
    return response.json()


def excerpt_text(log: str) -> list[str]:
    """文字格式的當機紀錄：標頭中的版本與原因、當機的執行緒、最後的例外堆疊。"""
    keep = ("Version:", "OS Version:", "Exception Type:", "Exception Codes:", "Exception Subtype:", "Termination Reason:",
            "Termination Description:", "Triggered by Thread:", "Crashed Thread:", "Exception Reason:")
    lines = log.splitlines()
    out = [line for line in lines if line.startswith(keep)]
    capture = False
    for line in lines:
        if re.match(r"^(Thread \d+ Crashed|Last Exception Backtrace|Application Specific Information)", line):
            capture = True
            out.append("")
        elif capture and not line.strip():
            capture = False
        if capture:
            out.append(line)
    return out


def excerpt_ips(log: str) -> tuple[list[str], list[str]]:
    """.ips（JSON）格式：exception、termination、faultingThread 的 frames。"""
    first, _, rest = log.partition("\n")
    header = json.loads(first)
    body = json.loads(rest)
    images = body.get("usedImages", [])
    out = [f"Version: {header.get('app_version')} ({header.get('build_version')})  OS: {header.get('os_version')}"]
    for key in ("exception", "termination", "asi", "ktriageinfo"):
        if key in body:
            out.append(f"{key}: {json.dumps(body[key], ensure_ascii=False)[:1500]}")
    offsets: list[str] = []

    def frames(title: str, items: list) -> None:
        out.append(title)
        for index, frame in enumerate(items[:60]):
            image = images[frame.get("imageIndex", 0)] if frame.get("imageIndex", -1) < len(images) else {}
            name = image.get("name") or "?"
            symbol = frame.get("symbol")
            location = f"{symbol} + {frame.get('symbolLocation', 0)}" if symbol else f"+ {hex(frame.get('imageOffset', 0))}"
            source = f"  ({frame['sourceFile']}:{frame.get('sourceLine')})" if frame.get("sourceFile") else ""
            out.append(f"{index:3} {name:<28} {location}{source}")
            if name == BINARY and not symbol:
                offsets.append(hex(frame.get("imageOffset", 0)))

    threads = body.get("threads", [])
    faulting = body.get("faultingThread")
    if isinstance(faulting, int) and faulting < len(threads):
        frames(f"Thread {faulting} crashed ({threads[faulting].get('queue', '')}):", threads[faulting].get("frames", []))
    if body.get("lastExceptionBacktrace"):
        frames("Last exception backtrace:", body["lastExceptionBacktrace"])
    for image in images:
        if image.get("name") == BINARY:
            out.append(f"{BINARY} image uuid {image.get('uuid')} base {hex(image.get('base', 0))}")
    return out, offsets


def main() -> None:
    apps = get("/apps", {"filter[bundleId]": BUNDLE_ID}).get("data", [])
    if not apps:
        print("::error::找不到 App")
        sys.exit(1)
    app_id = apps[0]["id"]
    submissions = get(
        f"/apps/{app_id}/betaFeedbackCrashSubmissions",
        {
            "sort": "-createdDate",
            "limit": int(os.environ.get("CRASH_LIMIT", "5")),
            "fields[betaFeedbackCrashSubmissions]": "createdDate,deviceModel,osVersion,appPlatform,buildBundleId,appUptimeInMilliseconds,build",
            "include": "build",
            "fields[builds]": "version",
        },
    )
    builds = {item["id"]: item["attributes"].get("version") for item in submissions.get("included", []) if item.get("type") == "builds"}
    entries = submissions.get("data", [])
    print(f"TestFlight 當機回報 {len(entries)} 筆（最新的在前）")
    all_offsets: list[str] = []
    for number, entry in enumerate(entries, 1):
        attributes = entry.get("attributes", {})
        build_id = (entry.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        uptime = attributes.get("appUptimeInMilliseconds")
        print("")
        print(f"===== #{number} {attributes.get('createdDate')}  build {builds.get(build_id, '?')}  "
              f"{attributes.get('deviceModel')}  {attributes.get('appPlatform')} {attributes.get('osVersion')}  "
              f"開啟 {round(uptime / 1000) if uptime else '?'} 秒後")
        log = get(f"/betaFeedbackCrashSubmissions/{entry['id']}/crashLog").get("data", {}).get("attributes", {}).get("logText") or ""
        if not log:
            print("（沒有當機紀錄）")
            continue
        try:
            lines, offsets = excerpt_ips(log)
        except (ValueError, KeyError, TypeError):
            lines, offsets = excerpt_text(log), []
            for line in lines:
                match = re.match(rf"^\d+\s+{BINARY}\s+0x[0-9a-f]+\s+(0x[0-9a-f]+) \+ (\d+)$", line.strip())
                if match:
                    offsets.append(hex(int(match.group(2))))
        print("\n".join(lines))
        if number == 1:
            all_offsets = offsets
    with open("offsets.txt", "w") as handle:
        handle.write(" ".join(all_offsets))


if __name__ == "__main__":
    main()
