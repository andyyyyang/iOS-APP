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
    deadline = time.time() + 40 * 60
    while True:
        builds = call(
            "GET",
            f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=1&fields[builds]=version,processingState,uploadedDate",
        )["data"]
        if not builds:
            sys.exit("::error::還沒有上傳任何 build")
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


def add_testers(app_id: str, group_id: str) -> None:
    users = call("GET", "/users?limit=50&fields[users]=username,firstName,lastName,roles")["data"]
    targets = [
        user for user in users
        if {"ACCOUNT_HOLDER", "ADMIN"} & set(user["attributes"].get("roles") or [])
    ]
    added = invited = 0
    for user in targets:
        attributes = user["attributes"]
        email = attributes["username"]
        print(f"::add-mask::{email}")
        existing = call("GET", f"/betaTesters?filter[email]={requests.utils.quote(email)}&limit=1")["data"]
        if existing:
            tester_id = existing[0]["id"]
            try:
                call("POST", f"/betaGroups/{group_id}/relationships/betaTesters", json={
                    "data": [{"type": "betaTesters", "id": tester_id}]
                })
            except RuntimeError as error:
                print(f"已在群組中或無法加入：{error}")
        else:
            tester_id = call("POST", "/betaTesters", json={
                "data": {
                    "type": "betaTesters",
                    "attributes": {
                        "email": email,
                        "firstName": attributes.get("firstName") or "",
                        "lastName": attributes.get("lastName") or "",
                    },
                    "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}},
                }
            })["data"]["id"]
        added += 1
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
            # 已經接受過邀請的測試人員不需要再寄
            print(f"未重新寄送邀請：{error}")
    summary(f"- 已加入 {added} 位測試人員（帳號持有人與管理員），寄出 {invited} 封 TestFlight 邀請")


def main() -> None:
    app_id = find_app()
    wait_for_build(app_id)
    group_id = internal_group(app_id)
    add_testers(app_id, group_id)
    summary("")
    summary("請到 Apple ID 的信箱打開 TestFlight 邀請信，在 iPhone 上點「在 TestFlight 中檢視」，或在 TestFlight App 輸入信中的兌換碼。")


if __name__ == "__main__":
    main()
