"""撤銷先前 CI 建立的開發憑證（App Store Connect API）。

每次在全新的 runner 上以 API 金鑰自動簽署（-allowProvisioningUpdates），Xcode 都會建立一張新的
「Apple Development: Created via API」憑證；私鑰隨 runner 一起消失，憑證留在帳號裡用不到，
累積到上限後封存會失敗（Your account has reached the maximum number of certificates）。
這裡只撤銷名稱含「Created via API」的開發憑證，自己 Mac 上 Xcode 建立的憑證與發佈憑證都不會動。

公開 repo 的 Actions 紀錄所有人都看得到，因此只輸出數量，不輸出名稱。
"""

import os
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
MARKER = "Created via API"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def main() -> None:
    headers = {"Authorization": f"Bearer {token()}"}
    response = requests.get(
        f"{API}/certificates",
        params={"filter[certificateType]": "DEVELOPMENT,IOS_DEVELOPMENT", "limit": 200},
        headers=headers,
        timeout=60,
    )
    response.raise_for_status()
    certificates = response.json().get("data", [])
    created_by_ci = [
        certificate
        for certificate in certificates
        if MARKER in (certificate["attributes"].get("name") or "")
        or MARKER in (certificate["attributes"].get("displayName") or "")
    ]
    print(f"開發憑證 {len(certificates)} 張，其中 CI 建立的 {len(created_by_ci)} 張")

    revoked = 0
    for certificate in created_by_ci:
        result = requests.delete(f"{API}/certificates/{certificate['id']}", headers=headers, timeout=60)
        if result.status_code in (200, 204):
            revoked += 1
        else:
            print(f"::warning::有一張 CI 憑證無法撤銷（HTTP {result.status_code}）")
    print(f"已撤銷 {revoked} 張")
    if not created_by_ci and certificates:
        print("::notice::沒有 CI 建立的開發憑證；若封存仍因憑證數量上限失敗，請到 Apple Developer → Certificates 撤銷不用的開發憑證")


if __name__ == "__main__":
    main()
