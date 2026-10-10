#!/usr/bin/env bash
# =============================================================================
# Security Gateway — анализ SARIF-отчётов и применение порогов.
# -----------------------------------------------------------------------------
# Использование:
#   ./scripts/security-gateway.sh <артефакт-директория>
#
# Пороги:
#   Critical >= 1  → exit 1 (блокирует релиз)
#   High     >= 1  → exit 1
#   Medium   >= 1  → warn (в GitHub Step Summary)
#   Low/Info       → информационно
#
# Входные файлы (SARIF):
#   semgrep.sarif     — SAST
#   trivy-fs.sarif    — SCA (filesystem)
#   trivy-image.sarif — Container
#   report_json.json  — ZAP baseline (JSON, не SARIF)
# =============================================================================

set -euo pipefail

ARTIFACTS_DIR="${1:-.}"
cd "$ARTIFACTS_DIR"

# Пороги
THRESHOLD_CRITICAL=1
THRESHOLD_HIGH=1

TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_LOW=0

echo "================================================"
echo " Security Gateway — анализ отчётов"
echo "================================================"
echo

# -----------------------------------------------------------------------------
# Функция: подсчёт severity из SARIF-файла
# -----------------------------------------------------------------------------
count_sarif() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    echo "  [$label] файл не найден: $file — пропуск"
    return
  fi

  local critical high medium low
  critical=$(jq '[.runs[].results[]? | select(.level=="error") | select(.properties.severity? // "" | ascii_downcase == "critical")] | length' "$file" 2>/dev/null || echo 0)
  high=$(jq '[.runs[].results[]? | select(.level=="error") | select(.properties.severity? // "" | ascii_downcase == "high")] | length' "$file" 2>/dev/null || echo 0)
  medium=$(jq '[.runs[].results[]? | select(.level=="warning")] | length' "$file" 2>/dev/null || echo 0)
  low=$(jq '[.runs[].results[]? | select(.level=="note" or .level=="none")] | length' "$file" 2>/dev/null || echo 0)

  echo "  [$label]  CRITICAL=$critical  HIGH=$high  MEDIUM=$medium  LOW=$low"

  TOTAL_CRITICAL=$((TOTAL_CRITICAL + critical))
  TOTAL_HIGH=$((TOTAL_HIGH + high))
  TOTAL_MEDIUM=$((TOTAL_MEDIUM + medium))
  TOTAL_LOW=$((TOTAL_LOW + low))
}

# -----------------------------------------------------------------------------
# Функция: подсчёт из ZAP JSON
# -----------------------------------------------------------------------------
count_zap() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "  [ZAP] файл не найден: $file — пропуск"
    return
  fi

  local high medium low info
  high=$(jq '[.site[].alerts[]? | select(.riskcode=="3")] | length' "$file" 2>/dev/null || echo 0)
  medium=$(jq '[.site[].alerts[]? | select(.riskcode=="2")] | length' "$file" 2>/dev/null || echo 0)
  low=$(jq '[.site[].alerts[]? | select(.riskcode=="1")] | length' "$file" 2>/dev/null || echo 0)
  info=$(jq '[.site[].alerts[]? | select(.riskcode=="0")] | length' "$file" 2>/dev/null || echo 0)

  echo "  [ZAP]    CRITICAL=0  HIGH=$high  MEDIUM=$medium  LOW=$low  INFO=$info"

  TOTAL_HIGH=$((TOTAL_HIGH + high))
  TOTAL_MEDIUM=$((TOTAL_MEDIUM + medium))
  TOTAL_LOW=$((TOTAL_LOW + low))
}

# -----------------------------------------------------------------------------
# Подсчёт
# -----------------------------------------------------------------------------
echo "Результаты сканеров:"
count_sarif "semgrep.sarif"      "Semgrep"
count_sarif "trivy-fs.sarif"     "Trivy FS"
count_sarif "trivy-image.sarif"  "Trivy Image"
count_zap "report_json.json"

echo
echo "================================================"
echo " Итог по всем сканерам"
echo "================================================"
echo " Critical: $TOTAL_CRITICAL"
echo " High:     $TOTAL_HIGH"
echo " Medium:   $TOTAL_MEDIUM"
echo " Low:      $TOTAL_LOW"
echo

# -----------------------------------------------------------------------------
# GitHub Step Summary (если запускается в Actions)
# -----------------------------------------------------------------------------
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 🛡️ Security Gateway — итог"
    echo
    echo "| Severity | Count | Threshold | Status |"
    echo "|----------|-------|-----------|--------|"
    echo "| 🔴 Critical | $TOTAL_CRITICAL | ≥$THRESHOLD_CRITICAL | $([[ $TOTAL_CRITICAL -ge $THRESHOLD_CRITICAL ]] && echo '❌ FAIL' || echo '✅ pass') |"
    echo "| 🟠 High | $TOTAL_HIGH | ≥$THRESHOLD_HIGH | $([[ $TOTAL_HIGH -ge $THRESHOLD_HIGH ]] && echo '❌ FAIL' || echo '✅ pass') |"
    echo "| 🟡 Medium | $TOTAL_MEDIUM | warn | $([[ $TOTAL_MEDIUM -gt 0 ]] && echo '⚠️ warn' || echo '✅ pass') |"
    echo "| 🔵 Low | $TOTAL_LOW | info | ℹ️ |"
    echo
    echo "### Источники"
    echo "- **SAST:** Semgrep"
    echo "- **SCA:** Trivy fs, npm audit"
    echo "- **Container:** Trivy image, Hadolint"
    echo "- **DAST:** OWASP ZAP baseline"
    echo
    if [[ $TOTAL_CRITICAL -ge $THRESHOLD_CRITICAL ]] || [[ $TOTAL_HIGH -ge $THRESHOLD_HIGH ]]; then
      echo "### ❌ Релиз заблокирован"
      echo "Обнаружены уязвимости выше порога. Исправьте критичные/высокие находки перед merge."
    else
      echo "### ✅ Релиз разрешён"
      echo "Critical и High не превышают порогов. Релиз может продолжаться."
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# -----------------------------------------------------------------------------
# Применение порогов
# -----------------------------------------------------------------------------
if [[ $TOTAL_CRITICAL -ge $THRESHOLD_CRITICAL ]] || [[ $TOTAL_HIGH -ge $THRESHOLD_HIGH ]]; then
  echo "❌ SECURITY GATEWAY: релиз заблокирован."
  echo "   Critical=$TOTAL_CRITICAL (порог $THRESHOLD_CRITICAL)"
  echo "   High=$TOTAL_HIGH (порог $THRESHOLD_HIGH)"
  exit 1
fi

echo "✅ SECURITY GATEWAY: пороги пройдены."
exit 0
