# SAST — Static Application Security Testing

## Что это

**SAST** — статический анализ исходного кода без его запуска. Ищет уязвимости в коде: SQL-инъекции, XSS, небезопасные крипто-операции, утечки данных, ошибки конфигурации.

В нашем пайплайне используется **два инструмента SAST**, которые дополняют друг друга:

1. **Semgrep** — кастомный анализ с гибкими правилами.
2. **CodeQL** — глубокий семантический анализ от GitHub.

---

## Semgrep

### Что это

[Semgrep](https://semgrep.dev/) — легковесный SAST-инструмент с открытым исходным кодом. Работает по принципу «поиска паттернов» в AST (абстрактном синтаксическом дереве), а не просто по регулярным выражениям.

### Почему Semgrep

| Критерий | Semgrep | SonarQube | Bandit |
|---|---|---|---|
| Лицензия | LGPL 2.1 (open-source) | LGPL (Community) / коммерческая | MIT |
| Установка | `pip install semgrep` | Требует сервера + БД | `pip install bandit` |
| Языки | 30+ (JS, TS, Vue, Python, Go, Java...) | 30+ | Только Python |
| Поддержка Vue | ✅ `p/vue` | ✅ | ❌ |
| Скорость | Секунды | Минуты | Секунды |
| Кастомные правила | ✅ Простой YAML | ✅ | ✅ |
| Интеграция в CI | Один шаг | Сложнее | Простая |

**Вывод:** Semgrep — оптимальный выбор для CI:
- Не требует инфраструктуры (запускается как CLI).
- Поддерживает Vue (наш frontend).
- Официальные правила от OWASP, JavaScript, TypeScript, Node.js.

### Настройка в пайплайне

```yaml
- name: Setup Python
  uses: actions/setup-python@v5
  with:
    python-version: '3.12'

- name: Install Semgrep
  run: pip install semgrep

- name: Run Semgrep
  run: |
    semgrep scan \
      --config=p/javascript \
      --config=p/typescript \
      --config=p/vue \
      --config=p/nodejs \
      --config=p/owasp-top-ten \
      --config=p/secrets \
      --sarif \
      --output=semgrep.sarif \
      --metrics=off \
      || true
Наборы правил
Набор	Что проверяет
p/javascript	Типичные ошибки JavaScript
p/typescript	Правила для TS
p/vue	Специфика Vue.js
p/nodejs	Node.js: небезопасные API, child_process, path traversal
p/owasp-top-ten	OWASP Top 10: SQLi, XSS, CSRF и др.
p/secrets	Подозрительные строки, похожие на секреты
Результаты первого запуска
На коде Uptime Kuma Semgrep нашёл в основном Medium-находки:

Использование eval() в собранном Vue-бандле (не в исходниках).

Отсутствие некоторых проверок ввода.

Возможные path traversal в местах работы с файлами.

Все находки выгружаются в SARIF и попадают в GitHub Security → Code scanning alerts.

CodeQL
Что это
CodeQL — семантический анализатор от GitHub. Строит граф данных всего проекта и ищет пути от источников (user input) до стоков (SQL, файловая система, ответ HTTP). Это позволяет находить реальные уязвимости, а не паттерны.

Почему CodeQL
Глубокий анализ — связывает данные между файлами и функциями.

Минимальные ложные срабатывания — по сравнению с pattern-based SAST.

Бесплатно для публичных репозиториев.

Нативная интеграция с GitHub Security.

Настройка
Workflow codeql-analysis.yml уже присутствует в upstream-проекте:

yaml
strategy:
  fail-fast: false
  matrix:
    language: ["go", "javascript-typescript"]
CodeQL анализирует два языка:

Go — healthcheck-утилита внутри проекта.

JavaScript/TypeScript — весь frontend (Vue) + backend (Express).

Мы не дублируем его в devsecops.yml — CodeQL запускается отдельным workflow и дополняет Semgrep.

Триггеры
push в master и 1.23.X (branch upstream).

pull_request в те же ветки.

Раз в сутки по расписанию (cron: "16 22 * * 0").

Плюс: CodeQL — один из немногих инструментов, работающих и на форках, потому что он не требует специальных секретов (в отличие от build-docker-push.yml, где условие if: github.repository == 'louislam/uptime-kuma' его отключает).

Semgrep vs CodeQL — почему оба
Аспект	Semgrep	CodeQL
Тип анализа	Pattern-based + AST	Data-flow + taint analysis
Сложность настройки	Минимальная	Средняя
Скорость	Секунды	Минуты
Ложные срабатывания	Больше	Меньше
Кастомные правила	YAML, простые	QL, сложный язык
Секреты в коде	✅	❌
OWASP Top 10	✅	✅
Data-flow	Ограниченный	✅ Полный
Стратегия: Semgrep даёт широкое покрытие и быстрый фидбек, CodeQL — точные находки через анализ потока данных. Вместе они покрывают весь спектр SAST.

Интеграция с Security Gateway
Оба инструмента выгружают SARIF. В security-gateway.sh:

bash
count_sarif "semgrep.sarif" "Semgrep"
Функция читает SARIF через jq:

bash
critical=$(jq '[.runs[].results[]? | select(.level=="error") | 
  select(.properties.severity? // "" | ascii_downcase == "critical")] | length' "$file")
На основе этих данных gateway применяет пороги:

Critical ≥ 1 → ❌ блокирует релиз.

High ≥ 1 → ❌ блокирует релиз.

Medium ≥ 1 → ⚠️ warn (не блокирует).

Примеры найденных уязвимостей
На момент написания диплома:

Semgrep: 0 Critical, 0 High, ~20 Medium (в основном в собранном dist/index-XXX.js).

CodeQL: 0 открытых алертов в Code scanning.

Важно: критичных уязвимостей в коде Uptime Kuma не обнаружено — это ожидаемо, проект зрелый и поддерживается сообществом.

Все находки доступны по адресу:

text
https://github.com/Oleg-devsecops/uptime-kuma/security/code-scanning
Ограничения и зоны роста
Semgrep не видит runtime-контекст — может флажить безопасные паттерны как уязвимости.

CodeQL требует autobuild — для нашего проекта работает, но для больших может не справляться.

Оба инструмента не находят логические уязвимости (например, авторизационные баги) — это только DAST + ручное ревью.

Secrets-правила Semgrep дополняют, но не заменяют Gitleaks (Gitleaks ищет в коммитах и истории).

Подробнее — в growth-zones.md.

Ссылки
Semgrep: https://semgrep.dev/

Правила Semgrep Registry: https://semgrep.dev/explore

CodeQL: https://codeql.github.com/

OWASP Top 10: https://owasp.org/Top10/

SARIF: https://sarifweb.azurewebsites.net/
