#!/usr/bin/env bash
set -euo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for script in "$project"/*.sh "$project"/tests/*.sh; do
    bash -n "$script"
done
for suite in install integration recovery; do
    bash "$project/tests/$suite.sh"
done
echo '全部测试通过。'
