# Security Gateway

## Что это

**Security Gateway** — финальный job в пайплайне, который:

1. **Собирает** SARIF-отчёты всех сканеров.
2. **Считает** уязвимости по severity.
3. **Применяет пороги** и решает: пропустить релиз или заблокировать.
4. **Публикует** итоги в GitHub Step Summary.
5. **Комментирует PR** с рекомендациями.

Это тот самый механизм из требований диплома:

> ✅ Имеется триггер на остановку релиза при наличии уязвимостей.  
> ✅ Сделаны дополнительные триггеры — оставление комментариев в MR, выгрузка рекомендаций по исправлению уязвимостей.

## Зачем нужен

Без gateway каждая security-проверка работает **в вакууме**: Semgrep находит, Trivy находит, ZAP находит, но **никто не принимает решение**. Разработчик видит 92 Medium в отчётах и не понимает — это критично или нет.

Gateway централизует **политику безопасности**:

- Один файл с порогами.
- Одно решение — релиз/стоп.
- Единый отчёт по всем сканерам.
- Автоматическая коммуникация в PR.

## Архитектура
┌─────────────────────────────────────────────────────────────┐
│ Отчёты от сканеров (SARIF + JSON) │
│ │
│ • semgrep.sarif (SAST) │
│ • trivy-fs.sarif (SCA) │
│ • trivy-image.sarif (Container) │
│ • report_json.json (DAST, ZAP) │
│ • results.sarif (Secrets, Gitleaks) │
│ │
│ │ │
│ ▼ │
│ ┌───────────────────────────┐ │
│ │ scripts/security- │ │
│ │ gateway.sh │ │
│ │ │ │
│ │ • Парсит SARIF (jq) │ │
│ │ • Считает severity │ │
│ │ • Применяет пороги │ │
│ │ • Пишет в Step Summary │ │
│ └───────────┬───────────────┘ │
│ │ │
│ ┌───────┴───────┐ │
│ ▼ ▼ │
│ exit 0 exit 1 │
│ (pass) (fail) │
└─────────────────────────────────────────────────────────────┘

text

## Пороги

| Severity | Порог | Действие |
|---|---|---|
| **Critical** | ≥ 1 | ❌ Блокирует merge |
| **High** | ≥ 1 | ❌ Блокирует merge |
| **Medium** | ≥ 1 | ⚠️ Warn (в summary) |
| **Low / Info** | — | ℹ️ Информационно |

Пороги **настраиваются** в скрипте:

```bash
THRESHOLD_CRITICAL=1
THRESHOLD_HIGH=1
Логика: любой Critical или High — стоп. Medium/Low публикуются, но не блокируют.

Скрипт security-gateway.sh
Функция count_sarif
Парсит SARIF-файл через jq:

bash
count_sarif() {
  local file="$1"
  local label="$2"

  critical=$(jq '[.runs[].results[]? | 
    select(.level=="error") | 
    select(.properties.severity? // "" | ascii_downcase == "critical")] | 
    length' "$file")
    
  high=$(jq '[.runs[].results[]? | 
    select(.level=="error") | 
    select(.properties.severity? // "" | ascii_downcase == "high")] | 
    length' "$file")
    
  medium=$(jq '[.runs[].results[]? | 
    select(.level=="warning")] | length' "$file")
    
  low=$(jq '[.runs[].results[]? | 
    select(.level=="note" or .level=="none")] | length' "$file")

  echo "  [$label]  CRITICAL=$critical  HIGH=$high  MEDIUM=$medium  LOW=$low"

  TOTAL_CRITICAL=$((TOTAL_CRITICAL + critical))
  TOTAL_HIGH=$((TOTAL_HIGH + high))
  # ...
}
Функция count_zap
ZAP отдаёт JSON, а не SARIF. Отдельная функция:

bash
count_zap() {
  high=$(jq '[.site[].alerts[]? | 
    select(.riskcode=="3")] | length' "$file")
    
  medium=$(jq '[.site[].alerts[]? | 
    select(.riskcode=="2")] | length' "$file")
  # ...
}
GitHub Step Summary
Если переменная GITHUB_STEP_SUMMARY установлена (всегда в Actions), скрипт пишет markdown:

bash
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 🛡️ Security Gateway — итог"
    echo
    echo "| Severity | Count | Threshold | Status |"
    echo "|----------|-------|-----------|--------|"
    echo "| 🔴 Critical | $TOTAL_CRITICAL | ≥$THRESHOLD_CRITICAL | ... |"
    echo "| 🟠 High | $TOTAL_HIGH | ≥$THRESHOLD_HIGH | ... |"
    # ...
  } >> "$GITHUB_STEP_SUMMARY"
fi
Применение порогов
bash
if [[ $TOTAL_CRITICAL -ge $THRESHOLD_CRITICAL ]] || 
   [[ $TOTAL_HIGH -ge $THRESHOLD_HIGH ]]; then
  echo "❌ SECURITY GATEWAY: релиз заблокирован."
  exit 1
fi

echo "✅ SECURITY GATEWAY: пороги пройдены."
exit 0
Job в workflow
yaml
security-gateway:
  name: Security Gateway
  runs-on: ubuntu-latest
  timeout-minutes: 5
  needs: [build, sast-semgrep, secrets-gitleaks, sca, container, 
          build-and-push, dast-zap]
  if: always() && (github.ref == 'refs/heads/master' || 
                   github.event_name == 'pull_request')
  permissions:
    contents: read
    security-events: write
    pull-requests: write

  steps:
    - uses: actions/checkout@v4

    - name: Download all security artifacts
      uses: actions/download-artifact@v4
      with:
        path: artifacts

    - name: Prepare reports directory
      run: |
        mkdir -p reports
        find artifacts -type f \( -name '*.sarif' -o -name 'report_json.json' \) \
          -exec cp {} reports/ \;

    - name: Run Security Gateway
      id: gateway
      run: |
        chmod +x scripts/security-gateway.sh
        bash scripts/security-gateway.sh reports

    - name: Comment on PR
      if: github.event_name == 'pull_request'
      uses: actions/github-script@v7
      env:
        GATEWAY_STATUS: ${{ steps.gateway.outcome }}
      with:
        script: |
          const status = process.env.GATEWAY_STATUS;
          const icon = status === 'success' ? '✅' : '❌';
          const body = `...markdown-комментарий...`;
          await github.rest.issues.createComment({
            issue_number: context.issue.number,
            owner: context.repo.owner,
            repo: context.repo.repo,
            body
          });
Особенности
if: always() — job выполняется, даже если другие упали. Это важно: gateway должен собрать все отчёты независимо от статуса предыдущих job'ов.

needs: [..., dast-zap] — ждёт все сканеры.

Условие master/PR — на feature-ветки не запускается, чтобы не спамить.

pull-requests: write — право комментировать PR.

Итоговый вывод
После прогона pipeline видишь:

text
================================================
 Security Gateway — анализ отчётов
================================================

Результаты сканеров:
  [Semgrep]      CRITICAL=0  HIGH=0  MEDIUM=20  LOW=15
  [Trivy FS]     CRITICAL=0  HIGH=2  MEDIUM=45  LOW=10
  [Trivy Image]  CRITICAL=0  HIGH=0  MEDIUM=25  LOW=15
  [ZAP]          CRITICAL=0  HIGH=0  MEDIUM=3   LOW=7   INFO=10

================================================
 Итог по всем сканерам
================================================
 Critical: 0
 High:     2
 Medium:   93
 Low:      47

❌ SECURITY GATEWAY: релиз заблокирован.
Или, при 0 Critical/High:

text
✅ SECURITY GATEWAY: пороги пройдены.
Комментарий в PR
При github.event_name == 'pull_request' gateway публикует:

✅ Security Gateway
Security Gateway: пороги пройдены. Релиз разрешён.

Рекомендации
Critical/High: исправить до merge

Medium: рассмотреть в следующем релизе

Low/Info: информационно, действий не требуется

Отчёт доступен в разделе Actions → этот workflow → артефакты.

При провале порогов:

❌ Security Gateway
Security Gateway: релиз заблокирован. Обнаружены Critical/High уязвимости.

...рекомендации...

Проверка работы
Тест 1: обычный push в master
Все 9 job'ов выполняются.

Security Gateway проходит (0 Critical/High).

Step Summary публикуется.

Тест 2: PR
Создаётся ветка test/security-gateway-pr-comment.

Commit с изменением.

Push.

Создаём PR в свой форк (не в upstream!).

Pipeline прогоняется.

Gateway комментирует PR.

PR закрывается вручную.

Тест 3: имитация провала
Можно временно изменить порог:

bash
THRESHOLD_MEDIUM=1
И добавить Medium в блокирующие. Тогда gateway упадёт — так можно показать работу в дипломе.

Ограничения
Gateway не исправляет уязвимости — только флагает.

Пороги статичные — заданы в скрипте. Их можно вынести в config.yaml для гибкости.

Нет интеграции с Jira/Linear — все уведомления только в GitHub.

Нет трассировки по времени — gateway не хранит историю (сколько было вчера, стало сегодня).

Всё это — зоны роста, описаны в growth-zones.md.

Ссылки
scripts/security-gateway.sh — исходник

actions/github-script — https://github.com/actions/github-script

SARIF спецификация: https://sarifweb.azurewebsites.net/

jq: https://jqlang.github.io/jq/
