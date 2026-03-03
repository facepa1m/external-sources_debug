# NoveLA Lua Plugin Guide — Полное руководство (v4)

> **Цель:** Самодостаточный документ. Имея только его, можно написать полнофункциональный плагин без доступа к исходному коду. Основан на анализе 27 нативных источников, изучении LuaSourceLoader.kt и реальном опыте отладки.
>
> **v4:** Добавлены `string_clean` (normalize + collapse whitespace + trim) и `http_get_batch` (параллельная загрузка страниц глав). Обновлены Best Practices, антипаттерны, раздел списка глав.
>
> **v3:** Обновлена архитектура настроек (фабрика + подкласс), `google_translate` получил обязательный аргумент `origin`, язык `"mul"` отображается как "Multilanguage" через `getLanguageDisplayName`, иконка плагина: YAML приоритетнее Lua.

---

## Содержание

1. [Чеклист разработки](#1-чеклист-разработки)
2. [Архитектура и жизненный цикл](#2-архитектура-и-жизненный-цикл)
3. [Критические правила LuaJ](#3-критические-правила-luaj)
4. [Анализ сайта — Decision Tree](#4-анализ-сайта--decision-tree)
5. [Структура файла плагина](#5-структура-файла-плагина)
6. [Глобальное Lua API — Полный справочник](#6-глобальное-lua-api--полный-справочник)
7. [Cover-трансформации (обязательно читать)](#7-cover-трансформации-обязательно-читать)
8. [Реализация каталога и поиска](#8-реализация-каталога-и-поиска)
9. [Реализация деталей книги](#9-реализация-деталей-книги)
10. [Реализация списка глав](#10-реализация-списка-глав)
11. [Реализация текста главы](#11-реализация-текста-главы)
12. [Настройки плагина (getSettingsSchema)](#12-настройки-плагина-getsettingsschema)
13. [Паттерны и сценарии](#13-паттерны-и-сценарии)
14. [Best Practices](#14-best-practices)
15. [Антипаттерны и частые ошибки](#15-антипаттерны-и-частые-ошибки)
16. [Отладка и логирование](#16-отладка-и-логирование)
17. [Регистрация плагина](#17-регистрация-плагина)

---

## 1. Чеклист разработки

- [ ] **Шаг 1: Анализ сайта.** Chrome DevTools (F12). URL каталога, пагинация, AJAX, кодировка.
- [ ] **Шаг 2: Файл.** `lang/source_id.lua`
- [ ] **Шаг 3: Метаданные.** `id`, `name`, `baseUrl`, `language`, `icon`, `version`.
- [ ] **Шаг 4: URL-хелпер.** Реализовать `absUrl()` для resolve относительных ссылок.
- [ ] **Шаг 5: Cover-трансформация.** Миниатюры → полный размер, прокси если нужно.
- [ ] **Шаг 6: Каталог и поиск.** `getCatalogList` + `getCatalogSearch` с `hasNext`.
- [ ] **Шаг 7: Книга.** `getBookTitle`, `getBookCoverImageUrl`, `getBookDescription`.
- [ ] **Шаг 8: Главы.** `getChapterList` (oldest-first) + `getChapterText`.
- [ ] **Шаг 9: Чистка текста.** Реклама, скрипты, навигация.
- [ ] **Шаг 10 (опц.): Настройки.** `getSettingsSchema()` если плагин требует конфигурации.
- [ ] **Шаг 11: Регистрация.** `index.yaml` + иконка.

---

## 2. Архитектура и жизненный цикл

Приложение загружает `.lua` через LuaJ. Скрипт выполняется — все top-level переменные и функции регистрируются в `globals`. Адаптер читает из globals по имени.

**Важно:** адаптер передаёт `cover` в UI **без каких-либо трансформаций** — `coverImageUrl = table.get("cover").optjstring("")`. Вся логика URL обложки целиком на стороне плагина.

```
1. Загрузка  → globals["id"], globals["name"], globals["baseUrl"], ...
2. Каталог   → getCatalogList(0), getCatalogList(1), ... пока hasNext=true
3. Поиск     → getCatalogSearch(0, query), ...
4. Книга     → getBookTitle(url) + getBookDescription(url) + getBookCoverImageUrl(url)
5. Главы     → getChapterList(url)     -- oldest-first
6. Чтение    → приложение скачивает HTML → getChapterText(html, url)
               ВАЖНО: второй аргумент url добавлен в v2 — используй его!
7. Обновления → getChapterListHash(url) -- любая строка меняющаяся при новых главах
8. Настройки → getSettingsSchema()      -- схема UI (необязательно)
```

---

## 3. Критические правила LuaJ

> LuaJ = **Lua 5.1**. Нарушение → `LuaError: attempt to index ? (a nil value)`.

### Правило 1: Только top-level функции, НЕ `return {}`

```lua
-- НЕВЕРНО — адаптер ищет функции в globals, return{} их туда не кладёт
return { getCatalogList = function(index) ... end }

-- ВЕРНО
function getCatalogList(index) ... end
```

### Правило 2: Поля и методы элемента

`html_select` / `html_select_first` возвращают таблицу. Поля — через `.`, Java-методы — через `:`.

```lua
-- ПОЛЯ (через точку):
el.text    -- текст элемента
el.html    -- внутренний HTML (передавать в html_select/html_text)
el.href    -- абсолютный URL из href
el.src     -- абсолютный URL из src
el.title   -- атрибут title
el.class   -- атрибут class
el.id      -- атрибут id

-- МЕТОДЫ (через двоеточие, зарегистрированы из Java — РАБОТАЮТ):
el:attr("data-src")        -- любой атрибут по имени
el:select("css selector")  -- поиск внутри элемента → массив
el:get_text()              -- = el.text
el:get_html()              -- = el.html
el:remove()                -- удалить из DOM (полезно внутри :select цикла)
```

```lua
-- html_attr — удобная функция без нужды в объекте элемента
local val = html_attr(html_string, "css selector", "attr_name")
-- Возвращает "" если не найдено, НИКОГДА не nil
```

### Правило 3: Нативные строковые методы только на локальных переменных

```lua
-- НЕВЕРНО — e.text это Java-объект, не Lua string
local found = e.text:find("pattern")

-- ВЕРНО — сначала сохранить в переменную
local t = e.text
local found = t:find("pattern")

-- ВЕРНО — использовать API
local m = regex_match(e.text, "pattern")
```

### Правило 4: `goto` не работает в LuaJ

```lua
-- НЕВЕРНО
goto continue

-- ВЕРНО — условный блок
if condition then ... end
```

### Правило 5: `tostring()` для чисел в конкатенации

```lua
log_error("code=" .. tostring(r.code))
```

### Правило 6: `regex_match` vs `string.match`

```lua
-- regex_match возвращает массив ПОЛНЫХ совпадений всего паттерна:
local m = regex_match("/novel/12345/", "/(%d+)/")
-- m[1] = "/12345/"   ← полное совпадение, НЕ capture group!

-- Для capture groups используй нативный Lua string.match:
local id = string.match("/novel/12345/", "/(%d+)/")
-- id = "12345"   ← правильно

-- regex_match полезен когда нужны ВСЕ совпадения паттерна:
local nums = regex_match("1,2,3,4", "%d+")
-- nums[1]="1", nums[2]="2", nums[3]="3", nums[4]="4"
```

### Правило 7: getChapterText получает два аргумента (v2)

```lua
-- ВЕРНО (v2) — второй аргумент url теперь всегда передаётся адаптером
function getChapterText(html, url)
  -- используй url для API-запросов вместо парсинга из HTML
end

-- УСТАРЕВШИЙ стиль (работает, но url придётся искать самому)
function getChapterText(html)
  local url = html_attr(html, "link[rel='canonical']", "href")
end
```

---

## 4. Анализ сайта — Decision Tree

**Контент:**
- Чистый HTML → `http_get` + `html_select`
- JSON API → `http_get` + `json_parse`
- API + шифрование → `http_post` к прокси или `aes_decrypt`
- Требует перевода → `google_translate` + постобработка

**Пагинация каталога:**
- `?page=1` — большинство сайтов
- `?offset=0&limit=20` — API
- URL-паттерн: `novels_0_0_1.htm`

**Список глав:**
- Всё на странице → парсить HTML
- Paginated HTML (≤10 стр.) → цикл `?page=N` с `sleep(300)`
- Paginated HTML (10+ стр.) → **`http_get_batch`** — параллельная загрузка
- AJAX GET → отдельный запрос с ID (WtrLab: `/api/chapters/{novelId}`)
- AJAX POST → WordPress `admin-ajax.php`
- JSON API → REST-эндпоинт с томами

**Кодировка:**
- Китайские сайты → `charset = "GBK"` везде
- GBK поиск → `url_encode_charset(query, "GBK")`

**Обложки:**
- Миниатюра в каталоге → трансформировать URL
- Hotlink-защита → прокси wsrv.nl

---

## 5. Структура файла плагина

```lua
-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "source_id"
name     = "Source Name"
version  = "1.0.0"
baseUrl  = "https://example.com/"
language = "en"    -- ISO 639-1: en, ru, zh, es, de, fr, it, pl, id, tr
               -- Для MTL: language = "MTL"  → отображается как "MTL"
icon     = "https://..."

-- ── URL-хелпер (рекомендуется всегда) ────────────────────────────────────────
local function absUrl(href)
  if href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

-- ── applyStandardContentTransforms (копировать в каждый плагин) ──────────────
local function applyStandardContentTransforms(text)
  if not text or text == "" then return "" end
  text = string_normalize(text)
  local domain = baseUrl:gsub("https?://", ""):gsub("^www%.", ""):gsub("/$", "")
  text = regex_replace(text, "(?i)" .. domain .. ".*?\\n", "")
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = regex_replace(text, "(?im)^\\s*(Перевод|Переводчик|Редакция|Редактор|Аннотация|Сайт|Источник|Студия)[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = regex_replace(text, "(?im)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = string_trim(text)
  return text
end

-- ── Cover-хелперы (по необходимости) ─────────────────────────────────────────
local function transformCover(coverUrl) ... end

-- ── Local вспомогательные функции ────────────────────────────────────────────
local function helper() ... end

-- ── Обязательные функции (top-level) ─────────────────────────────────────────
function getCatalogList(index) ... end
function getCatalogSearch(index, query) ... end
function getBookTitle(bookUrl) ... end
function getBookCoverImageUrl(bookUrl) ... end
function getBookDescription(bookUrl) ... end
function getChapterList(bookUrl) ... end
function getChapterText(html, url) ... end  -- url — второй аргумент (v2)

-- ── Необязательные функции ───────────────────────────────────────────────────
function getChapterListHash(bookUrl) ... end
function getSettingsSchema() ... end   -- настройки плагина (см. раздел 12)
```

### Форматы возврата

**getCatalogList / getCatalogSearch:**
```lua
return {
  items = {
    { title = "Title", url = "https://...", cover = "https://..." },
  },
  hasNext = true
}
```

**getChapterList:**
```lua
return {
  { title = "Chapter 1", url = "https://...", volume = "Vol.1" },  -- volume необязателен
}
-- Порядок: oldest → newest
```

**getChapterText:**
```lua
return "<p>Paragraph 1</p>\n<p>Paragraph 2</p>"
-- html_text() возвращает правильный формат автоматически
```

---

## 6. Глобальное Lua API — Полный справочник

### Networking

```lua
local r = http_get(url)
local r = http_get(url, { headers = { ["Referer"] = baseUrl }, charset = "GBK" })
-- r.success (bool), r.body (string), r.code (int)

local r = http_post(url, body, { headers = { ["Content-Type"] = "application/json" } })
local r = http_post(url, "key=val", {
  charset = "GBK",
  headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
})
```

-- Параллельная загрузка нескольких URL (v4) ───────────────────────────────────
local results = http_get_batch(urls_table)
-- urls_table  — Lua-массив строк { "https://...", "https://...", ... }
-- results     — Lua-массив { success, body, code } в том же порядке что urls_table
-- Запросы выполняются параллельно через OkHttp connection pool
-- НЕ передавай headers/charset — только URL строки
-- НЕ нужен sleep перед вызовом — запросы не блокируют друг друга
```

### HTML (Jsoup)

```lua
-- Массив элементов
local els = html_select(html_or_element, "css selector")

-- Первый или nil
local el = html_select_first(html_or_element, "css selector")

-- Атрибут без объекта (возвращает "" если нет)
local val = html_attr(html_string, "selector", "attr_name")

-- Текст с правильными абзацами
local text = html_text(html_or_element)

-- Удаление элементов → очищенный HTML
local cleaned = html_remove(html, "script", ".ads", "h3")

-- Парсинг → { text, html, title, body }
local doc = html_parse(html_string)

-- Поля элемента: el.text, el.html, el.href, el.src, el.title, el.class, el.id
-- Методы элемента: el:attr("name"), el:select("sel"), el:remove(), el:get_text()
```

**CSS-селекторы (Jsoup):**
```
.class, #id, tag, tag.class
a[href], img[src], meta[property='og:image']
div#catalog, ul#list
.parent > .child
li:nth-child(2), li:last-child
a:contains(Next)
.sm\\:text-lg   -- экранирование : в классах
```

### JSON / URL / String

```lua
json_parse(str)          -- string → lua table
json_stringify(val)      -- lua value → string

url_encode(str)                    -- UTF-8
url_encode_charset(str, "GBK")     -- нестандартная кодировка
url_resolve(base, relative)        -- абсолютный URL

regex_match(text, pattern)         -- массив ПОЛНЫХ совпадений
regex_replace(text, pattern, repl) -- замена (Kotlin Regex)
string.match(text, "(pattern)")    -- нативный Lua, capture groups
string_trim(str)
string_normalize(str)              -- NFKC Unicode
string_clean(str)                  -- normalize + collapse whitespace + trim (v4)
string_split(str, sep)             -- → массив
string_starts_with(str, prefix)
string_ends_with(str, suffix)
unescape_unicode(str)              -- \uXXXX → символы
```

### Прочее

```lua
base64_decode(str)
base64_encode(str)
aes_decrypt(b64, key, iv)          -- AES/CBC/PKCS5

google_translate(text, sourceLang, targetLang [, origin])
-- sourceLang: "zh-CN", "en", "ru", etc.
-- targetLang: "ru", "en", "es", "de", "pl", "it", "fr", "id", "tr"
-- origin:     ОБЯЗАТЕЛЬНО передавать baseUrl — без него API вернёт 400!
--             Пример: google_translate(html, "en", "ru", baseUrl)
-- Возвращает переведённый текст или оригинал при ошибке
-- ВАЖНО: принимает HTML с тегами <p>, возвращает HTML с тегами

get_preference(key)                -- "" если нет
set_preference(key, value)

sleep(ms)
os_time()                          -- Unix timestamp мс
log_info("msg")
log_error("msg")
```

---

## 7. Cover-трансформации (обязательно читать)

**Адаптер передаёт `cover` в UI без изменений.** Вся логика — в плагине.

### Универсальный absUrl хелпер

```lua
local function absUrl(href)
  if href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end
```

### Замена части URL (миниатюра → полный размер)

```lua
-- Jaomix: убрать -150x150
local function jaomixCover(url)
  return regex_replace(url, "%-150x150", "")
end

-- Общий паттерн: убрать размер-суффикс
local function removeSizeSuffix(url)
  return regex_replace(url, "%-%d+x%d+", "")
end
```

### Прокси (обход hotlink-защиты)

```lua
local function weservProxy(coverUrl)
  if coverUrl == "" then return "" end
  if not string_starts_with(coverUrl, "http") then return coverUrl end
  local stripped = regex_replace(coverUrl, "^https?://", "")
  return "https://wsrv.nl/?url=" .. url_encode(stripped) .. "&https=1"
end
```

### Lazy-load обложки (data-src)

Многие сайты используют lazy-loading — `src` пустой, реальный URL в `data-src`:

```lua
local cover = html_attr(card, "img", "src")
if cover == "" then cover = html_attr(card, "img", "data-src") end
cover = absUrl(cover)
```

---

## 8. Реализация каталога и поиска

### Page-based

```lua
function getCatalogList(index)
  local page = index + 1
  local r = http_get(baseUrl .. "novels?page=" .. page)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".novel-card")) do
    local titleEl = html_select_first(card.html, "h3 a")
    local imgEl   = html_select_first(card.html, "img")
    if titleEl then
      table.insert(items, {
        title = string_trim(titleEl.text),
        url   = absUrl(titleEl.href),
        cover = imgEl and absUrl(imgEl.src) or ""
      })
    end
  end
-- Предпочтительно: hasNext по наличию items, не по селектору
-- local nextEl = html_select_first(r.body, "a.next, .pagination .next")
  return { items = items, hasNext = #items > 0 }
end
```

### POST поиск с GBK

```lua
function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end
  local r = http_post(
    baseUrl .. "modules/article/search.php",
    "searchkey=" .. url_encode_charset(query, "GBK") .. "&searchtype=all",
    {
      charset = "GBK",
      headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    }
  )
  if not r.success then return { items = {}, hasNext = false } end
  -- парсинг...
end
```

---

## 9. Реализация деталей книги

```lua
function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h1.title, h3.title")
  if el then return string_trim(el.text) end
  local og = html_attr(r.body, "meta[property='og:title']", "content")
  if og ~= "" then return string_trim(og) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local url = html_attr(r.body, "meta[property='og:image']", "content")
  if url ~= "" then return url end
  local el = html_select_first(r.body, ".cover img, .book-cover img")
  if el then return absUrl(el.src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cleaned = html_remove(r.body, "script", ".ads")
  local el = html_select_first(cleaned, ".description, .synopsis, .desc-text")
  if el then return string_trim(el.text) end
  return nil
end

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".chapter-list a:last-child")
  if el then return el.href end
  return nil
end
```

---

## 10. Реализация списка глав

### Одна страница + reverseChapters (сайт даёт newest-first)

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, ".eplister li > a:not(.dlpdf)")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      local titleEl = html_select_first(a.html, ".epl-title")
      table.insert(chapters, {
        title = titleEl and string_clean(titleEl.text) or string_clean(a.text),
        url   = chUrl
      })
    end
  end

  -- Разворот: сайт отдаёт newest-first → нужен oldest-first
  local reversed = {}
  for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
  return reversed
end
```

### Paginated HTML — много страниц (10+) → `http_get_batch` ✨

Когда страниц много, последовательный цикл слишком медленный.
`http_get_batch` загружает все страницы параллельно — скорость сопоставима с нативным KT:

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local maxPage = 1
  local lastEl = html_select_first(r.body, "#list-chapter > ul:nth-child(3) > li.last > a")
  if lastEl then
    local p = string.match(lastEl.href, "[?&]page=(%d+)")
    if p then maxPage = tonumber(p) or 1 end
  end

  -- Собираем URL страниц 2..maxPage (страница 1 уже загружена)
  local pageUrls = {}
  for page = 2, maxPage do
    table.insert(pageUrls, bookUrl .. "?page=" .. tostring(page))
  end

  -- Параллельная загрузка — НЕ нужен sleep
  local pageResults = {}
  if #pageUrls > 0 then
    pageResults = http_get_batch(pageUrls)
  end

  local chapters = {}

  -- Страница 1 (уже есть)
  for _, a in ipairs(html_select(r.body, "ul.list-chapter li a")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      table.insert(chapters, { title = string_clean(a.text), url = chUrl })
    end
  end

  -- Страницы 2..N (порядок гарантирован)
  for _, pr in ipairs(pageResults) do
    if pr.success then
      for _, a in ipairs(html_select(pr.body, "ul.list-chapter li a")) do
        local chUrl = absUrl(a.href)
        if chUrl ~= "" then
          table.insert(chapters, { title = string_clean(a.text), url = chUrl })
        end
      end
    end
  end

  return chapters
end
```

> **Важно:** `http_get_batch` принимает только массив URL — без headers/charset.
> Порядок результатов **гарантирован** — соответствует порядку входного массива.

### AJAX GET (ID из URL — паттерн WtrLab)

```lua
function getChapterList(bookUrl)
  local novelId = string.match(bookUrl, "/novel/(%d+)/")
  if not novelId then return {} end
  local slug = string.match(bookUrl, "/novel/%d+/([^/?#]+)") or ""

  sleep(300)  -- rate limit

  local r = http_get(baseUrl .. "api/chapters/" .. novelId, {
    headers = { ["Referer"] = bookUrl }
  })
  if not r.success then return {} end

  local data = json_parse(r.body)
  if not data or not data.chapters then return {} end

  local chapters = {}
  for _, ch in ipairs(data.chapters) do
    local order = ch.order or #chapters + 1
    table.insert(chapters, {
      title = tostring(order) .. ": " .. (ch.title or "Chapter " .. tostring(order)),
      url   = baseUrl .. "novel/" .. novelId .. "/" .. slug .. "/chapter-" .. tostring(order)
    })
  end
  return chapters
end
```

### AJAX GET (ID из og:url — паттерн NovelBin)

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end
  local ogUrl = html_attr(r.body, "meta[property='og:url']", "content")
  local novelId = string.match(ogUrl, "/([^/?#]+)/*$")
  if not novelId then return {} end

  local ar = http_get(baseUrl .. "ajax/chapter-archive?novelId=" .. novelId)
  if not ar.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(ar.body, "ul.list-chapter li a")) do
    table.insert(chapters, { title = string_trim(a.text), url = absUrl(a.href) })
  end
  return chapters
end
```

### AJAX POST WordPress

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end
  local maxPage = math.max(1, #html_select(r.body, "select.page-select option"))
  local chapters = {}
  for page = maxPage, 1, -1 do
    sleep(300)
    local pr = http_post(baseUrl .. "wp-admin/admin-ajax.php",
      "action=get_chapters&page=" .. page,
      { headers = {
          ["Content-Type"]     = "application/x-www-form-urlencoded",
          ["X-Requested-With"] = "XMLHttpRequest",
          ["Referer"]          = bookUrl
      }}
    )
    if pr.success then
      for _, a in ipairs(html_select(pr.body, "a[href]")) do
        table.insert(chapters, { title = string_trim(a.text), url = absUrl(a.href) })
      end
    end
  end
  return chapters
end
```

### JSON API с томами

```lua
function getChapterList(bookUrl)
  local slug = string.match(bookUrl, "/([^/?#]+)$")
  if not slug then return {} end
  local r = http_get("https://api.example.com/manga/" .. slug .. "/chapters")
  if not r.success then return {} end
  local data = json_parse(r.body)
  local chapters = {}
  for _, item in ipairs(data.data or {}) do
    table.insert(chapters, {
      title  = "Глава " .. tostring(item.number) .. (item.name ~= "" and ": " .. item.name or ""),
      url    = baseUrl .. slug .. "/v" .. tostring(item.volume) .. "/c" .. tostring(item.number),
      volume = "Том " .. tostring(item.volume)
    })
  end
  -- Разворот newest→oldest
  local reversed = {}
  for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
  return reversed
end
```

---

## 11. Реализация текста главы

### Базовый паттерн

```lua
function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads", ".banner", "h3")
  local el = html_select_first(cleaned, "#chapter-content, .chapter-content, .content")
  if el then return html_text(el.html) end
  return ""
end
```

### API-based (паттерн WtrLab)

Когда сайт отдаёт контент через JSON API а не через HTML страницу:

```lua
function getChapterText(html, chapterUrl)
  -- Используем url напрямую (второй аргумент, не надо парсить из HTML)
  if not chapterUrl or chapterUrl == "" then return "" end

  local novelId = string.match(chapterUrl, "/novel/(%d+)/")
  local chapterNo = tonumber(string.match(chapterUrl, "/chapter%-(%d+)")) or 1

  local r = http_post(
    baseUrl .. "api/reader/get",
    json_stringify({
      novel_id   = novelId,
      chapter_no = chapterNo,
      mode       = get_preference("plugin_mode") or "default"
    }),
    { headers = {
        ["Content-Type"] = "application/json",
        ["Referer"]      = chapterUrl,
        ["Origin"]       = regex_replace(baseUrl, "/$", "")
    }}
  )
  if not r.success then return "" end

  local data = json_parse(r.body)
  if not data then return "" end

  -- Сборка абзацев из массива
  local parts = {}
  for _, para in ipairs(data.paragraphs or {}) do
    if type(para) == "string" and para ~= "" then
      table.insert(parts, "<p>" .. para .. "</p>")
    end
  end
  return table.concat(parts, "\n")
end
```

### С переводом через google_translate

```lua
-- Перевод порциями по ~8000 символов
local function translateChunks(paragraphs, sourceLang, targetLang)
  local result = {}
  for i = 1, #paragraphs do result[i] = paragraphs[i] end

  local MAX_CHARS = 8000
  local chunks = {}
  local ci, ch = {}, ""
  for i, para in ipairs(paragraphs) do
    local p = "<p>" .. para .. "</p>"
    if ch ~= "" and #ch + #p > MAX_CHARS then
      table.insert(chunks, { indices = ci, html = ch })
      ci, ch = {}, ""
    end
    table.insert(ci, i)
    ch = ch .. p
  end
  if ch ~= "" then table.insert(chunks, { indices = ci, html = ch }) end

  for idx, chunk in ipairs(chunks) do
    if idx > 1 then sleep(500) end
    local translated = google_translate(chunk.html, sourceLang, targetLang, baseUrl)  -- origin обязателен!
    if translated and translated ~= chunk.html then
      local tParas = {}
      for _, el in ipairs(html_select(translated, "p")) do
        local t = string_trim(el.text)
        if t ~= "" then table.insert(tParas, t) end
      end
      local minSz = math.min(#tParas, #chunk.indices)
      for pos = 1, minSz do
        result[chunk.indices[pos]] = tParas[pos]
      end
    end
  end
  return result
end

function getChapterText(html, url)
  -- ... получить paragraphs ...
  local lang = get_preference("target_lang")  -- "ru", "en", etc.
  if lang and lang ~= "none" and lang ~= "" then
    paragraphs = translateChunks(paragraphs, "zh-CN", lang)
  end
  local parts = {}
  for _, p in ipairs(paragraphs) do
    table.insert(parts, "<p>" .. p .. "</p>")
  end
  return table.concat(parts, "\n")
end
```

### Многостраничная глава

```lua
function getChapterText(html, url)
  local cleaned = html_remove(html, "script", ".ads")
  local el = html_select_first(cleaned, ".content")
  if not el then return "" end
  local parts = { html_text(el.html) }
  local current = cleaned
  for _ = 1, 20 do
    local nextEl = html_select_first(current, "a:contains(Next Part)")
    if not nextEl then break end
    local r = http_get(nextEl.href)
    if not r.success then break end
    current = html_remove(r.body, "script", ".ads")
    local contentEl = html_select_first(current, ".content")
    if contentEl then table.insert(parts, html_text(contentEl.html)) end
  end
  return table.concat(parts, "\n")
end
```

---

## 12. Настройки плагина (getSettingsSchema)

Плагины могут объявить функцию `getSettingsSchema()`, которая описывает настраиваемые параметры. Адаптер автоматически рендерит нативный Material3 UI на основе этой схемы.

### Хранение настроек

Настройки хранятся в `SharedPreferences "lua_preferences"`. Используй `get_preference(key)` для чтения и `set_preference(key, value)` для записи. Ключи должны быть уникальными в пределах всех плагинов — рекомендуется префикс с id плагина: `"wtrlab_mode"`, `"ranobehub_lang"`.

### Поддерживаемые типы виджетов

| type | Поведение |
|---|---|
| `"select"` | 2 варианта → кнопки бок о бок; 3+ вариантов → выпадающий список |

### Схема (формат возврата)

```lua
function getSettingsSchema()
  return {
    -- Виджет типа "select"
    {
      key     = "pluginid_mode",     -- ключ для get/set_preference
      type    = "select",
      label   = "Translation Mode",  -- заголовок секции
      current = get_preference("pluginid_mode") ~= "" 
                and get_preference("pluginid_mode") or "ai",
      options = {
        { value = "ai",  label = "AI (Enhanced)" },
        { value = "raw", label = "Raw (Web)" }
      }
    },
    -- Второй виджет
    {
      key     = "pluginid_lang",
      type    = "select",
      label   = "Translation Language",
      current = get_preference("pluginid_lang") ~= ""
                and get_preference("pluginid_lang") or "none",
      options = {
        { value = "none", label = "No translation" },
        { value = "en",   label = "English" },
        { value = "ru",   label = "Russian" },
        -- ...
      }
    }
  }
end
```

### Чтение настроек в плагине

```lua
local PREF_MODE = "wtrlab_mode"
local PREF_LANG = "wtrlab_language"

local function getMode()
  local v = get_preference(PREF_MODE)
  return (v ~= "" and v) or "ai"  -- значение по умолчанию
end

local function getLang()
  local v = get_preference(PREF_LANG)
  return (v ~= "" and v) or "none"
end

-- Использование в getChapterText:
function getChapterText(html, url)
  local mode = getMode()  -- "ai" или "raw"
  local lang = getLang()  -- "none", "ru", "en", ...
  -- ...
end
```

### Полный пример (WtrLab)

```lua
local PREF_MODE = "wtrlab_mode"
local PREF_LANG = "wtrlab_language"

local function getMode()
  local v = get_preference(PREF_MODE)
  return (v ~= "" and v) or "ai"
end

local function getLang()
  local v = get_preference(PREF_LANG)
  return (v ~= "" and v) or "none"
end

function getSettingsSchema()
  return {
    {
      key     = PREF_MODE,
      type    = "select",
      label   = "Translation Mode",
      current = getMode(),
      options = {
        { value = "ai",  label = "AI (Enhanced)" },
        { value = "raw", label = "Raw (Web)" }
      }
    },
    {
      key     = PREF_LANG,
      type    = "select",
      label   = "Translation Language",
      current = getLang(),
      options = {
        { value = "none", label = "No translation (original)" },
        { value = "en",   label = "English" },
        { value = "es",   label = "Spanish" },
        { value = "ru",   label = "Russian" },
        { value = "de",   label = "German" },
        { value = "id",   label = "Indonesian" },
        { value = "tr",   label = "Turkish" },
        { value = "pl",   label = "Polish" },
        { value = "it",   label = "Italian" },
        { value = "fr",   label = "French" }
      }
    }
  }
end
```

### Как работает в адаптере

```
1. createLuaSourceAdapter() вызывает parseLuaSettingsSchema(luaScript)
2. Если схема найдена → возвращает LuaSourceAdapterConfigurable (подкласс)
   Если нет → возвращает обычный LuaSourceAdapter (без кнопки настроек)
3. LuaSourceAdapterConfigurable реализует SourceInterface.Configurable
4. UI находит кнопку настроек через стандартный `is SourceInterface.Configurable`
   → никаких изменений в UI-коде не нужно
5. LuaSettingsScreen рендерит нативные Material3 виджеты
6. При выборе пользователя → prefs.putString(key, value)
7. В следующем вызове getChapterText → get_preference(key) вернёт новое значение
```

> **Важно:** Если плагин НЕ объявляет `getSettingsSchema()` — кнопка настроек
> не появляется вообще. Только плагины с явной схемой получают UI настроек.

---

## 13. Паттерны и сценарии

### Разворот массива (oldest-first)

```lua
local reversed = {}
for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
return reversed
```

### Capture groups (нативный Lua)

```lua
local id     = string.match(url, "/novel/(%d+)/")
local vol,ch = string.match(url, "/v(%d+)/c([%d%.]+)")
local slug   = string.match(url, "/([^/]+)$")
```

### JSONP

```lua
local jsonStr = string.match(r.body, "[^(]+%((.+)%)%s*$")
local data = json_parse(jsonStr)
```

### ID книги из `<script>`

```lua
local bookId = string.match(r.body, "bookId%s*=%s*(%d+)")
```

### Расшифровка зашифрованного тела через внешний прокси

```lua
-- Паттерн WtrLab: тело начинается с "arr:" → отправить на прокси
local function decryptBody(rawBody)
  if not string_starts_with(rawBody, "arr:") then return rawBody end
  local r = http_post(
    "https://my-proxy.fly.dev/decrypt",
    json_stringify({ payload = rawBody }),
    { headers = { ["Content-Type"] = "application/json" } }
  )
  if not r.success then return rawBody end
  local data = json_parse(r.body)
  if type(data) == "table" and data[1] ~= nil then
    return json_stringify(data)  -- массив абзацев
  end
  if type(data) == "table" and data.body then
    return json_stringify(data.body)
  end
  return rawBody
end
```

### Применение глоссария

```lua
-- glossary: { [0]="term0", [1]="term1", ... }
-- Маркеры в тексте: ※0⛬, ※0〓, ※1⛬, ...
local function applyGlossary(text, glossary)
  for idx, term in pairs(glossary) do
    text = text:gsub("※" .. tostring(idx) .. "⛬", term)
    text = text:gsub("※" .. tostring(idx) .. "〓", term)
  end
  return text
end
```

### Cloudflare

```lua
local r = http_get(url, { headers = { ["User-Agent"] = "Mozilla/5.0 (Linux; Android 12)" } })
```

---

## 14. Best Practices

1. **Всегда `absUrl(href)`** для любых ссылок — никогда не возвращай относительные URL
2. **Всегда `transformCover(url)`** — cover в адаптер идёт as-is без обработки
3. **`tostring()`** для чисел: `"page=" .. tostring(index)`
4. **`if el then`** перед любым использованием результата `html_select_first`
5. **`html_attr`** когда нужен один атрибут без объекта элемента
6. **`el:attr("name")`** когда объект элемента уже есть
7. **`html_remove` перед `html_text`** — чистить до, а не после
8. **`string_clean`** для заголовков и коротких строк — заменяет три вызова: normalize + collapse + trim
9. **`string_normalize`** для больших текстовых блоков перед `regex_replace`
10. **`sleep(300-500)`** только в последовательных циклах с запросами
11. **`http_get_batch`** когда страниц глав 10+ — параллельно в разы быстрее чем цикл
12. **Lazy-load обложки** — всегда проверять `data-src` если `src` пустой
13. **`string.match` с capture groups** вместо `regex_match` для извлечения подстрок
14. **`local` функции** для хелперов
15. **GBK везде**: `http_get(url, {charset="GBK"})`, `url_encode_charset(q, "GBK")`
16. **Настройки**: ключи вида `"{pluginid}_{key}"` для избежания конфликтов
17. **getChapterText**: принимай оба аргумента `(html, url)` — `url` удобнее canonical
18. **Перевод**: используй chunking по 8000 символов + `sleep(500)` между чанками
19. **Прокси для шифрования**: `http_post` к внешнему сервису если API шифрует ответы
20. **`google_translate` требует `origin`**: всегда передавай `baseUrl` 4-м аргументом — без него API вернёт 400
21. **Иконка**: в `index.yaml` — приоритетнее чем `icon` в Lua-скрипте. YAML исправит неверную иконку без обновления плагина
22. **`hasNext` через URL-индекс, не через селектор** — если URL страницы строится по индексу (`?page=N`), используй `hasNext = #items > 0` вместо поиска кнопки `.next`. Селектор зависит от вёрстки и ненадёжен.

---

## 15. Антипаттерны и частые ошибки

| Антипаттерн | Решение |
|---|---|
| `hasNext = html_select_first(r.body, ".next") ~= nil` при URL-пагинации | `hasNext = #items > 0` |
| `return { getCatalogList = function() end }` | Top-level функции |
| `e.text:find(p)` | `local t = e.text; t:find(p)` |
| `regex_match(url, "/(%d+)/")[1]` → "/123/" | `string.match(url, "/(%d+)/")` → "123" |
| Относительный URL в `cover` или `url` | `absUrl(href)` |
| Миниатюра вместо полного cover | `transformCover(url)` |
| `"x=" .. r.code` | `"x=" .. tostring(r.code)` |
| `goto continue` | `if ... end` |
| Последовательный цикл для 10+ страниц глав | `http_get_batch(urls)` |
| `sleep` перед `http_get_batch` | Не нужен — запросы параллельны |
| Пустой cover при lazy-load | Проверять `data-src` если `src == ""` |
| `string_normalize + regex_replace("\\s+") + string_trim` для заголовков | `string_clean(text)` |
| Запросы в цикле без `sleep` | `sleep(300)` |
| Текст без `<p>` | Использовать `html_text()` |
| GBK сайт без charset | `{charset = "GBK"}` |
| Игнорирование `r.success` | `if not r.success then return ... end` |
| `get_preference` без default | `(get_preference(k) ~= "" and get_preference(k)) or default` |
| Конфликт ключей preferences между плагинами | Префикс `"{id}_{key}"` |
| `google_translate` на огромном тексте | Chunking по 8000 символов |
| `google_translate(text, src, tgt)` без origin | Всегда передавай `baseUrl` 4-м аргументом |
| `language = "MTL"` показывает капсом | Это нормально если `LanguageCode.MTL.iso639_1` ≠ "MTL" — проверь значение в enum |
| Парсить URL из canonical вместо аргумента | Использовать второй аргумент `url` в `getChapterText` |

---

## 16. Отладка и логирование

```lua
log_info("getCatalogList page=" .. tostring(index + 1))
log_error("http failed " .. tostring(r.code) .. " " .. url)
```

Logcat тег: `Lua:`

| Ошибка | Причина |
|---|---|
| `attempt to index ? (a nil value)` | `html_select_first` вернул nil; функции в `return{}` |
| `attempt to concatenate number` | Нужен `tostring()` |
| `Compile error` | Незакрытый `end`, `goto` |
| `missing 'getCatalogList'` | Функция в `return{}`, не top-level |
| Пустой каталог | Неверный CSS-селектор |
| Кривые символы | `charset="GBK"`, `string_normalize()` |
| `regex_match` даёт "/123/" вместо "123" | `string.match(str, "/(%d+)/")` |
| Сломанные обложки | Нет `absUrl()` или `transformCover()` |
| `get_preference` вернул "" | Добавить default: `(v ~= "" and v) or default` |
| Turnstile/CAPTCHA | `error(chapterUrl)` — сигнал для WebView |
| Пустой перевод | `google_translate` вернул оригинал при ошибке — скорее всего не передан `origin` |
| Кнопка настроек не появляется | Плагин не объявляет `getSettingsSchema()` или функция возвращает пустую таблицу |
| Настройки сбрасываются | Ключи конфликтуют с другим плагином — добавь префикс id: `"wtrlab_mode"` |
| Список глав грузится медленно (10+ стр.) | Используй `http_get_batch` вместо последовательного цикла |

---

repository/
  en/wtrlab.lua        ru/jaomix.lua       zh/shuba69.lua
  en/index.yaml        ru/index.yaml       zh/index.yaml
  icons/wtrlab.png     icons/jaomix.png    icons/shuba69.png
  index.yaml
```

**`en/index.yaml`:**
```yaml
- id: wtrlab
  name: WTR-LAB
  version: "1.0.0"
  language: MtL
  icon: https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wtr-lab.png
  codeUrl: https://raw.githubusercontent.com/HnDK0/external-sources/main/mtl/wtrlab.lua
```

**Глобальный `index.yaml`:**
```yaml
count: 3
sources:
  - lang: en
    index: https://raw.githubusercontent.com/.../en/index.yaml
  - lang: MTL
    index: https://raw.githubusercontent.com/.../mtl/index.yaml
  - lang: ru
    index: https://raw.githubusercontent.com/.../ru/index.yaml
```

