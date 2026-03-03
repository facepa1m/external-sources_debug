-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "royal_road"
name     = "Royal Road"
version  = "1.0.0"
baseUrl  = "https://www.royalroad.com"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/royalroad.png"

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
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = regex_replace(text, "(?im)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = string_trim(text)
  return text
end

-- ── Каталог (best-rated, постраничный) ────────────────────────────────────────

function getCatalogList(index)
  local url
  if index == 0 then
    url = baseUrl .. "/fictions/best-rated"
  else
    url = baseUrl .. "/fictions/best-rated?page=" .. tostring(index + 1)
  end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".fiction-list-item")) do
    local titleEl = html_select_first(card.html, "h2 a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, "img", "src")
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = absUrl(cover)
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local page = index + 1
  local url = baseUrl .. "/fictions/search?title=" .. url_encode(query) .. "&page=" .. tostring(page)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".fiction-list-item")) do
    local titleEl = html_select_first(card.html, "h2 a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, "img", "src")
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = absUrl(cover)
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h1.font-white")
  return el and string_clean(el.text) or nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cover = html_attr(r.body, ".cover-art-container img[src]", "src")
  if cover == "" then return nil end
  return absUrl(cover)
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".description")
  return el and string_trim(el.text) or nil
end

-- ── Список глав (NONE — всё на странице книги) ────────────────────────────────

function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then
    log_error("royalroad: getChapterList failed for " .. bookUrl)
    return {}
  end

  local chapters = {}
  -- Таблица глав: tr.chapter-row, первая ячейка содержит ссылку
  for _, a in ipairs(html_select(r.body, "tr.chapter-row td:first-child a[href]")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      local title = a.title
      if not title or title == "" then title = string_trim(a.text) end
      table.insert(chapters, { title = string_clean(title), url = chUrl })
    end
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  -- Последняя метка (дата/номер) в заголовке portlet — меняется при новых главах
  local el = html_select_first(r.body, ".portlet-title .actions .label")
  return el and string_clean(el.text) or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", "a", ".ads-title")
  local el = html_select_first(cleaned, ".chapter-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end