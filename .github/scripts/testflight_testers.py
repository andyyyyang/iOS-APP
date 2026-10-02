"""把最新 build 發給內部測試人員（App Store Connect API）。

1. 依 Bundle ID 找到 App，等待最新 build 處理完成
2. 建立（或沿用）可存取所有 build 的內部測試群組
3. 把帳號持有人與管理員加入群組並寄出 TestFlight 邀請

公開 repo 的 Actions 紀錄所有人都看得到，因此不輸出任何 email。
"""

import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.andyyyyang.LocalOCR")
GROUP_NAME = "內部測試"
SUMMARY = os.environ.get("GITHUB_STEP_SUMMARY")


def summary(line: str) -> None:
    print(line)
    if SUMMARY:
        with open(SUMMARY, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, **kwargs) -> dict:
    response = requests.request(
        method,
        f"{API}{path}",
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
        timeout=60,
        **kwargs,
    )
    if response.status_code >= 400:
        detail = "; ".join(
            f"{error.get('code')}: {error.get('detail')}" for error in response.json().get("errors", [])
        ) if response.content else ""
        raise RuntimeError(f"{method} {path.split('?')[0]} → {response.status_code} {detail}")
    return response.json() if response.content else {}


def find_app() -> str:
    apps = call("GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"::error::App Store Connect 找不到 Bundle ID {BUNDLE_ID} 的 App，請先建立 App（docs/TESTFLIGHT.md 第 2 步）")
    return apps[0]["id"]


def wait_for_build(app_id: str) -> None:
    """等待最新 build 處理完成；有 EXPECTED_BUILD 時等待這次上傳的 build 出現並處理完成。"""
    expected = os.environ.get("EXPECTED_BUILD", "").strip()
    deadline = time.time() + 40 * 60
    while True:
        query = f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=1&fields[builds]=version,processingState,uploadedDate"
        if expected:
            query += f"&filter[version]={expected}"
        builds = call("GET", query)["data"]
        if not builds:
            if not expected:
                sys.exit("::error::還沒有上傳任何 build")
            if time.time() > deadline:
                summary(f"- build {expected} 仍未出現在 App Store Connect，處理完成後群組成員會自動收到")
                return
            print(f"等待 build {expected} 出現在 App Store Connect…")
            time.sleep(60)
            continue
        attributes = builds[0]["attributes"]
        state = attributes["processingState"]
        print(f"最新 build {attributes['version']}：{state}")
        if state == "VALID":
            summary(f"- 最新 build **{attributes['version']}** 已處理完成，可以測試")
            return
        if state in ("FAILED", "INVALID"):
            sys.exit(f"::error::build {attributes['version']} 處理失敗（{state}），請查看 App Store Connect 的郵件說明")
        if time.time() > deadline:
            summary(f"- build {attributes['version']} 仍在處理中（{state}），處理完成後群組成員會自動收到")
            return
        time.sleep(60)


def internal_group(app_id: str) -> str:
    groups = call("GET", f"/betaGroups?filter[app]={app_id}&filter[isInternalGroup]=true")["data"]
    if groups:
        group = groups[0]
        if not group["attributes"].get("hasAccessToAllBuilds"):
            call("PATCH", f"/betaGroups/{group['id']}", json={
                "data": {"type": "betaGroups", "id": group["id"], "attributes": {"hasAccessToAllBuilds": True}}
            })
        summary(f"- 使用內部測試群組「{group['attributes']['name']}」")
        return group["id"]
    group = call("POST", "/betaGroups", json={
        "data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    })["data"]
    summary(f"- 已建立內部測試群組「{GROUP_NAME}」（自動取得之後所有 build）")
    return group["id"]


def group_tester_count(group_id: str) -> int:
    return len(call("GET", f"/betaGroups/{group_id}/betaTesters?limit=200")["data"])


def assign(app_id: str, group_id: str, email: str, first: str, last: str) -> str:
    """把測試人員加入群組，回傳 betaTester id。先建立（已存在時 Apple 會沿用），失敗再改用關聯。"""
    try:
        return call("POST", "/betaTesters", json={
            "data": {
                "type": "betaTesters",
                "attributes": {"email": email, "firstName": first, "lastName": last},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}},
            }
        })["data"]["id"]
    except RuntimeError as create_error:
        print(f"建立測試人員失敗，改用既有紀錄：{create_error}")
        query = requests.utils.quote(email)
        existing = call("GET", f"/betaTesters?filter[email]={query}&filter[apps]={app_id}&limit=1")["data"] \
            or call("GET", f"/betaTesters?filter[email]={query}&limit=1")["data"]
        if not existing:
            raise
        tester_id = existing[0]["id"]
        call("POST", f"/betaGroups/{group_id}/relationships/betaTesters", json={
            "data": [{"type": "betaTesters", "id": tester_id}]
        })
        return tester_id


def add_testers(app_id: str, group_id: str) -> None:
    try:
        users = call("GET", "/users?limit=50&fields[users]=username,firstName,lastName,roles")["data"]
    except RuntimeError as error:
        sys.exit(f"::error::無法讀取 App Store Connect 使用者（API 金鑰需要「管理」權限）：{error}")
    targets = [
        user for user in users
        if {"ACCOUNT_HOLDER", "ADMIN"} & set(user["attributes"].get("roles") or [])
    ]
    members_before = {
        (tester["attributes"].get("email") or "").lower()
        for tester in call("GET", f"/betaGroups/{group_id}/betaTesters?limit=200&fields[betaTesters]=email")["data"]
    }
    assigned = invited = already = 0
    failures: list[str] = []
    for user in targets:
        attributes = user["attributes"]
        email = attributes["username"]
        print(f"::add-mask::{email}")
        if email.lower() in members_before:
            # 已在群組中：可存取所有 build 的內部群組會自動收到新版本，不需再邀請
            already += 1
            continue
        try:
            tester_id = assign(app_id, group_id, email, attributes.get("firstName") or "", attributes.get("lastName") or "")
            assigned += 1
        except RuntimeError as error:
            failures.append(str(error))
            continue
        try:
            call("POST", "/betaTesterInvitations", json={
                "data": {
                    "type": "betaTesterInvitations",
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                        "betaTester": {"data": {"type": "betaTesters", "id": tester_id}},
                    },
                }
            })
            invited += 1
        except RuntimeError as error:
            # 已經接受過邀請，或加入群組時 Apple 已自動寄出
            print(f"未另外寄送邀請：{error}")

    members = group_tester_count(group_id)
    summary(f"- 帳號持有人／管理員 {len(targets)} 位：已在群組 {already} 位、新加入 {assigned} 位、寄出 {invited} 封邀請")
    summary(f"- 「內部測試」群組目前有 **{members}** 位測試人員")
    for failure in failures:
        summary(f"  - 加入失敗：{failure}")
    if members == 0:
        sys.exit("::error::內部測試群組沒有任何測試人員，請依步驟摘要中的錯誤處理，或在 App Store Connect 的 TestFlight 頁面手動加入自己")


def main() -> None:
    app_id = find_app()
    wait_for_build(app_id)
    group_id = internal_group(app_id)
    add_testers(app_id, group_id)
    summary("")
    summary("已在群組的測試人員會在 TestFlight App 收到新版本通知；新加入的人請打開 TestFlight 邀請信，或在 TestFlight App 輸入信中的兌換碼。")


if __name__ == "__main__":
    main()
