# DAST — Dynamic Application Security Testing

## Что это

**DAST** — динамический анализ **работающего** приложения. В отличие от SAST (который смотрит исходный код), DAST ведёт себя как реальный пользователь или атакующий: отправляет HTTP-запросы, изучает ответы, ищет уязвимости в поведении.

DAST не видит код — он тестирует **развёрнутый сервис**.

## OWASP ZAP

### Что это

[OWASP ZAP](https://www.zaproxy.org/) (Zed Attack Proxy) — самый популярный open-source DAST-инструмент. Поддерживается OWASP Foundation, интегрируется с CI/CD через официальные GitHub Actions.

### Почему ZAP

| Критерий | ZAP | Burp Suite | Nessus |
|---|---|---|---|
| Лицензия | Apache 2.0 | Community / Pro (платно) | Платно |
| CI-интеграция | Официальный Action | Через CLI, сложно | Нет |
| Режимы | Baseline / Full / API | Manual + Auto | Network-level |
| Порог входа | Низкий | Средний | Высокий |
| Open-source | ✅ | Community ограничен | ❌ |

**Вывод:** ZAP — оптимальный выбор для CI:
- Официальный `zaproxy/action-baseline` — готовый Action.
- Три режима: baseline (безопасный), full (активный), api (для REST API).
- SARIF/JSON/HTML-отчёты.
- Бесплатный.

## Baseline vs Full scan

| Параметр | Baseline | Full |
|---|---|---|
| Активные атаки | ❌ Только пассивные | ✅ SQLi, XSS, обход авторизации |
| Риск сломать сервис | Минимальный | Высокий |
| Время | 2–5 мин | 30–120 мин |
| Использование в CI | ✅ Каждый PR | Ночью по расписанию |
| Наш выбор | ✅ Основной | Опционально |

**В дипломе реализован baseline** — он безопасен для staging и подходит для запуска после каждого деплоя.

## Настройка в пайплайне

```yaml
dast-zap:
  name: DAST (OWASP ZAP baseline)
  runs-on: ubuntu-latest
  timeout-minutes: 20
  needs: [deploy-staging]
  if: github.ref == 'refs/heads/master' && github.event_name == 'push'

  steps:
    - name: Wait for staging service
      run: |
        for i in $(seq 1 30); do
          if curl -sSf -o /dev/null -m 5 http://89.23.97.174; then
            echo "Service is up"
            exit 0
          fi
          sleep 5
        done
        exit 1

    - name: ZAP Baseline Scan
      uses: zaproxy/action-baseline@v0.12.0
      with:
        target: 'http://89.23.97.174'
        rules_file_name: '.zap/rules.tsv'
        cmd_options: '-a -j'
        allow_issue_writing: true
Логика
Ждём готовности сервиса. После deploy-staging контейнеру нужно 10–30 секунд на старт. Шаг делает до 30 попыток curl с паузой 5 секунд (итого до 150 секунд).

ZAP Baseline Scan. Action разворачивает ZAP в контейнере, сканирует целевой URL, генерирует отчёты.

Выгрузка артефактов — HTML, JSON, Markdown отчёты.

SARIF в GitHub Security — ZAP также умеет отдавать SARIF.

Опции запуска
yaml
cmd_options: '-a -j'
-a — включать alpha-правила (экспериментальные, но полезные).

-j — использовать AJAX Spider (сканирует JS-приложения, что критично для Vue).

Без -j ZAP не сможет пройти по страницам нашего SPA — нужен именно AJAX spider.

Правила .zap/rules.tsv
Файл управляет тем, какие правила считать серьёзными:

text
10015	IGNORE	# Incomplete or No Cache-control Header Set
10096	IGNORE	# Timestamp Disclosure
10109	IGNORE	# Modern Web Application
Формат: <rule_id> <IGNORE|WARN|FAIL> <comment>

IGNORE — не сообщать.

WARN — сообщить, не блокировать.

FAIL — считать серьёзной.

Результаты первого прогона
На staging http://89.23.97.174:

Risk Level	Count
High	0
Medium	3
Low	7
Informational	10
False Positives	0
Medium (3)
CSP Header Not Set — отсутствует Content-Security-Policy. Типично для dev-окружений без reverse-proxy.

Missing Anti-clickjacking Header — нет X-Frame-Options / frame-ancestors.

Session ID in URL Rewrite — особенность socket.io, использующего sid в URL. Не является уязвимостью приложения.

Low (7)
COEP, COOP, CORP — заголовки кросс-доменной безопасности.

Dangerous JS Functions — eval() в собранном бандле (Vue/Vite).

Permissions-Policy не установлен.

Private IP Disclosure — 192.168.100.1 в демо-данных.

X-Content-Type-Options — anti-MIME-sniffing.

Informational (10)
localStorage использование, Sec-Fetch-* заголовки, кэширование и т. д.

Интерпретация для диплома
0 Critical и 0 High — сервис не имеет критичных уязвимостей.

Все Medium/Low — типичные для веб-приложений:

Часть исправляется настройкой reverse-proxy (nginx/Caddy с security headers).

Часть — особенности самого Uptime Kuma.

Часть — false positive (socket.io sid).

В реальной эксплуатации эти находки были бы отфильтрованы через:

nginx с заголовками Content-Security-Policy, X-Frame-Options, X-Content-Type-Options, Permissions-Policy.

Cloudflare или Traefik для HSTS + TLS.

Tuning .zap/rules.tsv для отсечения неактуальных правил.

Security Gateway и DAST
Результаты ZAP в формате JSON попадают в security-gateway.sh:

bash
count_zap "report_json.json"
Скрипт извлекает riskcode:

bash
high=$(jq '[.site[].alerts[]? | select(.riskcode=="3")] | length' "$file")
medium=$(jq '[.site[].alerts[]? | select(.riskcode=="2")] | length' "$file")
При пороге High ≥ 1 — релиз блокируется.

Ограничения
Baseline не находит SQLi/XSS активно — только пассивные проверки.

Не сканирует формы авторизации без настройки — нужна аутентификация через контекст ZAP.

Slow-тесты — Full scan может занять 1–2 часа, в CI не подходит.

AJAX spider не всегда обходит весь SPA — часть Vue-роутов может остаться неисследованной.

Для полного покрытия рекомендуется:

Full scan ночью по расписанию.

API scan для REST-эндпоинтов (есть в ZAP).

Аутентифицированный скан через контекст (требует настройки).

Интеграция с GitHub Security
SARIF-отчёт ZAP публикуется командой upload-sarif:

yaml
- name: Upload ZAP SARIF to GitHub Security
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: report_json.json
    category: zap-baseline
Все алерты отображаются в:

text
https://github.com/Oleg-devsecops/uptime-kuma/security/code-scanning
Ссылки
OWASP ZAP: https://www.zaproxy.org/

ZAP Baseline Action: https://github.com/zaproxy/action-baseline

ZAP Rules: https://www.zaproxy.org/docs/alerts/

OWASP Testing Guide: https://owasp.org/www-project-web-security-testing-guide/
