# DevSecOps Pipeline для Uptime Kuma

**Дипломная работа**  
**Профессия:** Специалист по информационной безопасности  
**Трек:** DevSecOps

---

## Введение

Данный проект представляет собой **полный DevSecOps-пайплайн** для open-source веб-сервиса [Uptime Kuma](https://github.com/louislam/uptime-kuma). Пайплайн покрывает весь жизненный цикл приложения — от коммита до production-деплоя — с автоматическими проверками безопасности на каждом этапе.

### Что было сделано

- Форк open-source проекта Uptime Kuma (Node.js + Vue + SQLite).
- Настроен защищённый VPS (Debian 13, UFW, Fail2Ban, SSH hardening).
- Построен CI/CD пайплайн на GitHub Actions с 9 job'ами.
- Интегрированы **8 инструментов безопасности**:
  - SAST: Semgrep, CodeQL
  - Secrets: Gitleaks
  - SCA: Trivy fs, npm audit
  - Container: Hadolint, Trivy image
  - DAST: OWASP ZAP
- Реализован **Security Gateway** с порогами и автокомментированием в PR.
- Настроен автоматический деплой на VPS с healthcheck.

---

## Архитектура

GitHub push (master)
│
▼
┌─────────────────────────────────────────────────────────────┐
│ GitHub Actions Pipeline │
│ │
│ 1. Build & Test lint, build, unit-tests │
│ 2. SAST (Semgrep) статический анализ кода │
│ 3. Secrets (Gitleaks) поиск утечек │
│ 4. SCA npm audit + Trivy fs │
│ 5. Container Hadolint + Trivy image │
│ 6. Build & Push docker build → GHCR │
│ 7. Deploy to Staging SSH → VPS → docker compose │
│ 8. DAST (ZAP baseline) скан работающего сервиса │
│ 9. Security Gateway пороги → стоп-релиз + комментарии │
└─────────────────────────────────────────────────────────────┘
│
▼
http://89.23.97.174 (Uptime Kuma на VPS)

## Стек технологий

| Компонент | Технология |
|---|---|
| Язык | Node.js 26, Vue.js 3, TypeScript |
| БД | SQLite (embedded) |
| CI/CD | GitHub Actions |
| Registry | GitHub Container Registry (GHCR) |
| Хостинг | VPS Debian 13 (Timeweb) |
| Контейнеризация | Docker, Docker Compose |
| Reverse-proxy | Docker port mapping (80:3001) |

---

## Инструменты безопасности

| Инструмент | Категория | Что проверяет |
|---|---|---|
| **Semgrep** | SAST | Уязвимости в JS/TS/Vue (OWASP Top 10) |
| **CodeQL** | SAST | Глубокий анализ Go + JS/TS (от GitHub) |
| **Gitleaks** | Secrets | Утёкшие токены, пароли, ключи |
| **npm audit** | SCA | Уязвимые зависимости npm |
| **Trivy fs** | SCA | Уязвимости в lock-файлах |
| **Trivy image** | Container | CVE в образе |
| **Hadolint** | Container | Best-practices Dockerfile |
| **OWASP ZAP** | DAST | Сканирование работающего сервиса |

---

## Security Gateway

Финальный job `security-gateway`:

- Парсит SARIF-отчёты всех сканеров.
- Считает уязвимости по severity.
- Применяет пороги:

  | Severity | Порог | Действие |
  |---|---|---|
  | Critical | ≥ 1 | ❌ Блокирует merge |
  | High | ≥ 1 | ❌ Блокирует merge |
  | Medium | ≥ 1 | ⚠️ Warn |
  | Low / Info | — | 📝 Информационно |

- Публикует summary в **GitHub Step Summary**.
- **Комментирует PR** с рекомендациями.

---

## Структура репозитория

uptime-kuma/
├── .github/
│ └── workflows/
│ └── devsecops.yml ← основной пайплайн
├── .zap/
│ └── rules.tsv ← правила ZAP
├── scripts/
│ └── security-gateway.sh ← логика порогов
├── docs/ ← документация диплома
│ ├── README.md ← этот файл
│ ├── ci-cd.md
│ ├── sast.md
│ ├── dast.md
│ ├── security-checks.md
│ ├── security-gateway.md
│ └── growth-zones.md
├── docker/
│ └── dockerfile ← сборка образа
├── server/ ← Node.js backend
├── src/ ← Vue.js frontend
└── package.json

## Документация

- [CI/CD Pipeline](ci-cd.md) — обзор стадий, инструменты, схема.
- [SAST](sast.md) — Semgrep + CodeQL, аналитика выбора.
- [DAST](dast.md) — OWASP ZAP baseline.
- [Security Checks](security-checks.md) — Gitleaks, Trivy, Hadolint.
- [Security Gateway](security-gateway.md) — пороги, логика, PR-комментарии.
- [Зоны роста](growth-zones.md) — что можно улучшить.

---

## Результаты

- **9 job'ов** в пайплайне — все зелёные.
- **Critical / High:** 0 / 0 — релиз разрешён.
- **Medium / Low:** 92 / 40 — информационные (в основном в базовом Docker-образе).
- **Автодеплой** работает end-to-end.
- **Security Gateway** блокирует релиз при Critical/High.
- **PR-комментарии** публикуют рекомендации автоматически.

---

## Ссылки

- **Репозиторий:** https://github.com/Oleg-devsecops/uptime-kuma
- **Staging:** http://89.23.97.174
- **GHCR:** https://github.com/Oleg-devsecops?tab=packages
- **Security Alerts:** https://github.com/Oleg-devsecops/uptime-kuma/security/code-scanning
- **Upstream:** https://github.com/louislam/uptime-kuma

---

**Автор:** Олег Богдашкин  
**Дата:** 11 октября 2026
---

## Полный список документов

| Документ | Что описывает |
|---|---|
| [README.md](README.md) | Обзор проекта, архитектура, результаты |
| [ci-cd.md](ci-cd.md) | Все 9 стадий пайплайна: инструменты, конфиги, обоснования |
| [sast.md](sast.md) | Semgrep + CodeQL, аналитика выбора, сравнение |
| [dast.md](dast.md) | OWASP ZAP baseline, конфигурация, результаты сканирования |
| [security-checks.md](security-checks.md) | Gitleaks, Trivy fs/image, Hadolint, npm audit |
| [security-gateway.md](security-gateway.md) | Пороги, стоп-релиз, автокомментирование в PR |
| [growth-zones.md](growth-zones.md) | Честный анализ ограничений и план улучшений |

---

## Итоговые результаты

### Технические

- **9 job'ов** в CI/CD пайплайне — все зелёные.
- **8 инструментов безопасности** интегрированы.
- **0 Critical, 0 High** на момент последнего прогона.
- **Автодеплой** работает end-to-end (коммит → GHCR → VPS).
- **Security Gateway** блокирует релиз при Critical/High.
- **PR-комментарии** с рекомендациями работают.

### Документация

- **7 документов** (этот + 6 остальных) покрывают все аспекты.
- **~1500 строк** markdown-описания.
- Все решения обоснованы с аналитикой.

### Инфраструктура

- **VPS:** Debian 13 (Trixie), UFW, Fail2Ban, SSH hardening.
- **Пользователи:** `diploma` (админ), `deploy` (CI/CD, без sudo).
- **Контейнеризация:** Docker + Docker Compose.
- **Registry:** GitHub Container Registry (публичный образ).

---

## Демонстрация для защиты

Если нужно показать работу в реальном времени:

### 1. Push нового коммита

```bash
cd ~/uptime-kuma
echo "" >> docs/README.md
git add docs/README.md
git commit -m "docs: trigger full pipeline demo"
git push origin master
2. Наблюдение за pipeline
text
https://github.com/oleg-devsecops/uptime-kuma/actions
Все 9 job'ов пройдут за ~13 минут.

3. Проверка деплоя
text
http://89.23.97.174
Сервис обновляется автоматически.

4. Проверка PR-комментариев
Создай тестовую ветку, открой PR в свой форк — Security Gateway прокомментирует.

Ссылки на защиту
Репозиторий: https://github.com/Oleg-devsecops/uptime-kuma

Actions: https://github.com/Oleg-devsecops/uptime-kuma/actions/workflows/devsecops.yml

Security Dashboard: https://github.com/Oleg-devsecops/uptime-kuma/security/code-scanning

Packages (GHCR): https://github.com/Oleg-devsecops?tab=packages

Staging: http://89.23.97.174

Благодарности
Проект основан на Uptime Kuma — open-source uptime-мониторинге от Louis Lam и сообщества. Дипломная работа выполнена как форк с полной переработкой CI/CD в DevSecOps-парадигму.
