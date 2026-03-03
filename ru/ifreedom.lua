-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "ifreedom"
name     = "iFreedom"
version  = "1.0.0"
baseUrl  = "https://ifreedom.su/"
language = "ru"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/ifreedom.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

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

-- ── Каталог ───────────────────────────────────────────────────────────────────

local SORT_PARAM = "%D0%9F%D0%BE+%D1%80%D0%B5%D0%B9%D1%82%D0%B8%D0%BD%D0%B3%D1%83"

function getCatalogList(index)
  local url = baseUrl .. "vse-knigi/?sort=" .. SORT_PARAM .. "&bpage=" .. tostring(index + 1)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".booksearch .item-book-slide")) do
    local titleEl = html_select_first(card.html, ".block-book-slide-title")
    local bookUrl = absUrl(html_attr(card.html, "a", "href"))
    local cover   = absUrl(html_attr(card.html, "img", "src"))
    if titleEl and bookUrl ~= "" then
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = cover
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local url = baseUrl .. "vse-knigi/?searchname=" .. url_encode(query) .. "&bpage=" .. tostring(index + 1)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".booksearch .item-book-slide")) do
    local titleEl = html_select_first(card.html, ".block-book-slide-title")
    local bookUrl = absUrl(html_attr(card.html, "a", "href"))
    local cover   = absUrl(html_attr(card.html, "img", "src"))
    if titleEl and bookUrl ~= "" then
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = cover
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h1")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.book-img.block-book-slide-img > img")
  if el then return absUrl(el.src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "[data-name=\"Описание\"]")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (NONE + reverseChapters) ─────────────────────────────────────

function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, "div.chapterinfo a")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      table.insert(chapters, {
        title = string_clean(a.text),
        url   = chUrl
      })
    end
  end

  local reversed = {}
  for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
  return reversed
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.book-info-list:has(svg.icon-tabler-list-check) div")
  if el then return string_clean(el.text) end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads", ".pc-adv", ".mob-adv")
  local el = html_select_first(cleaned, ".chapter-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end