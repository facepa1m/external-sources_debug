# NoveLA Lua Plugin Guide — Полное руководство

> **Цель:** Самодостаточный документ. Имея только его, можно написать полнофункциональный плагин без доступа к исходному коду. Основан на анализе 27 нативных источников и реальном опыте разработки.

---

## Содержание

1. [Чеклист разработки](#1-чеклист-разработки)
2. [Архитектура и жизненный цикл](#2-архитектура-и-жизненный-цикл)
3. [Критические правила LuaJ](#3-критические-правила-luaj)
4. [Анализ сайта — Decision Tree](#4-анализ-сайта--decision-tree)
5. [Структура файла плагина](#5-структура-файла-плагина)
6. [Глобальное Lua API — Полный справочник](#6-глобальное-lua-api--полный-справочник)
7. [Реализация каталога и поиска](#7-реализация-каталога-и-поиска)
8. [Реализация деталей книги](#8-реализация-деталей-книги)
9. [Реализация списка глав](#9-реализация-списка-глав)
10. [Реализация текста главы](#10-реализация-текста-главы)
11. [Паттерны и сценарии](#11-паттерны-и-сценарии)
12. [Best Practices](#12-best-practices)
13. [Антипаттерны и частые ошибки](#13-антипаттерны-и-частые-ошибки)
14. [Отладка и логирование](#14-отладка-и-логирование)
15. [Регистрация плагина](#15-регистрация-плагина)

---

## 1. Чеклист разработки

- [ ] **Шаг 1: Анализ сайта.** Chrome DevTools (F12). Изучите структуру URL, пагинацию, эндпоинты AJAX, кодировку.
- [ ] **Шаг 2: Создание файла.** `lang/source_id.lua`
- [ ] **Шаг 3: Метаданные.** Заполните `id`, `name`, `baseUrl`, `language`, `icon`, `version`.
- [ ] **Шаг 4: Каталог и поиск.** `getCatalogList` + `getCatalogSearch` с флагом `hasNext`.
- [ ] **Шаг 5: Книга.** `getBookTitle`, `getBookCoverImageUrl`, `getBookDescription`.
- [ ] **Шаг 6: Главы.** `getChapterList` (порядок от старых к новым) + `getChapterText`.
- [ ] **Шаг 7: Чистка текста.** Удалить рекламу, скрипты, навигацию из текста главы.
- [ ] **Шаг 8: Регистрация.** `index.yaml` + иконка.

---

## 2. Архитектура и жизненный цикл

Приложение загружает `.lua` файл через **LuaJ**. Скрипт **выполняется** при загрузке — все функции и переменные верхнего уровня регистрируются в `globals`. Адаптер затем читает функции напрямую из `globals` по имени.

**Жизненный цикл вызовов:**

```
1. Загрузка скрипта → globals["id"], globals["name"], globals["baseUrl"] и т.д.
2. Каталог          → getCatalogList(0), getCatalogList(1), ... пока hasNext=true
3. Поиск            → getCatalogSearch(0, query), getCatalogSearch(1, query), ...
4. Карточка книги   → getBookTitle(url) + getBookDescription(url) + getBookCoverImageUrl(url)
5. Список глав      → getChapterList(url)     -- порядок: старые → новые
6. Чтение главы     → приложение скачивает HTML → getChapterText(html)
7. Проверка обновл. → getChapterListHash(url) -- строка меняется при новых главах
```

---

## 3. Критические правила LuaJ

> LuaJ реализует **Lua 5.1**. Несоблюдение этих правил вызывает `LuaError: attempt to index ? (a nil value)` или молчаливые баги.

### Правило 1: НЕ использовать `return { функции }` — только top-level

Старый стиль с `return { getCatalogList = function() end }` **не работает**.
Адаптер читает функции из globals, а не из возвращаемого значения скрипта.

```lua
-- НЕВЕРНО — адаптер получит nil для всех функций
return {
  getCatalogList = function(index) ... end,
}

-- ВЕРНО — функции на верхнем уровне файла
function getCatalogList(index)
  ...
end
```

### Правило 2: НЕ вызывать методы через `:` на полях Java-объектов

```lua
-- НЕВЕРНО — LuaError
local els = html_select(body, "meta[property='og:image']")
local url = els[1]:attr("content")

-- ВЕРНО — использовать html_attr
local url = html_attr(body, "meta[property='og:image']", "content")
```

**Безопасные поля элемента** (доступны напрямую): `el.text`, `el.html`, `el.href`, `el.src`, `el.id`, `el.class`

**Для любого другого атрибута** — только `html_attr(html, selector, "attr_name")`

### Правило 3: НЕ вызывать строковые методы через `:` на полях таблицы

```lua
-- НЕВЕРНО
local found = e.text:find("Chapters")
local s = r.body:sub(1, 200)
local clean = string_trim(baseUrl):gsub("/$", "")

-- ВЕРНО
local m = regex_match(e.text, "Chapters")
if m[1] then ... end

local body = r.body
local s = string.sub(body, 1, 200)

local clean = regex_replace(string_trim(baseUrl), "/$", "")
```

### Правило 4: НЕ использовать `goto`

```lua
-- НЕВЕРНО — Lua 5.2+, LuaJ не поддерживает
goto continue

-- ВЕРНО — условный блок
if condition then
  -- обработка
end
```

### Правило 5: ВСЕГДА `tostring()` для чисел в конкатенации

```lua
-- НЕВЕРНО — attempt to concatenate number
log_error("code=" .. r.code)

-- ВЕРНО
log_error("code=" .. tostring(r.code))
```

---

## 4. Анализ сайта — Decision Tree

**Как сайт отдаёт контент?**
- **Чистый HTML** → `http_get` + `html_select`
- **JSON API** → `http_get` + `json_parse`
- **Зашифрован (AES)** → `aes_decrypt`

**Пагинация каталога:**
- `?page=1` (page-based) — большинство сайтов
- `?offset=0&limit=20` (offset-based) — API-сайты
- `?after=cursor` (cursor-based) — редко

**Список глав:**
- **Всё на странице** — парсить HTML книги
- **Paginated HTML** — цикл по страницам `?page=N`
- **AJAX GET** — отдельный запрос с ID книги
- **AJAX POST** — WordPress `admin-ajax.php`
- **JSON API** — REST-эндпоинт

**Кодировка:**
- Китайские сайты часто используют **GBK** → `http_get(url, {charset = "GBK"})`

---

## 5. Структура файла плагина

```lua
-- ── Метаданные (обязательно) ──────────────────────────────────────────────────
id       = "source_id"          -- уникальный ID, snake_case или camelCase
name     = "Source Name"        -- отображаемое имя
version  = "1.0.0"
baseUrl  = "https://example.com/"
language = "en"                 -- ISO 639-1: en, ru, zh, es, de, fr, it, pl, id, tr, mul
icon     = "https://..."        -- полный HTTPS URL иконки

-- ── Вспомогательные функции (local) ──────────────────────────────────────────
local function helper() ... end

-- ── Обязательные функции (global, top-level) ─────────────────────────────────
function getCatalogList(index) ... end
function getCatalogSearch(index, query) ... end
function getBookTitle(bookUrl) ... end
function getBookCoverImageUrl(bookUrl) ... end
function getBookDescription(bookUrl) ... end
function getChapterList(bookUrl) ... end
function getChapterText(html) ... end

-- ── Необязательные функции ────────────────────────────────────────────────────
function getChapterListHash(bookUrl) ... end  -- для проверки обновлений
function getSettings() ... end               -- чтение текущих настроек
function setMode(mode) ... end               -- изменение настроек
```

### Форматы возвращаемых значений

**getCatalogList / getCatalogSearch:**
```lua
return {
  items = {
    { title = "Title", url = "https://...", cover = "https://..." },
  },
  hasNext = true   -- есть ли следующая страница
}
```

**getChapterList:**
```lua
return {
  { title = "Chapter 1", url = "https://...", volume = "Vol.1" },  -- volume необязателен
  { title = "Chapter 2", url = "https://..." },
}
-- Порядок: от старых глав к новым
```

**getChapterText:**
```lua
return "<p>Paragraph 1</p>\n<p>Paragraph 2</p>"
-- Текст ОБЯЗАТЕЛЬНО в <p> тегах — иначе читалка покажет всё одним блоком
```

---

## 6. Глобальное Lua API — Полный справочник

### 6.1. Networking

```lua
-- GET запрос
local r = http_get(url)
local r = http_get(url, {
  headers = { ["User-Agent"] = "Mozilla/5.0", ["Referer"] = baseUrl },
  charset = "GBK"   -- для нестандартных кодировок (китайские сайты)
})
-- r.success (bool), r.body (string), r.code (int)

-- POST запрос
local r = http_post(url, body_string, {
  headers = { ["Content-Type"] = "application/json" }
})
local r = http_post(url, "key=val&key2=val2", {
  headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
})

-- Cookies (OkHttp CookieJar)
local cookies = get_cookies(url)        -- таблица {name = value}
set_cookies(url, cookies_table)
```

### 6.2. HTML парсинг (Jsoup)

```lua
-- Выбор элементов — возвращает МАССИВ
local els = html_select(html_or_element_html, "css selector")
-- Поля каждого элемента:
-- el.text  — текстовое содержимое
-- el.html  — внутренний HTML (использовать для вложенного парсинга)
-- el.href  — абсолютный URL из href атрибута
-- el.src   — абсолютный URL из src атрибута
-- el.id    — атрибут id
-- el.class — атрибут class

-- Первый элемент или nil
local el = html_select_first(html_string, "css selector")
if el then
  local text = el.text
end

-- Получение ЛЮБОГО атрибута (безопасный способ, никогда не nil)
local value = html_attr(html_string, "css selector", "attr_name")
-- Возвращает "" если не найдено

-- Извлечение текста с сохранением абзацев (<p>, <br> → \n)
local text = html_text(html_string_or_element_html)

-- Удаление элементов — возвращает очищенный HTML string
local cleaned = html_remove(html_string, "script", ".ads", "h3", ".banner")
```

**Поддерживаемые CSS-селекторы (Jsoup):**
```
.class, #id, tag, tag.class
a[href], img[src], meta[property='og:image']
.parent > .child           прямой потомок
.parent .descendant        любой потомок потомков
li:first-child, li:last-child
a:contains(Next)           содержит текст
:not(.selector)
.sm\\:text-lg              экранирование двоеточия в классах
```

### 6.3. JSON

```lua
local data = json_parse(string)      -- string → lua table/array
local str  = json_stringify(value)   -- lua value → JSON string
```

### 6.4. URL

```lua
local enc = url_encode(str)                       -- URL-encode (UTF-8)
local enc = url_encode_charset(str, "GBK")        -- с нестандартной кодировкой
local abs = url_resolve(base_url, relative_url)   -- resolve относительного URL
```

### 6.5. Regex и строки

```lua
-- Поиск: возвращает массив ВСЕХ совпадений
local m = regex_match(text, "pattern")
-- m[1], m[2], ... — совпадения

-- Замена
local result = regex_replace(text, "pattern", "replacement")

-- Строковые утилиты
local trimmed = string_trim(str)
local norm    = string_normalize(str)          -- NFKC Unicode нормализация
local parts   = string_split(str, separator)   -- возвращает массив
local b       = string_starts_with(str, prefix)
local b       = string_ends_with(str, suffix)
local str     = unescape_unicode(str)          -- \uXXXX → символы
```

### 6.6. Base64 и Crypto

```lua
local decoded = base64_decode(str)
local encoded = base64_encode(str)

-- AES/CBC/PKCS5Padding
local plain = aes_decrypt(encrypted_base64, key_string, iv_string)
```

### 6.7. Google Translate

```lua
-- Синхронный, блокирует поток — использовать с осторожностью
local translated = google_translate(text, "zh-CN", "ru")
-- source: "en", "zh-CN", "auto" и т.д.
-- target: "ru", "en", "es" и т.д.
```

### 6.8. Настройки и утилиты

```lua
local val = get_preference(key)    -- "" если нет значения
set_preference(key, value)

sleep(500)           -- задержка в мс (rate-limiting)
local ts = os_time() -- Unix timestamp в мс (cache-busting)

log_info("message")  -- тег "Lua:" в Logcat
log_error("message")
```

---

## 7. Реализация каталога и поиска

### Page-based (большинство сайтов)

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
        url   = titleEl.href,
        cover = imgEl and imgEl.src or ""
      })
    end
  end

  local nextEl = html_select_first(r.body, "a.next, .pagination .next")
  return { items = items, hasNext = nextEl ~= nil }
end
```

### Offset-based (JSON API)

```lua
function getCatalogList(index)
  local limit  = 20
  local offset = index * limit
  local r = http_get(baseUrl .. "api/list?offset=" .. offset .. "&limit=" .. limit)
  if not r.success then return { items = {}, hasNext = false } end
  local data = json_parse(r.body)
  local items = {}
  for _, book in ipairs(data.books or {}) do
    table.insert(items, { title = book.title, url = book.url, cover = book.cover })
  end
  return { items = items, hasNext = (data.total or 0) > offset + limit }
end
```

### POST поиск (FreeWebNovel)

```lua
function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end
  local r = http_post(baseUrl .. "search", "searchkey=" .. url_encode(query), {
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  })
  if not r.success then return { items = {}, hasNext = false } end
  -- парсинг как обычный HTML...
end
```

### Редирект на книгу при точном совпадении (PiaoTia)

```lua
function getCatalogSearch(index, query)
  local r = http_get(baseUrl .. "search?q=" .. url_encode(query))
  if not r.success then return { items = {}, hasNext = false } end
  local urlMatch = regex_match(r.body, "canonical.*?(https://[^\"']+/book/[^\"']+)")
  if urlMatch[1] then
    return { items = {{ title = query, url = urlMatch[1], cover = "" }}, hasNext = false }
  end
  -- иначе обычный парсинг...
end
```

---

## 8. Реализация деталей книги

```lua
function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h1.title, h3.title, .book-title")
  if el then return string_trim(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  -- og:image надёжнее чем img на странице
  local url = html_attr(r.body, "meta[property='og:image']", "content")
  if url ~= "" then return url end
  local el = html_select_first(r.body, ".cover img, .book-cover img")
  if el then return el.src end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cleaned = html_remove(r.body, "script", ".ads")
  local el = html_select_first(cleaned, ".description, .synopsis, .desc-text, #summary")
  if el then return string_trim(el.text) end
  return nil
end

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  -- Вернуть что угодно что меняется при новых главах:
  -- URL последней главы, количество глав, дата обновления
  local el = html_select_first(r.body, ".chapter-list a:last-child")
  if el then return el.href end
  return nil
end
```

---

## 8.1. Трансформеры обложек

Многие сайты используют thumbnail или относительные URL для обложек. Трансформеры исправляют это в `getBookCoverImageUrl`.

### Базовый трансформер

```lua
-- Преобразование относительных/абсолютных URL
local function transformCoverUrl(coverUrl, bookUrl)
  if coverUrl:find("^//") then
    -- protocol-relative URL (//example.com/image.jpg)
    return "https:" .. coverUrl
  elseif coverUrl:find("^/") then
    -- relative URL (/image.jpg)
    return url_resolve(bookUrl, coverUrl)
  end
  return coverUrl
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cover = html_attr(r.body, "meta[property='og:image']", "content")
  if cover ~= "" then 
    return transformCoverUrl(cover, bookUrl) 
  end
  return nil
end
```

### Пример: NovelBin thumbnail → полная обложка

```lua
-- NovelBin использует thumbnail в URL, заменяем на полные обложки
local function transformNovelBinCover(coverUrl)
  if coverUrl:find("novel_200_89") then
    return coverUrl:gsub("novel_200_89", "novel")
  end
  return coverUrl
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cover = html_attr(r.body, "meta[property='og:image']", "content")
  if cover ~= "" then 
    return transformNovelBinCover(cover) 
  end
  return nil
end
```

### Пример: Image Proxy для CORS

```lua
-- Использование прокси для обложек без CORS
local function transformCoverWithProxy(coverUrl)
  return "https://wsrv.nl/?url=" .. url_encode(coverUrl)
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cover = html_attr(r.body, "meta[property='og:image']", "content")
  if cover ~= "" then 
    return transformCoverWithProxy(cover) 
  end
  return nil
end
```

**Рекомендации:**
- Всегда проверяйте `coverUrl ~= ""` перед трансформацией
- Используйте `url_resolve()` для относительных URL
- Тестируйте трансформеры с разными форматами обложек
- Логируйте оригинальный и трансформированный URL для отладки
```

---

## 9. Реализация списка глав

### Простой HTML

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end
  local chapters = {}
  for _, a in ipairs(html_select(r.body, ".chapter-list a, ul.chapters li a")) do
    table.insert(chapters, { title = string_trim(a.text), url = a.href })
  end
  return chapters
end
```

### Paginated HTML (NovelFire)

```lua
function getChapterList(bookUrl)
  local chapters = {}
  local page = 1
  local maxPage = 1

  while page <= maxPage do
    local r = http_get(bookUrl .. "?page=" .. page)
    if not r.success then break end
    if page == 1 then
      local lastEl = html_select_first(r.body, ".pagination li:last-child a")
      if lastEl then
        local m = regex_match(lastEl.href, "page=(%d+)")
        maxPage = tonumber(m[1]) or 1
      end
    end
    for _, a in ipairs(html_select(r.body, ".chapter-list a")) do
      table.insert(chapters, { title = string_trim(a.text), url = a.href })
    end
    page = page + 1
  end
  return chapters
end
```

### AJAX GET (NovelBin)

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local ogUrl = html_attr(r.body, "meta[property='og:url']", "content")
  local m = regex_match(ogUrl, "/([^/?#]+)$")
  if not m[1] then return {} end

  local ar = http_get(baseUrl .. "ajax/chapter-archive?id=" .. m[1])
  if not ar.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(ar.body, "ul.chapters li a")) do
    table.insert(chapters, { title = string_trim(a.text), url = a.href })
  end
  return chapters
end
```

### AJAX POST WordPress (Jaomix, ScribbleHub)

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local opts = html_select(r.body, "select.page-select option")
  local maxPage = math.max(1, #opts)
  local chapters = {}

  for page = maxPage, 1, -1 do   -- обратный порядок → правильная сортировка
    sleep(300)
    local pr = http_post(
      baseUrl .. "wp-admin/admin-ajax.php",
      "action=get_chapters&page=" .. page,
      { headers = {
          ["Content-Type"]     = "application/x-www-form-urlencoded",
          ["X-Requested-With"] = "XMLHttpRequest",
          ["Referer"]          = bookUrl
      }}
    )
    if pr.success then
      for _, a in ipairs(html_select(pr.body, "a[href]")) do
        table.insert(chapters, { title = string_trim(a.text), url = a.href })
      end
    end
  end
  return chapters
end
```

### JSON API с томами (RanobeLib, RanobeHub)

```lua
function getChapterList(bookUrl)
  local m = regex_match(bookUrl, "/([^/?#]+)$")
  if not m[1] then return {} end

  local r = http_get("https://api.example.com/manga/" .. m[1] .. "/chapters")
  if not r.success then return {} end
  local data = json_parse(r.body)

  local chapters = {}
  for _, item in ipairs(data.data or {}) do
    table.insert(chapters, {
      title  = "Глава " .. item.number .. (item.name and (": " .. item.name) or ""),
      url    = baseUrl .. m[1] .. "/v" .. item.volume .. "/c" .. item.number,
      volume = "Том " .. item.volume
    })
  end

  -- Если сайт вернул в обратном порядке
  local reversed = {}
  for i = #chapters, 1, -1 do
    table.insert(reversed, chapters[i])
  end
  return reversed
end
```

### ID книги из тега `<script>` (NovelBuddy)

```lua
function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local m = regex_match(r.body, "bookId%s*=%s*(%d+)")
  if not m[1] then return {} end

  local ar = http_get(baseUrl .. "api/chapters?id=" .. m[1])
  if not ar.success then return {} end
  local data = json_parse(ar.body)

  local chapters = {}
  for _, ch in ipairs(data or {}) do
    table.insert(chapters, {
      title  = ch.name or ("Chapter " .. ch.id),
      url    = baseUrl .. "read/" .. ch.id,
      volume = ch.vol and ("Том " .. ch.vol) or nil
    })
  end
  return chapters
end
```

---

## 10. Реализация текста главы

### Базовый паттерн

```lua
function getChapterText(html)
  local cleaned = html_remove(html, "script", "style", ".ads", ".banner",
                               ".chapter-warning", "h3", ".social-share")
  local el = html_select_first(cleaned, "#chapter-content, .chapter-content, .content")
  if el then return html_text(el.html) end
  return ""
end
```

### Многостраничная глава (Novel543)

```lua
function getChapterText(html)
  local cleaned = html_remove(html, "script", ".ads")
  local el = html_select_first(cleaned, ".content")
  if not el then return "" end

  local parts = { html_text(el.html) }
  local current = cleaned
  for _ = 1, 20 do  -- ограничение итераций
    local nextEl = html_select_first(current, "a:contains(Next Part), a:contains(Следующая)")
    if not nextEl then break end
    local r = http_get(nextEl.href)
    if not r.success then break end
    local nextCleaned = html_remove(r.body, "script", ".ads")
    local contentEl = html_select_first(nextCleaned, ".content")
    if contentEl then table.insert(parts, html_text(contentEl.html)) end
    current = nextCleaned
  end

  return table.concat(parts, "\n")
end
```

### GBK кодировка (китайские сайты)

```lua
-- Для GBK сайтов: charset передаётся в http_get
function getChapterList(bookUrl)
  local r = http_get(bookUrl, { charset = "GBK" })
  if not r.success then return {} end
  local chapters = {}
  for _, a in ipairs(html_select(r.body, "#catalog ul li a")) do
    table.insert(chapters, { title = a.text, url = url_resolve(baseUrl, a.href) })
  end
  -- GBK сайты часто отдают в обратном порядке
  local reversed = {}
  for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
  return reversed
end
```

### JSON-контент (RanobeLib TipTap)

```lua
local function jsonToHtml(nodes)
  if not nodes then return "" end
  local out = {}
  for _, node in ipairs(nodes) do
    local t = node.type
    if t == "text" then
      local text = node.text or ""
      for _, mark in ipairs(node.marks or {}) do
        if mark.type == "bold"   then text = "<b>" .. text .. "</b>" end
        if mark.type == "italic" then text = "<i>" .. text .. "</i>" end
      end
      table.insert(out, text)
    elseif t == "paragraph" then
      table.insert(out, "<p>" .. jsonToHtml(node.content) .. "</p>")
    elseif t == "hardBreak" then
      table.insert(out, "<br>")
    elseif t == "image" then
      local src = (node.attrs or {}).src or ""
      table.insert(out, '<img src="' .. src .. '">')
    else
      table.insert(out, jsonToHtml(node.content))
    end
  end
  return table.concat(out, "")
end

function getChapterText(html)
  local slugM = regex_match(html, "site%.com/ru/([^/]+)/read/v(%d+)/c([%d%.]+)")
  if not slugM[1] then return html_text(html) end

  local r = http_get("https://api.site.com/api/manga/" .. slugM[1] ..
    "/chapter?volume=" .. slugM[2] .. "&number=" .. slugM[3],
    { headers = { ["Site-Id"] = "3" } })
  if not r.success then return "" end

  local data = json_parse(r.body)
  local content = data and data.data and data.data.content
  if not content then return "" end
  if type(content) == "string" then return html_text(content) end
  return html_text(jsonToHtml(content.content))
end
```

---

## 11. Паттерны и сценарии

### Обратный порядок глав

```lua
local reversed = {}
for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
return reversed
```

### og:meta теги

```lua
local cover = html_attr(body, "meta[property='og:image']", "content")
local desc  = html_attr(body, "meta[name='description']", "content")
local url   = html_attr(body, "meta[property='og:url']", "content")
```

### JSONP ответ (Quanben5)

```lua
local r = http_get(url)
-- Тело: jQuery({...}) или callback({...})
local jsonStr = regex_replace(r.body, "^[^(]+%((.+)%)%s*$", "%1")
local data = json_parse(jsonStr)
```

### Динамическая обложка из ID книги

```lua
local bookId = regex_match(bookUrl, "/book/(%d+)")[1]
local cover  = "https://cdn.site.com/covers/" .. bookId .. ".jpg"
```

### Определение тома из названия

```lua
local volM   = regex_match(ch.title, "Том (%d+)")
local volume = volM[1] and ("Том " .. volM[1]) or nil
table.insert(chapters, { title = ch.title, url = ch.url, volume = volume })
```

### Cloudflare — куки и User-Agent

```lua
-- Куки сохраняются автоматически через OkHttp CookieJar
local r = http_get(bookUrl, {
  headers = { ["User-Agent"] = "Mozilla/5.0 (Linux; Android 12)" }
})
```

### Image Proxy для обложек без CORS

```lua
local cover = "https://wsrv.nl/?url=" .. url_encode(raw_cover_url)
```

### CSS с двоеточием в классе

```lua
local el = html_select_first(body, ".sm\\:text-lg")
```

### Rate limiting

```lua
for page = 1, maxPage do
  if page > 1 then sleep(500) end
  local r = http_get(url .. "?page=" .. page)
end
```

### Настройки плагина

```lua
local PREF_KEY = "myplugin_setting"

local function getSetting()
  local v = get_preference(PREF_KEY)
  if v ~= "" then return v end
  return "default_value"
end

function getSettings()
  return { setting = getSetting() }
end

function setSetting(value)
  set_preference(PREF_KEY, value)
end
```

---

## 12. Best Practices

1. **`tostring()` для чисел** в конкатенации: `"code=" .. tostring(r.code)`
2. **Проверяй nil** перед использованием: `if el then ... end`
3. **`html_attr`** для атрибутов — никогда `el:attr()`
4. **`html_select_first`** когда нужен один элемент
5. **`html_remove` перед `html_text`** — чистить мусор ДО извлечения текста
6. **`string_normalize`** для текста с unicode/кириллицей
7. **`url_resolve(baseUrl, href)`** для относительных ссылок
8. **`sleep(300-500)`** между запросами в циклах
9. **Оборачивай текст в `<p>`** — читалка без этого не разбивает на абзацы
10. **`local` функции** для хелперов — не засоряй globals

---

## 13. Антипаттерны и частые ошибки

| Антипаттерн | Решение |
|---|---|
| `return { getCatalogList = function() end }` | Функции на верхнем уровне файла |
| `el:attr("name")` | `html_attr(html, selector, "name")` |
| `r.body:sub(1, 100)` | `local b = r.body; string.sub(b, 1, 100)` |
| `e.text:find("pattern")` | `regex_match(e.text, "pattern")[1]` |
| `string_trim(s):gsub(...)` | `regex_replace(string_trim(s), ...)` |
| `goto continue` | Условный блок `if ... end` |
| `"msg=" .. someNumber` | `"msg=" .. tostring(someNumber)` |
| Regex для парсинга HTML | `html_select` / Jsoup |
| Запросы в цикле без `sleep` | `sleep(300)` между запросами |
| Текст без `<p>` тегов | Обернуть в `<p>...</p>` |
| Игнорирование `r.success` | Всегда проверять перед `r.body` |

---

## 14. Отладка и логирование

```lua
log_info("getCatalogList page=" .. tostring(index + 1))
log_info("items=" .. tostring(#items))
log_error("http failed code=" .. tostring(r.code) .. " url=" .. url)
```

Логи видны в **Android Studio Logcat**, тег `Lua:`.

**Таблица ошибок:**

| Ошибка в логах | Причина |
|---|---|
| `attempt to index ? (a nil value)` | `el:attr()` вместо `html_attr()`, или функции в `return {}` |
| `attempt to concatenate number` | Нужен `tostring()` |
| `Compile error` | Синтаксическая ошибка, незакрытый `end`, `goto` |
| `missing 'getCatalogList'` | Функция определена внутри `return{}`, а не на top-level |
| Пустой каталог | Неверный CSS-селектор или сайт изменил структуру |
| Кривые символы | Нужен `charset = "GBK"` или `string_normalize` |

---

## 15. Регистрация плагина

**Структура репозитория:**
```
repository/
  en/
    novelbin.lua
    index.yaml
  ru/
    ranobelib.lua
    index.yaml
  icons/
    novelbin.png      (128x128 px, PNG)
  index.yaml          (глобальный индекс)
```

**`en/index.yaml`:**
```yaml
- id: novelbin
  name: NovelBin
  version: "1.0.0"
  language: en
  icon: https://raw.githubusercontent.com/user/repo/main/icons/novelbin.png
  codeUrl: https://raw.githubusercontent.com/user/repo/main/en/novelbin.lua
```

**Глобальный `index.yaml`:**
```yaml
count: 5
sources:
  - lang: en
    index: https://raw.githubusercontent.com/user/repo/main/en/index.yaml
  - lang: ru
    index: https://raw.githubusercontent.com/user/repo/main/ru/index.yaml
```

**Иконка:** PNG, минимум 64×64, рекомендуется 128×128.
