# ansible-desktop

複数顧客 × 複数環境のサーバーを管理する Ansible リポジトリ。 

## インベントリー構成

「顧客 × 環境」ごとにインベントリーディレクトリーを分離する。`-i` で指定した
ディレクトリーの外のホストには届かないため、顧客・環境の取り違え事故を構造で防ぐ。

```
inventories/
├── _template/            # 新規「顧客 × 環境」追加用の雛形
├── local/
│   └── development/      # ローカル検証 VM（ansible.cfg のデフォルト）
└── customer_a/
    ├── production/
    │   ├── hosts.yml     # 役割グループ（web / db）とホスト定義
    │   ├── group_vars/   # all.yml（環境共通）、web.yml など役割別変数
    │   └── host_vars/    # サーバー個別の変数
    └── staging/
```

- プレイブックは `hosts: web` のように**役割グループだけ**を指定する。
  どの顧客のどの環境かは実行時の `-i` で決まる。
- ホスト名は `<顧客略称>-<環境略称>-<役割><連番>`（例: `ca-prd-web01`）。

## 使い方

```bash
# 対象ホストの確認（実行前に必ず）
make list C=customer_a E=production

# ドライラン
make check C=customer_a E=production P=site

# 顧客Aの本番環境「全体」に実行
make run C=customer_a E=production P=site

# 特定サーバーのみ / 役割グループのみ
make run C=customer_a E=production P=site L=ca-prd-web01
make run C=customer_a E=production P=site L=web
```

Makefile を使わない場合:

```bash
ansible-playbook -i inventories/customer_a/production playbooks/site.yml --limit ca-prd-web01
```

## アカウント管理（users.csv）

`playbooks/site.yml`（common ロール、タグ `users`）は
`roles/common/files/users.csv` を読み込み、行ごとにアカウントの作成・削除・
SSH 公開鍵の配置・SFTP 用 bind mount を行う。CSV は UTF-8（BOM 可）、
1 行目がヘッダー。`UserName` が空の行は無視される。

```csv
Delete,ServerName,UserName,LastName,FirstName,Password,Description,AdditionalGroups,sftp,no_login,mount_src
,all,tanakat,Tanaka,Taro,,開発部,,True,True,/home/kusanagi/example.jp/DocumentRoot/wp-content/sites/1:/home/kusanagi/example.jp/DocumentRoot/wp-includes/sites/1
True,ca-prd-web01,suzukih,Suzuki,Hanako,,経理部,,,,
```

| 列 | 説明 |
|---|---|
| `Delete` | 真値（`True` / `1` / `yes` / `y` など）で退役扱い。サーバーに存在する場合のみ `userdel`（`-r` なし。ホームとメールスプールは残る）を実行する。`users_delete_mode: disable` にすると削除せずシェルを nologin にしてロックするだけになる。`root` / `kusanagi` / `ec2-user` / `psuser` / 実行ユーザーは保護対象で、指定するとプレイブックが停止する。 |
| `ServerName` | その行を適用するサーバー。`all`（大文字小文字不問）で全サーバー、インベントリーのホスト名で特定サーバー、`名前:名前` のコロン区切りで複数指定。**空欄はどのサーバーにも適用されない**（作成も削除もされない）。 |
| `UserName` | Linux のアカウント名。SSH 鍵ファイル名・ホーム（`/home/<UserName>`）にもそのまま使われる。 |
| `LastName` / `FirstName` | GECOS（`comment`）用の氏名。大小文字は正規化される（`TANAKA` → `Tanaka`、`o'brien` → `O'Brien`）。 |
| `Password` | **使用しない**。SSH はパスワード認証を行わない方針のため、値があっても無視して警告を出す。アカウントは常にパスワードロック状態で作成される。 |
| `Description` | GECOS に氏名の後ろへ付与する説明（部署など）。`:` は空白に置き換えられる。 |
| `AdditionalGroups` | 追加参加させるグループ（カンマ区切り）。未作成のグループは自動作成する。`Administrators` は `wheel` / `sudo` に読み替えるが、**sudo 権限の付与は Ansible からは行わない**ため警告のみで参加させない。全ユーザーは列の指定に関係なく `www` / `kusanagi` にも参加する（これらはサーバー側に存在している必要がある）。 |
| `sftp` | 真値で SFTP chroot 用に構成する。ホームを `root:root 0755` に変更し、`mount_src` の bind mount を作る。空欄に戻すと既存の bind mount と `/etc/fstab` のエントリを削除する。 |
| `no_login` | `sftp` と両方真のときだけ有効で、シェルを nologin にして SFTP 専用アカウントにする。`no_login` 単独では効果がない（シェルは `/bin/bash` のまま）。 |
| `mount_src` | SFTP で公開する**マウント元**（実体）のパス。コロン区切りで複数指定可（セミコロンも可）。`/home/kusanagi/` 配下のパスのみ有効で、先頭の `/home/kusanagi/` を `/home/<UserName>/` に置き換えた場所がマウント先になる（例: `/home/kusanagi/example.jp/DocumentRoot/a` → `/home/tanakat/example.jp/DocumentRoot/a`）。マウント元が存在しない場合は警告してスキップする（実体は Ansible では作らない）。列から消すと対応する bind mount を解除し、`Delete` 時は `userdel` の前に解除する。 |

SSH 鍵は実行機の `roles/common/files/ssh_keys/<UserName>`（秘密鍵）/ `<UserName>.pub` に
ed25519 で生成され、公開鍵だけが `authorized_keys` へ配置される。既存の鍵は
作り直さない。既定では `authorized_keys` に追記のみで、手動追加された鍵は消さない
（`users_ssh_key_exclusive: true` で CSV の内容に上書き）。
各種既定値は `roles/common/defaults/main.yml` を参照。

## 管理台帳の作成（全顧客 × 全環境 × 全ホスト）

```bash
make list-all              # 全インベントリーの対象ホストを一覧表示（SSH 接続なし）
make report                # 全ホストからファクトを収集して台帳を生成
make report C=customer_b   # 指定顧客の全環境のみを対象に台帳を生成
```

`make report` は `_template` を除く全「顧客 × 環境」を順に実行し、
ホストごとの収集結果を `build/report/*.json` に保存したうえで
**`build/report_all_inventories.csv`**（Excel でそのまま開ける UTF-8 BOM 付き）と
**`build/report_all_inventories.md`** を生成する。
`C=<顧客名>` を指定した場合は `inventories/<顧客名>/` 配下の環境だけを対象にし、
出力名は `build/report_<顧客名>_inventories.csv` / `.md` になる。
収集項目: OS / カーネル / アーキテクチャ / vCPU / メモリ / ディスク / IPv4 /
ハードウェア基盤 / `/etc/os-release` の主要キー（`NAME`, `VERSION_ID`,
`SUPPORT_END` など。`playbooks/inventory_report.yml` の `report_os_release_keys` で変更可）/
所属グループ / 収集日時。列の並びは `templates/inventory_ledger_{csv,md}.j2` で定義する。
到達できないホストも `status: unreachable` として台帳に残る。

1 環境だけ収集し直して台帳を更新することもできる（他環境の収集済みデータは残る）:

```bash
ansible-playbook -i inventories/customer_a/production playbooks/inventory_report.yml
```

> **注意**: 複数インベントリーを `-i` の連続指定で 1 回にまとめて実行してはいけない。
> 各環境の `group_vars/all.yml`（SSH 設定や customer_name / env_name）が
> グローバルの `all` グループ上で衝突し、最後に読まれた環境の値が全ホストに
> 適用されてしまう。`make report` が環境ごとにループ実行しているのはこのため。

## 顧客・環境の追加

```bash
cp -r inventories/_template inventories/<顧客名>/<環境名>
# hosts.yml の CUSTOMER とホスト定義、group_vars/all.yml を書き換える
```

## 認証情報

- SSH 鍵は各環境の `group_vars/all.yml` の `ansible_ssh_private_key_file` で指定する。
- パスワード等の秘密情報は顧客ごとに vault-id を分けて ansible-vault で暗号化する:
  `ansible-vault encrypt --vault-id customer_a@prompt inventories/customer_a/production/group_vars/vault.yml`
