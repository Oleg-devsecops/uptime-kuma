# Security Checks — секреты, зависимости, контейнеры

В этом разделе описаны три категории проверок, дополняющих SAST/DAST:

1. **Secrets** — поиск утечек секретов в коде и истории коммитов.
2. **SCA** — анализ зависимостей (Software Composition Analysis).
3. **Container** — безопасность Dockerfile и образа.

---

## 1. Secrets — Gitleaks

### Что это

[Gitleaks](https://github.com/gitleaks/gitleaks) — инструмент поиска **секретов** (токенов, ключей, паролей) в Git-репозитории: в текущих файлах, в истории коммитов, в staged-изменениях.

### Почему Gitleaks

| Критерий | Gitleaks | truffleHog | detect-secrets |
|---|---|---|---|
| Лицензия | MIT | AGPL | Apache 2.0 |
| История коммитов | ✅ | ✅ | Частично |
| Кастомные правила | TOML | Python | YAML |
| Скорость | Очень быстро (Go) | Быстро | Быстро |
| GitHub Action | ✅ Официальный | ✅ | ✅ |
| SARIF | ✅ | ✅ | ⚠️ |

### Настройка в пайплайне

```yaml
secrets-gitleaks:
  needs: build
  permissions:
    contents: read
  steps:
    - name: Checkout (full history)
      uses: actions/checkout@v4
      with:
        fetch-depth: 0      # вся история — иначе не найдёт старые утечки
        persist-credentials: false

    - name: Run Gitleaks
      uses: gitleaks/gitleaks-action@v2
      env:
        GITLEAKS_ENABLE_COMMENTS: "false"
Ключевые моменты
fetch-depth: 0 — обязателен. Без него action видит только последний коммит.

persist-credentials: false — безопасность: не сохраняем GITHUB_TOKEN в .git/config.

GITLEAKS_ENABLE_COMMENTS: "false" — не создаём issue автоматически.

Что ищет
Gitleaks содержит 130+ правил, покрывающих:

AWS Access Key / Secret Key

GitHub PAT / OAuth tokens

Google API keys

Stripe / Twilio / SendGrid keys

JWT tokens

RSA / DSA / EC приватные ключи

SSH приватные ключи

Slack / Discord webhooks

Общие паттерны — password=, secret=, token= в переменных

Результаты первого запуска
text
No leaks detected ✅
Ни одного секрета в истории репозитория Uptime Kuma не обнаружено. Это ожидаемо — проект зрелый, автор не коммитит секреты.

Отчёт сохранён в артефактах:

gitleaks-report — SARIF.

gitleaks-results.sarif.

2. SCA — Trivy fs + npm audit
Что это
SCA (Software Composition Analysis) — анализ зависимостей проекта на известные уязвимости (CVE).

2.1. npm audit
Встроенный в npm анализатор — использует базу GitHub Advisory Database.

bash
npm audit --omit=dev --json > npm-audit.json
--omit=dev — только production-зависимости. Dev-зависимости (vite, eslint) не едут в production-образ, их CVE менее критичны.

--json — для парсинга в gateway.

Плюсы:

Бесплатно, встроено.

Точные данные для npm-экосистемы.

Учитывает transitive dependencies.

Минусы:

Только Node.js.

Не покрывает системные пакеты в образе.

2.2. Trivy fs
Trivy — универсальный сканер от Aqua Security.

yaml
- name: Trivy fs scan
  uses: aquasecurity/trivy-action@master
  with:
    scan-type: fs
    scan-ref: .
    format: sarif
    output: trivy-fs.sarif
    severity: CRITICAL,HIGH,MEDIUM
    ignore-unfixed: true
    exit-code: "0"
Что сканирует Trivy fs:

package-lock.json — npm-зависимости.

Dockerfile — misconfiguration.

Terraform / Kubernetes YAML — если есть.

Системные пакеты — если запущен в контексте контейнера.

Почему Trivy:

Мультиязычный: npm, pip, go, maven, bundler, cargo.

Поддерживает ОС-пакеты (Debian, Alpine).

Один инструмент для fs / image / repo / k8s.

SARIF-вывод «из коробки».

ignore-unfixed: true — игнорирует CVE без патча (иначе сотни «вечных» алертов).

2.3. Выбор между npm audit и Trivy
Аспект	npm audit	Trivy fs
Экосистема	Только npm	10+
Системные пакеты	❌	✅
Скорость	Мгновенно	30–60 сек
Формат	JSON	SARIF, JSON, table
GitHub Security	❌	✅
Используются оба — npm audit даёт детальные рекомендации по npm-пакетам, Trivy — общее покрытие и SARIF.

Результаты
На Uptime Kuma:

npm audit: 6 moderate, 4 high, 2 critical (в основном в dev-зависимостях и transitive).

Trivy fs: аналогичный набор CVE, выгружен в SARIF.

Все алерты в:

text
https://github.com/Oleg-devsecops/uptime-kuma/security/code-scanning
3. Container — Hadolint + Trivy image
3.1. Hadolint
Hadolint — линтер Dockerfile.

yaml
- name: Hadolint (Dockerfile linter)
  uses: hadolint/hadolint-action@v3.1.0
  with:
    dockerfile: docker/dockerfile
    failure-threshold: warning
Что проверяет:

DL3001 — не использовать apt, yum внутри RUN.

DL3008 — пинить версии apt-пакетов.

DL3013 — пинить версии pip.

DL3025 — использовать JSON-форму CMD/ENTRYPOINT.

DL4006 — устанавливать SHELL для pipefail.

DL3059 — несколько подряд RUN — консолидировать.

DL3027 — не использовать apt (нужен apt-get).

Порог warning: job падает при warning и выше. Info — игнорируется.

3.2. Trivy image
Сканирование собранного Docker-образа.

bash
docker build --target release -f docker/dockerfile -t uptime-kuma:devsecops-$SHA .
yaml
- name: Trivy image scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: uptime-kuma:devsecops-${{ github.sha }}
    severity: CRITICAL,HIGH
    ignore-unfixed: true
Что сканирует:

Системные пакеты базового образа (Debian, Alpine).

Node.js-зависимости внутри /app/node_modules.

Конфигурацию образа (exposed ports, env vars, user).

Флаги:

severity: CRITICAL,HIGH — отсекаем Medium/Low из образа (иначе сотни алертов в базовом node:26).

ignore-unfixed: true — не флагаем CVE без доступного патча.

Результаты
На образ ghcr.io/oleg-devsecops/uptime-kuma:latest:

Critical: 0

High: 2 (в базовом образе Node.js — известные CVE в libssl, патч ещё не выпущен upstream).

Medium: ~90 (в основном apt-пакеты Debian).

Все High/Critical имеют ignore-unfixed или затрагивают базовый образ — не наши прямые зависимости.

Security Gateway и эти проверки
Все SARIF-отчёты (semgrep.sarif, trivy-fs.sarif, trivy-image.sarif) попадают в security-gateway.sh. Функция count_sarif считает находки по level:

error — Critical/High.

warning — Medium.

note — Low/Info.

Пороги:

Severity	Действие
Critical ≥ 1	❌ Блокирует релиз
High ≥ 1	❌ Блокирует релиз
Medium ≥ 1	⚠️ Warn
Low/Info	ℹ️ Информация
Важно: на момент написания диплома High = 0 в SARIF от Trivy image, потому что:

Medium не попадает в SARIF-вывод (severity: CRITICAL,HIGH).

High с ignore-unfixed: true отсеиваются, если нет патча.

Такой подход — компромисс между строгостью и практичностью: не блокируем релиз из-за CVE, которые мы не можем исправить без обновления upstream-образа.

Ограничения
SCA не находит 0-day уязвимости — только те, что уже есть в CVE-базах.

Gitleaks не ловит зашифрованные секреты — если в репозитории лежит зашифрованный блоб, он не будет распознан.

Hadolint оценивает только Dockerfile, не сам образ.

Trivy использует базу NVD, которая обновляется с задержкой 1–3 дня после CVE.

Ссылки
Gitleaks: https://github.com/gitleaks/gitleaks

Trivy: https://trivy.dev/

Hadolint: https://github.com/hadolint/hadolint

npm audit: https://docs.npmjs.com/cli/v10/commands/npm-audit

GitHub Advisory Database: https://github.com/advisories

CVE / NVD: https://nvd.nist.gov/
