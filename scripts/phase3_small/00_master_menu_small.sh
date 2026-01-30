#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

menu() {
  cat <<'EOF'

==============================
 Phase3 SMALL Interactive Menu
==============================
 1) UP core (Central + JS quorum)
 2) Ensure JetStream streams
 3) UP add zone SNC
 4) UP add subzone SNC/unit1
 5) UP add leaf (subzone desk1)
 6) SMOKE UP end-to-end (leaf→...→central)
 7) SMOKE DOWN end-to-end (central→...→subzone)
 8) Add leaf to central (desk1) + UP check
 9) Add leaf to zone SNC (desk1) + UP check
10) OFFLINE zone relay replay (leaf backlog)
90) DOWN keep volumes
91) DOWN purge volumes
 q) Quit
EOF
}

while true; do
  menu
  read -r -p "Select: " c
  case "${c}" in
    1)  bash "${DIR}/01_up_central.sh" ;;
    2)  bash "${DIR}/02_js_ensure_streams_v2.sh" ;;
    3)  bash "${DIR}/03_up_zone_snc.sh" ;;
    4)  bash "${DIR}/04_up_subzone_snc_unit1.sh" ;;
    5)  bash "${DIR}/05_up_leaf_subzone_snc_unit1_desk1.sh" ;;
    6)  bash "${DIR}/06a_smoke_up_end_to_end_v2.sh" ;;
    7)  bash "${DIR}/07_smoke_down_end_to_end.sh" ;;
    8)  bash "${DIR}/08_add_leaf_central_desk1.sh" ;;
    9)  bash "${DIR}/09_add_leaf_zone_snc_desk1.sh" ;;
   10)  bash "${DIR}/10_offline_zone_replay.sh" ;;
   90)  bash "${DIR}/90_down_keep.sh" ;;
   91)  bash "${DIR}/91_down_purge.sh" ;;
    q|Q) exit 0 ;;
    *) echo "Invalid choice" ;;
  esac
done
