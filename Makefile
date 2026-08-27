# 顧客 × 環境を明示してプレイブックを実行するラッパー
#
# 使い方:
#   make list  C=customer_a E=production                # 対象ホストの確認
#   make check C=customer_a E=production P=site         # ドライラン（--check --diff）
#   make run   C=customer_a E=production P=site         # 本実行
#   make run   C=customer_a E=production P=site L=ca-prd-web01   # 特定サーバーのみ
#   make run   C=customer_a E=production P=site L=web            # 役割グループのみ
#
# C=顧客名 E=環境名 P=プレイブック名(既定: site) L=--limit の値(省略可)
#
# 全顧客 × 全環境の横断操作:
#   make list-all     # 全インベントリーの対象ホストを一覧表示
#   make report       # 全ホストから環境情報を収集して管理台帳を生成
#                     # → build/ledger.csv / build/ledger.md

P ?= site
INV = inventories/$(C)/$(E)
LIMIT = $(if $(L),--limit $(L))

# 全「顧客 × 環境」ディレクトリー（_template を除く）
ALL_ENVS = $(shell find inventories -mindepth 2 -maxdepth 2 -type d ! -path 'inventories/_template*' | sort)

.PHONY: help guard list check run list-all report

help:
	@grep -E '^#( |$$)' Makefile | sed 's/^# \{0,1\}//'

guard:
	@test -n "$(C)" || { echo "C（顧客名）を指定してください。例: make run C=customer_a E=production"; exit 1; }
	@test -n "$(E)" || { echo "E（環境名）を指定してください。例: make run C=customer_a E=production"; exit 1; }
	@test -d "$(INV)" || { echo "インベントリーが見つかりません: $(INV)"; exit 1; }

list: guard
	ansible-inventory -i $(INV) --graph

check: guard
	ansible-playbook -i $(INV) playbooks/$(P).yml --check --diff $(LIMIT)

run: guard
	ansible-playbook -i $(INV) playbooks/$(P).yml $(LIMIT)

list-all:
	@for d in $(ALL_ENVS); do echo "=== $$d ==="; ansible-inventory -i $$d --graph; done

# group_vars/all.yml が環境ごとに異なる（SSH 設定等が衝突する）ため、
# 複数 -i の一括指定ではなく環境ごとに実行して build/report/ に集約する。
report:
	rm -rf build/report
	@for d in $(ALL_ENVS); do \
		echo "=== $$d ==="; \
		ansible-playbook -i $$d playbooks/inventory_report.yml || echo "WARN: $$d の収集に失敗"; \
	done
	@echo "生成完了: build/ledger.csv / build/ledger.md"
