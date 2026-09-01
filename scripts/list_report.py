#!/usr/bin/env python3
"""直前の make report の収集結果（build/report/*.json）からホスト一覧を表示する。

make list-all から呼ばれる。ansible-inventory を叩かないので SSH 接続も発生しない。
JSON が 1 件も無い場合は終了コード 1 を返し、Makefile 側が ansible-inventory に切り替える。
"""
import glob
import json
import os
import sys


def main(report_dir: str) -> int:
    paths = sorted(glob.glob(os.path.join(report_dir, "*.json")))
    if not paths:
        return 1

    records = []
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                records.append(json.load(f))
        except (OSError, ValueError) as e:
            print(f"WARN: {p} を読めません: {e}", file=sys.stderr)

    # 顧客 → 環境 → ホスト名 の順に並べる
    records.sort(key=lambda r: (r.get("customer", ""), r.get("environment", ""), r.get("hostname", "")))

    latest = max((r.get("collected_at", "") for r in records), default="")
    print(f"# 直前の make report の結果を表示しています（{report_dir}/, {len(records)} ホスト, 最終収集 {latest}）")
    print("# 最新の状態を取り直すには make report、インベントリーを直接照会するには make list-all LIVE=1")

    current = None
    for r in records:
        key = (r.get("customer", ""), r.get("environment", ""))
        if key != current:
            current = key
            print(f"\n=== inventories/{key[0]}/{key[1]} ===")
        print(
            f"  {r.get('hostname', ''):<20} {r.get('status', ''):<12} "
            f"{r.get('ansible_host', ''):<18} groups: {r.get('groups', '')}  "
            f"collected: {r.get('collected_at', '')}"
        )

    unreachable = [r["hostname"] for r in records if r.get("status") != "ok"]
    if unreachable:
        print(f"\n# 到達不能 {len(unreachable)} 台: {' '.join(unreachable)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/report"))
