#!/bin/bash
# Make every script in the live scripts dir executable (template sync copies
# files with default permissions; cron needs them runnable).

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

count=0
while IFS= read -r script; do
    chmod +x "$script"
    count=$((count + 1))
done < <(find "$SCRIPTS_DIR" -type f -name '*.sh')

echo "Marked $count scripts executable"
