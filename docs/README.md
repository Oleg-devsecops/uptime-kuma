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
