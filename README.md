# Insta360 Sync

Mac メニューバー常駐アプリと PWA による、Insta360 Wi-Fi バックアップツール。

登録済み Insta360 の SSID を検知すると Web Push でスマホに通知し、PWA からバックアップ開始を承認すると Mac がカメラ AP に接続してファイルをコピーします。

## 機能

- 複数 Insta360 カメラの SSID 登録（表示名・Wi-Fi パスワード）
- SSID スキャン検知 → Web Push 通知 → PWA で承認
- TCP/6666（[insta360-wifi-api](https://github.com/RigacciOrg/insta360-wifi-api) 互換）+ OSC HTTP フォールバック
- バックアップ先フォルダ構造:
  - **オリジナル構造**: `{保存先}/{カメラ名}/DCIM/...`
  - **日付別**: `{保存先}/{YYYY-MM-DD}/{ファイル名}`（SD 上の階層は無視）
- 既存ファイルはスキップ（同名・同サイズ）

## 必要条件

- macOS 15+
- Xcode / Swift 6 ツールチェーン
- Node.js 20+（PWA ビルド）
- OpenSSL（初回 TLS 証明書生成）
- 位置情報サービス（SSID 取得に必須）

## ビルド

```bash
make mac-app
```

位置情報（SSID 取得）の許可をビルド後も維持するには、Apple Development 証明書で署名します:

```bash
make mac-app-signed
# または
make run-signed
```

PWA のみ:

```bash
make pwa
```

## 実行

```bash
make run
```

または:

```bash
open apps/mac-app/.build/Insta360Sync.app
```

## 初回セットアップ

1. Mac アプリを起動し、メニューバーから **開始** を押す
2. **設定** でカメラ（SSID・パスワード）と保存先を登録
3. システム設定 → プライバシーとセキュリティ → **位置情報** で Insta360 Sync を許可
4. iPhone の Safari で `https://<Macのホスト名>.local:9443/` を開く
   - 自己署名証明書の警告 → **詳細** → 続行
5. Mac 設定画面の **API トークン** を PWA に入力して保存
6. PWA で **Push 通知を有効化**
7. Safari の共有メニューから **ホーム画面に追加**（iOS 16.4+ で Web Push に必須）

## プロジェクト構成

```
insta360-sync/
├── apps/
│   ├── mac-app/          # Swift メニューバーアプリ
│   │   └── scripts/resign-mac-app.sh
│   └── pwa/              # 承認 UI（Vite + TypeScript）
├── vendor/insta360-proto/ # Protobuf 定義（参考）
├── scripts/
│   ├── build-pwa.sh
│   ├── build-mac-app.sh
│   └── generate-protos.sh
└── Makefile
```

## API（Mac HTTPS サーバー）

| エンドポイント | 認証 | 説明 |
|---|---|---|
| `GET /api/public/vapid` | 不要 | VAPID 公開鍵 |
| `GET /api/public/certificate` | 不要 | ルート証明書情報（CN/SAN/フィンガープリント/有効期限/PEM） |
| `GET /api/public/certificate.pem` | 不要 | PEM 形式の証明書 (`.crt` としてダウンロード) |
| `GET /api/public/certificate.crt` | 不要 | Android 向けの `.crt`（`.pem` と同じ内容） |
| `GET /api/public/certificate.der` | 不要 | DER 形式（バイナリ） |
| `GET /api/public/certificate.mobileconfig` | 不要 | iOS/iPadOS/macOS 向け構成プロファイル |
| `GET /api/settings` | Bearer | 公開設定 + VAPID 公開鍵 |
| `POST /api/push/subscribe` | Bearer | Push Subscription 登録 |
| `GET /api/backup/pending` | Bearer | 承認待ち一覧 |
| `POST /api/backup/approve` | Bearer | バックアップ開始 |
| `POST /api/backup/skip` | Bearer | スキップ |
| `GET /api/backup/status` | Bearer | 進捗・履歴 |

認証: `Authorization: Bearer {apiToken}`

### ルート証明書のインストール

PWA トップの「ルート証明書」セクションから、iOS/iPadOS 用の `.mobileconfig`
または Android 用の `.crt` をダウンロードできます。フィンガープリント (SHA-256)
を照合し、以下の手順でインストールしてください。

- **iOS/iPadOS**: Safari で `.mobileconfig` を開く → 設定 → 一般 → VPN と
  デバイス管理 → プロファイルをインストール → 設定 → 一般 → 情報 → 証明書
  信頼設定 でフル信頼を有効化。
- **Android**: Chrome で `.crt` をダウンロード → 設定 → セキュリティと
  プライバシー → 暗号化と認証情報 → 証明書のインストール → CA 証明書 として
  インポート。

## カメラ側

- AP IP: `192.168.42.1`
- デフォルト Wi-Fi パスワード: `88888888`（機種・設定で上書き可能）

## ライセンス

MIT（アプリ本体）。Protobuf 定義は [RigacciOrg/insta360-wifi-api](https://github.com/RigacciOrg/insta360-wifi-api) を参考にしています。
