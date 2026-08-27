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

## 管理台帳の作成（全顧客 × 全環境 × 全ホスト）

```bash
make list-all   # 全インベントリーの対象ホストを一覧表示（SSH 接続なし）
make report     # 全ホストからファクトを収集して台帳を生成
```

`make report` は `_template` を除く全「顧客 × 環境」を順に実行し、
ホストごとの収集結果を `build/report/*.json` に保存したうえで
**`build/ledger.csv`**（Excel でそのまま開ける UTF-8 BOM 付き）と
**`build/ledger.md`** を生成する。
収集項目: OS / カーネル / アーキテクチャ / vCPU / メモリ / ディスク / IPv4 /
ハードウェア基盤 / 所属グループ / 収集日時。到達できないホストも
`status: unreachable` として台帳に残る。

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
