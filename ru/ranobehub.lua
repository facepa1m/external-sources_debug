-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "ranobehub"
name     = "RanobeHub"
version  = "1.0.0"
baseUrl  = "https://ranobehub.org"
language = "ru"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/ranobehub.png"

-- ── Константы ─────────────────────────────────────────────────────────────────

local apiBase = "https://ranobehub.org/api/"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

-- Извлекает числовой ID книги из URL вида:
--   https://ranobehub.org/ranobe/1234  →  "1234"
--   https://ranobehub.org/ranobe/1234-slug  →  "1234"
local function extractId(bookUrl)
  local segment = bookUrl:gsub(baseUrl .. "/ranobe/", ""):match("^([^/?#]+)")
  if not segment then return nil end
  -- ID всегда идёт первым (может быть "1234" или "1234-slug")
  return segment:match("^(%d+)")
end

local function applyStandardContentTransforms(text)
  if not text or text == "" then return "" end
  text = string_normalize(text)
  local domain = baseUrl:gsub("https?://", ""):gsub("^www%.", ""):gsub("/$", "")
  text = regex_replace(text, "(?i)" .. domain .. ".*?\\n", "")
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = string_trim(text)
  return text
end

-- Выбирает лучшее из нескольких вариантов названия (рус > англ > ориг > name)
local function pickTitle(names, fallback)
  if not names then return fallback or "" end
  return names.rus or names.eng or names.original or fallback or ""
end

-- ── Каталог (JSON API) ────────────────────────────────────────────────────────

function getCatalogList(index)
  local page = index + 1
  local url = apiBase .. "search?page=" .. tostring(page) .. "&sort=computed_rating&status=0&take=40"

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local data = json_parse(r.body)
  if not data or not data.resource then return { items = {}, hasNext = false } end

  local items = {}
  for _, novel in ipairs(data.resource) do
    local title = pickTitle(novel.names, novel.name)
    local id    = tostring(novel.id or "")
    local cover = novel.poster and novel.poster.medium or ""
    if title ~= "" and id ~= "" then
      table.insert(items, {
        title = string_clean(title),
        url   = baseUrl .. "/ranobe/" .. id,
        cover = absUrl(cover)
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск (JSON API fulltext, только первая страница) ─────────────────────────

function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end

  local url = apiBase .. "fulltext/global?query=" .. url_encode(query) .. "&take=10"
  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local results = json_parse(r.body)
  if not results then return { items = {}, hasNext = false } end

  local items = {}
  -- Ответ — массив блоков по типу контента; нас интересуют только "ranobe"
  for _, block in ipairs(results) do
    if type(block) == "table" then
      local meta = block.meta
      if meta and meta.key == "ranobe" and block.data then
        for _, novel in ipairs(block.data) do
          local title = pickTitle(novel.names, novel.name)
          local id    = tostring(novel.id or "")
          -- Поиск возвращает /small обложку — заменяем на /medium
          local cover = novel.image and novel.image:gsub("/small", "/medium") or ""
          if title ~= "" and id ~= "" then
            table.insert(items, {
              title = string_clean(title),
              url   = baseUrl .. "/ranobe/" .. id,
              cover = absUrl(cover)
            })
          end
        end
      end
    end
  end

  return { items = items, hasNext = false }
end

-- ── Детали книги (JSON API /api/ranobe/{id}) ──────────────────────────────────

local function fetchBookData(bookUrl)
  local id = extractId(bookUrl)
  if not id then return nil end
  local r = http_get(apiBase .. "ranobe/" .. id)
  if not r.success then return nil end
  local parsed = json_parse(r.body)
  return parsed and parsed.data or nil
end

function getBookTitle(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local title = pickTitle(data.names, data.name)
  return title ~= "" and string_clean(title) or nil
end

function getBookCoverImageUrl(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local cover = data.posters and data.posters.medium or ""
  return cover ~= "" and absUrl(cover) or nil
end

function getBookDescription(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local desc = data.description or ""
  -- Убираем HTML-теги если они есть
  desc = regex_replace(desc, "<[^>]*>", "")
  return string_trim(desc) ~= "" and string_trim(desc) or nil
end

-- ── Список глав (JSON API /api/ranobe/{id}/contents, тома + главы) ────────────

function getChapterList(bookUrl)
  local id = extractId(bookUrl)
  if not id then
    log_error("ranobehub: cannot extract id from " .. bookUrl)
    return {}
  end

  local r = http_get(apiBase .. "ranobe/" .. id .. "/contents")
  if not r.success then
    log_error("ranobehub: contents failed code=" .. tostring(r.code))
    return {}
  end

  local data = json_parse(r.body)
  if not data or not data.volumes then return {} end

  local chapters = {}
  for _, volume in ipairs(data.volumes) do
    local volNum = tostring(volume.num or "")
    if volume.chapters then
      for _, chapter in ipairs(volume.chapters) do
        local chNum  = tostring(chapter.num or "")
        local title  = chapter.name or ("Chapter " .. chNum)
        local chUrl  = baseUrl .. "/ranobe/" .. id .. "/" .. volNum .. "/" .. chNum
        table.insert(chapters, {
          title  = string_clean(title),
          url    = chUrl,
          volume = "Том " .. volNum
        })
      end
    end
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local id = extractId(bookUrl)
  if not id then return nil end
  local r = http_get(apiBase .. "ranobe/" .. id .. "/contents")
  if not r.success then return nil end
  local data = json_parse(r.body)
  if not data or not data.volumes then return nil end
  -- Последний том → последняя глава → её номер
  local volumes = data.volumes
  local lastVol = volumes[#volumes]
  if not lastVol or not lastVol.chapters then return nil end
  local lastCh = lastVol.chapters[#lastVol.chapters]
  return lastCh and tostring(lastCh.num) or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────
--
-- Сайт отдаёт SSR HTML. Контент главы находится в блоке между заголовком
-- и комментариями. Используем несколько селекторов по убыванию точности.

function getChapterText(html, url)
  -- Структура страницы:
  -- <div class="ui text container" data-container="CHAPTER_ID">
  --   <div class="title-wrapper"><h1>Глава N</h1></div>
  --   <p>абзац...</p>  ← параграфы напрямую в контейнере
  --   <p>абзац...</p>
  -- </div>
  -- Следующий <div class="ui text container"> (без data-container) — футер с навигацией.

  -- Убираем скрипты и рекламу до парсинга
  local cleaned = html_remove(html, "script", "style", ".ads-desktop", ".ads-mobile")

  -- Контейнер главы отличается от остальных наличием data-container
  local el = html_select_first(cleaned, "div.ui.text.container[data-container]")
  if el then
    -- Убираем title-wrapper (заголовок) и hoticons внутри контейнера
    local inner = html_remove(el.html, ".title-wrapper", ".chapter-hoticons")
    return applyStandardContentTransforms(html_text(inner))
  end

  return ""
end