# CI/CD Pipeline

## Обзор

Пайплайн реализован на **GitHub Actions** и описан в одном файле — [`.github/workflows/devsecops.yml`](../.github/workflows/devsecops.yml).

Запускается на:
- `push` в `master`
- `pull_request` в `master`
- ручной запуск через `workflow_dispatch`

## Схема
┌──────────────────────────────────────────────────────────────────┐
│ 1. Build & Test ─ lint, build, unit-tests (без Docker) │
│ │ │
│ ├──► 2. SAST (Semgrep) ─ статический анализ кода │
│ ├──► 3. Secrets (Gitleaks) ─ утечки секретов │
│ ├──► 4. SCA ─ npm audit + Trivy fs │
│ └──► 5. Container ─ Hadolint + Trivy image │
│ │ │
│ ▼ │
│ 6. Build & Push to GHCR ─ docker build + push (только master) │
│ │ │
│ ▼ │
│ 7. Deploy to Staging ─ SSH + docker compose (только master)│
│ │ │
│ ▼ │
│ 8. DAST (OWASP ZAP) ─ скан работающего сервиса │
│ │ │
│ ▼ │
│ 9. Security Gateway ─ пороги, стоп-релиз, PR-комментарии │
└──────────────────────────────────────────────────────────────────┘

## Стадии

### 1. Build & Test

**Раннер:** `ubuntu-latest`  
**Timeout:** 20 минут  
**Триггер:** всегда

**Шаги:**

- Checkout репозитория.
- Node.js 26.2.0 (из `engines.node` в `package.json`).
- `npm ci --no-audit --no-fund` — установка зависимостей с кэшем.
- `npm run lint:js` — ESLint.
- `npm run build` — сборка Vite (frontend).
- **Core backend tests** — 10 файлов без внешних зависимостей:
  - check-translations, test-better-auth, test-cert-hostname-match,
    test-domain, test-monitor-response, test-ping-chart,
    test-status-page, test-uptime-calculator, test-util, test-util-server.
- **Full test suite** (informational, `continue-on-error`) — все тесты, включая требующие внешних сервисов (MQTT, Oracle, MariaDB).
- Выгрузка артефакта `build-dist` (7 дней хранения).

**Почему так:**  
Тесты разделены на две группы: «обязательные» и «информационные». Это позволяет CI быть строгим к критичным тестам, но не блокироваться из-за отсутствия MQTT-брокера или Oracle в облаке. Стратегия описана в разделе [Зоны роста](growth-zones.md).

### 2. SAST (Semgrep)

**Timeout:** 20 минут  
**Зависит от:** `build`  
**Права:** `security-events: write`

**Шаги:**

- Установка Python 3.12.
- `pip install semgrep` — свежая версия (актуальный способ; `returntocorp/semgrep-action@v1` устарел).
- Запуск `semgrep scan` с наборами правил:
  - `p/javascript`
  - `p/typescript`
  - `p/vue`
  - `p/nodejs`
  - `p/owasp-top-ten`
  - `p/secrets`
- Выгрузка SARIF в артефакты.
- Загрузка SARIF в GitHub Security (`Code scanning alerts`).

**Аналитика выбора:** [sast.md](sast.md).

### 3. Secrets (Gitleaks)

**Timeout:** 10 минут  
**Зависит от:** `build`

**Шаги:**

- Checkout с `fetch-depth: 0` — полная история коммитов.
- `gitleaks/gitleaks-action@v2` — сканирование всей истории.
- Выгрузка отчёта в артефакты.

**Что ищет:** токены, приватные ключи, пароли, JWT, AWS/GCP credentials.

### 4. SCA (npm audit + Trivy fs)

**Timeout:** 15 минут  
**Зависит от:** `build`

**Шаги:**

- `npm ci --ignore-scripts`
- `npm audit --omit=dev --json > npm-audit.json` — только production-зависимости.
- Trivy fs по lock-файлам с `severity: CRITICAL,HIGH,MEDIUM`.
- Выгрузка SARIF в артефакты + GitHub Security.

**Что ищет:** CVE в зависимостях npm и в lock-файлах.

### 5. Container (Hadolint + Trivy image)

**Timeout:** 30 минут  
**Зависит от:** `build`

**Шаги:**

- **Hadolint** по `docker/dockerfile` (`failure-threshold: warning`) — best-practices Dockerfile.
- `docker build --target release -f docker/dockerfile` — сборка финальной стадии (release).
- **Trivy image** по собранному образу (`severity: CRITICAL,HIGH`, `ignore-unfixed: true`).
- Выгрузка SARIF.

**Важно:** указывается `--target release`, иначе Docker пытается собрать последнюю стадию в Dockerfile (`upload-artifact`), которая требует GitHub-токен и падает. Это решение вынужденное — описано в [growth-zones.md](growth-zones.md).

### 6. Build & Push to GHCR

**Timeout:** 30 минут  
**Зависит от:** всех предыдущих  
**Триггер:** только `push` в `master`

**Шаги:**

- Логин в GHCR через `GITHUB_TOKEN` (без внешних секретов).
- `docker build --target release`.
- Теги: `latest` и `sha-<7-символов-хеша>`.
- Push в `ghcr.io/<owner-lowercase>/uptime-kuma`.

**Особенность:** имя owner приведено к нижнему регистру через `tr '[:upper:]' '[:lower:]'` — Docker registry требует lowercase.

### 7. Deploy to Staging

**Timeout:** 10 минут  
**Зависит от:** `build-and-push`  
**Триггер:** только `push` в `master`

**Шаги:**

- SSH на VPS под пользователем `deploy` (ключ из секретов GitHub).
- `docker compose pull` — скачивание образа из GHCR.
- `docker compose up -d` — перезапуск контейнера.
- **Healthcheck loop:** ждём до 30 секунд `(healthy)` в `docker compose ps`.
- Если не стал healthy — печатаем логи и exit 1.

**Секреты GitHub:**
- `VPS_HOST` — IP сервера
- `VPS_USER` — `deploy`
- `VPS_SSH_PRIVATE_KEY` — приватный SSH-ключ

**Среда GitHub:** `environment: staging`, URL: `http://89.23.97.174`.

### 8. DAST (OWASP ZAP baseline)

**Timeout:** 20 минут  
**Зависит от:** `deploy-staging`

**Шаги:**

- Ожидание доступности сервиса (`curl` до 150 сек).
- ZAP baseline scan с конфигом `.zap/rules.tsv`.
- Выгрузка отчётов: HTML, JSON, Markdown.
- Загрузка SARIF в GitHub Security.

**Аналитика:** [dast.md](dast.md).

### 9. Security Gateway

**Timeout:** 5 минут  
**Зависит от:** всех сканеров  
**Триггер:** `master` или `pull_request`

**Шаги:**

- Скачивание всех SARIF/JSON-артефактов.
- Запуск `scripts/security-gateway.sh`:
  - Парсинг SARIF (`jq`).
  - Подсчёт по severity.
  - Применение порогов: Critical ≥ 1 → FAIL, High ≥ 1 → FAIL.
  - Публикация таблицы в GitHub Step Summary.
- **Если PR** — комментарий с рекомендациями через `actions/github-script`.

**Аналитика:** [security-gateway.md](security-gateway.md).

## Управление параллелизмом

```yaml
concurrency:
  group: devsecops-${{ github.ref }}
  cancel-in-progress: true

# CI/CD Pipeline

## Обзор

Пайплайн реализован на **GitHub Actions** и описан в одном файле — [`.github/workflows/devsecops.yml`](../.github/workflows/devsecops.yml).

Запускается на:
- `push` в `master`
- `pull_request` в `master`
- ручной запуск через `workflow_dispatch`

## Схема
┌──────────────────────────────────────────────────────────────────┐
│ 1. Build & Test ─ lint, build, unit-tests (без Docker) │
│ │ │
│ ├──► 2. SAST (Semgrep) ─ статический анализ кода │
│ ├──► 3. Secrets (Gitleaks) ─ утечки секретов │
│ ├──► 4. SCA ─ npm audit + Trivy fs │
│ └──► 5. Container ─ Hadolint + Trivy image │
│ │ │
│ ▼ │
│ 6. Build & Push to GHCR ─ docker build + push (только master) │
│ │ │
│ ▼ │
│ 7. Deploy to Staging ─ SSH + docker compose (только master)│
│ │ │
│ ▼ │
│ 8. DAST (OWASP ZAP) ─ скан работающего сервиса │
│ │ │
│ ▼ │
│ 9. Security Gateway ─ пороги, стоп-релиз, PR-комментарии │
└──────────────────────────────────────────────────────────────────┘

text

## Стадии

### 1. Build & Test

**Раннер:** `ubuntu-latest`  
**Timeout:** 20 минут  
**Триггер:** всегда

**Шаги:**

- Checkout репозитория.
- Node.js 26.2.0 (из `engines.node` в `package.json`).
- `npm ci --no-audit --no-fund` — установка зависимостей с кэшем.
- `npm run lint:js` — ESLint.
- `npm run build` — сборка Vite (frontend).
- **Core backend tests** — 10 файлов без внешних зависимостей:
  - check-translations, test-better-auth, test-cert-hostname-match,
    test-domain, test-monitor-response, test-ping-chart,
    test-status-page, test-uptime-calculator, test-util, test-util-server.
- **Full test suite** (informational, `continue-on-error`) — все тесты, включая требующие внешних сервисов (MQTT, Oracle, MariaDB).
- Выгрузка артефакта `build-dist` (7 дней хранения).

**Почему так:**  
Тесты разделены на две группы: «обязательные» и «информационные». Это позволяет CI быть строгим к критичным тестам, но не блокироваться из-за отсутствия MQTT-брокера или Oracle в облаке. Стратегия описана в разделе [Зоны роста](growth-zones.md).

### 2. SAST (Semgrep)

**Timeout:** 20 минут  
**Зависит от:** `build`  
**Права:** `security-events: write`

**Шаги:**

- Установка Python 3.12.
- `pip install semgrep` — свежая версия (актуальный способ; `returntocorp/semgrep-action@v1` устарел).
- Запуск `semgrep scan` с наборами правил:
  - `p/javascript`
  - `p/typescript`
  - `p/vue`
  - `p/nodejs`
  - `p/owasp-top-ten`
  - `p/secrets`
- Выгрузка SARIF в артефакты.
- Загрузка SARIF в GitHub Security (`Code scanning alerts`).

**Аналитика выбора:** [sast.md](sast.md).

### 3. Secrets (Gitleaks)

**Timeout:** 10 минут  
**Зависит от:** `build`

**Шаги:**

- Checkout с `fetch-depth: 0` — полная история коммитов.
- `gitleaks/gitleaks-action@v2` — сканирование всей истории.
- Выгрузка отчёта в артефакты.

**Что ищет:** токены, приватные ключи, пароли, JWT, AWS/GCP credentials.

### 4. SCA (npm audit + Trivy fs)

**Timeout:** 15 минут  
**Зависит от:** `build`

**Шаги:**

- `npm ci --ignore-scripts`
- `npm audit --omit=dev --json > npm-audit.json` — только production-зависимости.
- Trivy fs по lock-файлам с `severity: CRITICAL,HIGH,MEDIUM`.
- Выгрузка SARIF в артефакты + GitHub Security.

**Что ищет:** CVE в зависимостях npm и в lock-файлах.

### 5. Container (Hadolint + Trivy image)

**Timeout:** 30 минут  
**Зависит от:** `build`

**Шаги:**

- **Hadolint** по `docker/dockerfile` (`failure-threshold: warning`) — best-practices Dockerfile.
- `docker build --target release -f docker/dockerfile` — сборка финальной стадии (release).
- **Trivy image** по собранному образу (`severity: CRITICAL,HIGH`, `ignore-unfixed: true`).
- Выгрузка SARIF.

**Важно:** указывается `--target release`, иначе Docker пытается собрать последнюю стадию в Dockerfile (`upload-artifact`), которая требует GitHub-токен и падает. Это решение вынужденное — описано в [growth-zones.md](growth-zones.md).

### 6. Build & Push to GHCR

**Timeout:** 30 минут  
**Зависит от:** всех предыдущих  
**Триггер:** только `push` в `master`

**Шаги:**

- Логин в GHCR через `GITHUB_TOKEN` (без внешних секретов).
- `docker build --target release`.
- Теги: `latest` и `sha-<7-символов-хеша>`.
- Push в `ghcr.io/<owner-lowercase>/uptime-kuma`.

**Особенность:** имя owner приведено к нижнему регистру через `tr '[:upper:]' '[:lower:]'` — Docker registry требует lowercase.

### 7. Deploy to Staging

**Timeout:** 10 минут  
**Зависит от:** `build-and-push`  
**Триггер:** только `push` в `master`

**Шаги:**

- SSH на VPS под пользователем `deploy` (ключ из секретов GitHub).
- `docker compose pull` — скачивание образа из GHCR.
- `docker compose up -d` — перезапуск контейнера.
- **Healthcheck loop:** ждём до 30 секунд `(healthy)` в `docker compose ps`.
- Если не стал healthy — печатаем логи и exit 1.

**Секреты GitHub:**
- `VPS_HOST` — IP сервера
- `VPS_USER` — `deploy`
- `VPS_SSH_PRIVATE_KEY` — приватный SSH-ключ

**Среда GitHub:** `environment: staging`, URL: `http://89.23.97.174`.

### 8. DAST (OWASP ZAP baseline)

**Timeout:** 20 минут  
**Зависит от:** `deploy-staging`

**Шаги:**

- Ожидание доступности сервиса (`curl` до 150 сек).
- ZAP baseline scan с конфигом `.zap/rules.tsv`.
- Выгрузка отчётов: HTML, JSON, Markdown.
- Загрузка SARIF в GitHub Security.

**Аналитика:** [dast.md](dast.md).

### 9. Security Gateway

**Timeout:** 5 минут  
**Зависит от:** всех сканеров  
**Триггер:** `master` или `pull_request`

**Шаги:**

- Скачивание всех SARIF/JSON-артефактов.
- Запуск `scripts/security-gateway.sh`:
  - Парсинг SARIF (`jq`).
  - Подсчёт по severity.
  - Применение порогов: Critical ≥ 1 → FAIL, High ≥ 1 → FAIL.
  - Публикация таблицы в GitHub Step Summary.
- **Если PR** — комментарий с рекомендациями через `actions/github-script`.

**Аналитика:** [security-gateway.md](security-gateway.md).

## Управление параллелизмом

```yaml
concurrency:
  group: devsecops-${{ github.ref }}
  cancel-in-progress: true
При новом push в ту же ветку предыдущий запуск автоматически отменяется. Экономит минуты CI.

Итоговое время
Сценарий	Время
Первый прогон (без кэша)	18–25 мин
Повторный прогон (с кэшем npm)	12–15 мин
Pull Request (без deploy/DAST)	8–10 мин
Стоимость
GitHub Actions бесплатны для публичных репозиториев и до 2000 минут/мес для приватных. Наш пайплайн использует ~15 минут на прогон — при 4 прогонах в день это ~1800 минут/мес, укладываемся в бесплатный лимит.


