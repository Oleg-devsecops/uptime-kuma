# Зоны роста и ограничения

Честный анализ того, что **не идеально** в текущей реализации и что стоит улучшить в следующих итерациях. Этот раздел — важная часть инженерной практики: понимать границы решения и видеть путь развития.

---

## 1. Проблемы, выявленные в процессе

### 1.1. Dockerfile запускает `server.js` без tsx-загрузчика

**Симптом:** контейнер циклически перезапускается с ошибкой:
Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/app/src/util'
imported from /app/server/server.js

text

**Причина:** Upstream Dockerfile содержит `CMD ["node", "server/server.js"]`, но `server.js` использует ESM-импорты из `.ts`-файлов (`../src/util`). Node.js не может разрешить `.ts` без загрузчика `tsx`.

**Обход:** в `docker-compose.yml` на VPS добавлен `command`:

```yaml
command: ["node", "--import=tsx", "server/server.js"]
Правильное решение: изменить CMD в Dockerfile:

dockerfile
CMD ["node", "--import=tsx", "server/server.js"]
или добавить стадию сборки TypeScript → JavaScript, чтобы на выходе был чистый JS без tsx-требований.

Что мешает сейчас: изменение Dockerfile форка может конфликтовать с upstream при merge. Обход через docker-compose.yml локален и не трогает репозиторий.

1.2. Frontend dist/ не собирается в образе
Симптом: после сборки образа контейнер падает:

text
Error: Cannot find 'dist/index.html', did you install correctly?
Причина: Upstream Dockerfile рассчитан на то, что dist/ собирается вне образа (в их CI на раннере), а потом копируется в контекст docker build. Мы используем «чистый» docker build — в контексте нет dist/.

Решение в форке: модифицирован docker/dockerfile:

diff
- RUN npm ci --omit=dev
+ RUN npm ci
  COPY . .
+ RUN npm run build
  RUN mkdir ./data
Плюс добавлено:

npm ci вместо npm ci --omit=dev — нужны devDependencies (vite).

RUN npm run build — сборка frontend прямо в образе.

Минусы решения:

Образ содержит dev-зависимости — размер вырос на ~200 МБ.

Сборка стала дольше на ~3–5 минут.

Правильное решение: multi-stage сборка:

dockerfile
# Стадия сборки frontend (с devDeps)
FROM louislam/uptime-kuma:base3 AS build-frontend
USER node
WORKDIR /app
COPY --chown=node:node package*.json .npmrc ./
RUN npm ci
COPY --chown=node:node . .
RUN npm run build

# Стадия production (только prod deps + dist)
FROM louislam/uptime-kuma:base3 AS release
USER node
WORKDIR /app
COPY --chown=node:node package*.json package-lock.json .npmrc ./
RUN npm ci --omit=dev
COPY --chown=node:node --from=build-frontend /app/dist ./dist
COPY --chown=node:node server ./server
COPY --chown=node:node src ./src
# ...
Что мешает сейчас: multi-stage усложняет Dockerfile, а в рамках диплома важно минимизировать изменения upstream. Оставлено как задача для следующих итераций.

1.3. Docker Hub rate limit ломает миграционные тесты
Симптом: тесты test-migration.js и test-migration-v2-to-v3.ts падают с:

text
Error: (HTTP code 500) server error - toomanyrequests: 
You have reached your unauthenticated pull rate limit.
Причина: эти тесты запускают контейнеры MariaDB и MySQL через Docker. GitHub Actions не аутентифицирован в Docker Hub — лимит 100 pulls / 6 часов для анонимных пользователей. Общий IP-пул раннеров уже исчерпал лимит.

Обход: миграционные тесты исключены из «обязательной» группы в CI. Они остаются в test-backend (full suite, informational).

Правильное решение:

Аутентификация в Docker Hub через секреты GitHub (DOCKERHUB_USERNAME / DOCKERHUB_TOKEN) — лимит вырастет до 200 pulls / 6 часов.

Или переход на ghcr.io — там лимиты мягче.

Или использование сервисных контейнеров GitHub Actions (services:) — они уже кэшированы.

Для диплома: сохранение «informational» статуса достаточно. Полное покрытие — задача для production-пайплайна.

1.4. returntocorp/semgrep-action@v1 устарел
Симптом: job SAST падает с Docker pull failed with exit code 1.

Причина: разработчик (r2c) перестал поддерживать action, встроенный Docker-образ не загружается.

Решение: замена на pip install semgrep + прямой вызов semgrep scan. Это актуальный подход.

1.5. docker/setup-buildx-action не загружает buildkit
Симптом: job Container падает:

text
Error: failed to solve: ... auth.docker.io/token ... 
net/http: request canceled (Client.Timeout exceeded)
Причина: buildx пытается скачать moby/buildkit:buildx-stable-1 из Docker Hub, но IP-пул GitHub Actions исчерпал лимит.

Решение: замена buildx на обычный docker build + docker push:

yaml
- name: Build and push image to GHCR
  run: |
    docker build --target release -f docker/dockerfile \
      -t $IMAGE:latest -t $IMAGE:sha-$SHA_SHORT .
    docker push $IMAGE:latest
    docker push $IMAGE:sha-$SHA_SHORT
Минусы: потеряли кэш слоёв (cache-from/to: type=gha). Сборка стала дольше на ~30–50%.

Правильное решение: использовать GitHub Actions Cache для Docker через docker/build-push-action с ретраями, либо self-hosted runner с локальным кэшем.

1.6. GHCR требует lowercase в имени owner
Симптом: push в GHCR падает:

text
invalid tag "ghcr.io/Oleg-devsecops/uptime-kuma:latest": 
repository name must be lowercase
Причина: GitHub username Oleg-devsecops содержит заглавную O, а Docker registry требует lowercase.

Решение: приведение через bash:

bash
OWNER_LOWER=$(echo "$REPO_OWNER" | tr '[:upper:]' '[:lower:]')
IMAGE=ghcr.io/${OWNER_LOWER}/uptime-kuma
2. Ограничения текущей реализации
2.1. Cache зависимостей не полный
Сейчас используется actions/setup-node@v4 с cache: npm — кэшируется npm-кэш, но не node_modules. Для каждого прогона npm ci ставит с нуля, только скорость скачивания выше.

Что можно улучшить: кэш всего node_modules через actions/cache@v4. Даст выигрыш 30–60 секунд на прогон.

2.2. DAST сканирует только unauthenticated-поверхность
ZAP baseline не логинится в Uptime Kuma. Значит, часть эндпоинтов (/dashboard, /settings) не сканируется — ZAP получает 302-редирект на /setup или /login.

Что можно улучшить: ZAP Context с настройкой аутентификации:

yaml
- name: ZAP with auth
  uses: zaproxy/action-baseline@v0.12.0
  with:
    target: http://89.23.97.174
    context_file: .zap/context.context
    auth_script: .zap/auth.js
Это позволит просканировать закрытые разделы. Требует сохранения тестового пользователя в secrets.

2.3. Security Gateway пороги — статичные
Сейчас пороги жёстко заданы:

bash
THRESHOLD_CRITICAL=1
THRESHOLD_HIGH=1
Что можно улучшить:

Вынести в отдельный security-policy.yaml с градациями по типу проекта.

Разные пороги для master / PR / feature-ветки.

Baseline suppression: если вчера было 3 High, а сегодня 5 — блокировать только рост.

2.4. Нет SBOM
SBOM (Software Bill of Materials) — формальный список всех компонентов и зависимостей. Требуется в некоторых регуляторных стандартах (например, US Executive Order 14028, PCI DSS 4.0).

Что можно улучшить: генерация SBOM через:

Syft — от авторов Grype.

Trivy — уже умеет (trivy image --format cyclonedx).

cdxgen — от IBM.

Добавление SBOM в артефакты — простая задача, но потребует форматирования под CycloneDX или SPDX.

2.5. Нет подписи образов
GHCR-образ не подписан. В production нужно:

Cosign — подпись + верификация.

Notation — альтернатива от Microsoft.

SLSA Level 3 — цепочка поставки.

Добавление Cosign займёт ~10 строк в workflow + хранение ключа в секретах.

2.6. Нет fuzzing / property-based testing
Тесты Uptime Kuma — детерминированные. Отсутствует:

Fuzzing — случайные входные данные.

Property-based testing — например, через fast-check.

Mutation testing — Stryker.

Эти инструменты ловят уязвимости, которые SAST/DAST пропускают.

2.7. Нет IAST
IAST (Interactive AST) — гибрид SAST и DAST, работает внутри приложения во время тестов. Примеры:

Contrast Security (коммерческий)

CodeLogic (коммерческий)

Open-source: пока нет зрелых инструментов.

Пропущено сознательно — на момент написания диплома зрелых open-source IAST нет.

3. Ограничения архитектуры
3.1. Один сервер — единая точка отказа
VPS 89.23.97.174 — и staging, и production (в нашем случае одно и то же). Если упадёт:

Сервис недоступен.

CI не может деплоить.

Нет rollback.

Что можно улучшить:

Второй VPS + load balancer.

Или переезд на Kubernetes (GKE, EKS) с автоскейлом.

Или managed PaaS (Fly.io, Render) для простоты.

3.2. Нет монторинга и алертинга
Отсутствуют:

Prometheus + Grafana — метрики.

Loki / ELK — логи.

Alertmanager — алерты.

Sentry — error tracking.

При инциденте не будет данных для post-mortem.

3.3. Секреты в GitHub — базовый уровень
Используются Repository secrets — общие для всего репозитория. Для production нужны:

Environment secrets — отдельные для staging/production.

OIDC — отказ от долгоживущих токенов (Vault, AWS IAM).

Sealed Secrets / SOPS — для секретов внутри кластера.

3.4. Логи CI не агрегируются
Логи GitHub Actions хранятся 90 дней, но не индексируются. Для аудита и compliance нужен:

S3-bucket с экспортом логов.

Datadog / Splunk для поиска.

4. Что не покрыто намеренно
4.1. Penetration testing
Полноценный pentest — ручная работа опытного специалиста. DAST заменяет его частично, но не полностью.

4.2. Red team / blue team
Имитация APT-атак, social engineering, физический доступ — вне рамок диплома.

4.3. Compliance-фреймворки
SOC 2, ISO 27001, PCI DSS требуют процессов (управление доступами, аудит, риск-менеджмент), которые не автоматизируются.

4.4. Защита от supply chain-атак
Атаки на зависимые пакеты (например, известный инцидент с event-stream, colors.js) требуют:

Verified Publishers (npm provenance).

Lockfile review.

Dependency Confusion prevention.

Часть покрыта npm audit и Trivy, но глубокой защиты нет.

5. Метрики для оценки зрелости
Метрика	Текущее	Целевое
Покрытие SAST	80%	95%
Time-to-detect (уязвимость)	< 10 мин	< 5 мин
Time-to-remediate (Critical)	—	< 24 ч
Покрытие DAST	60% (без auth)	90% (с auth)
Покрытие SBOM	0%	100%
Подпись образов	нет	есть
MTTR инцидентов	—	< 1 ч
Кол-во security-jobs	9	12+
6. Приоритизация улучшений
По принципу MoSCoW для следующей итерации:

Must have
Multi-stage Dockerfile — уменьшение размера образа.

Cosign подпись GHCR-образов.

Аутентифицированный DAST — покрытие /dashboard.

Should have
SBOM (CycloneDX) в артефактах.

SBOM diff — сравнение с предыдущей версией.

Prometheus + Grafana — метрики сервиса.

Could have
Fuzzing через OSS-Fuzz или собственный.

SLSA Level 3 — цепочка поставки.

Multi-region deploy.

Won't have (в рамках диплома)
Compliance-фреймворки — вне технической части.

Red team — вне автоматизации.

IAST — нет зрелых open-source решений.

7. Итог
Пайплайн покрывает весь жизненный цикл приложения от коммита до production-деплоя с 8 инструментами безопасности. Все обязательные требования диплома выполнены:

✅ SAST — Semgrep + CodeQL.

✅ DAST — OWASP ZAP baseline.

✅ Secrets — Gitleaks.

✅ Security checks — Trivy, Hadolint, npm audit.

✅ Security Gateway — пороги, стоп-релиз, комментарии в PR.

✅ Документация процесса — этот раздел + остальные документы.

Зоны роста сформулированы реалистично и приоритизированы по MoSCoW. Часть из них — работа на следующую итерацию, часть — вне scope диплома.

Такой подход — инженерно зрелый: показать не только что сделано, но и что осознанно не сделано, и почему.
