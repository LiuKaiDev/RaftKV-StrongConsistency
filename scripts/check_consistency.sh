#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "${TMP_DIR}"/*.dump; rmdir "${TMP_DIR}" 2>/dev/null || true' EXIT

servers=(127.0.0.1:9001 127.0.0.1:9002 127.0.0.1:9003)

dump_once() {
  local attempt="$1"
  for i in "${!servers[@]}"; do
    if ! "${ROOT_DIR}/bin/kv_client" --servers="${servers[$i]}" dump | sort >"${TMP_DIR}/node$((i + 1)).dump"; then
      echo "attempt ${attempt}: node$((i + 1)) dump failed"
      return 1
    fi
  done

  cmp -s "${TMP_DIR}/node1.dump" "${TMP_DIR}/node2.dump" && \
    cmp -s "${TMP_DIR}/node1.dump" "${TMP_DIR}/node3.dump"
}

for attempt in $(seq 1 10); do
  if dump_once "${attempt}"; then
    echo "all nodes are consistent"
    exit 0
  fi
  if [[ "${attempt}" -lt 10 ]]; then
    echo "attempt ${attempt}: nodes are not consistent yet, wait follower catch-up"
    sleep 1
  fi
done

echo "nodes are inconsistent after retries"
diff -u "${TMP_DIR}/node1.dump" "${TMP_DIR}/node2.dump" || true
diff -u "${TMP_DIR}/node1.dump" "${TMP_DIR}/node3.dump" || true
exit 1
