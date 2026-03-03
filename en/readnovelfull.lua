-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "read_novel_full"
name     = "ReadNovelFull"
version  = "1.0.0"
baseUrl  = "https://readnovelfull.com/"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/readnovelfull.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

local function transformCover(coverUrl)
  if not coverUrl or coverUrl == "" then return "" end
  coverUrl = regex_replace(coverUrl, "t-200x89", "t-300x439")
  coverUrl = regex_replace(coverUrl, "t-80x113", "t-300x439")
  return coverUrl
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

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local catalogBase = baseUrl .. "novel-list/most-popular-novel"
  local url = index == 0 and catalogBase or (catalogBase .. "?page=" .. tostring(index + 1))

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, row in ipairs(html_select(r.body, ".col-novel-main .row")) do
    local titleEl = html_select_first(row.html, ".novel-title a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(row.html, "div.col-xs-3 > div > img", "src")
      if cover == "" then cover = html_attr(row.html, "div.col-xs-3 > div > img", "data-src") end
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = transformCover(absUrl(cover))
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local searchBase = baseUrl:gsub("/$", "") .. "/novel-list/search?keyword=" .. url_encode(query)
  local url = index == 0 and searchBase or (searchBase .. "&page=" .. tostring(index + 1))

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, row in ipairs(html_select(r.body, ".col-novel-main .row")) do
    local titleEl = html_select_first(row.html, ".novel-title a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(row.html, "div.col-xs-3 > div > img", "src")
      if cover == "" then cover = html_attr(row.html, "div.col-xs-3 > div > img", "data-src") end
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
        cover = transformCover(absUrl(cover))
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h3.title")
  return el and string_clean(el.text) or nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local cover = html_attr(r.body, ".book img[src]", "src")
  if cover == "" then return nil end
  return transformCover(absUrl(cover))
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "#tab-description")
  return el and string_trim(el.text) or nil
end

-- ── Список глав (AJAX) ────────────────────────────────────────────────────────

function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then
    log_error("readnovelfull: getChapterList failed for " .. bookUrl)
    return {}
  end

  -- novelId хранится в атрибуте data-novel-id элемента #rating
  local novelId = html_attr(r.body, "#rating[data-novel-id]", "data-novel-id")
  if novelId == "" then
    log_error("readnovelfull: novelId not found at " .. bookUrl)
    return {}
  end

  local ajaxUrl = baseUrl:gsub("/$", "") .. "/ajax/chapter-archive?novelId=" .. novelId
  local ar = http_get(ajaxUrl)
  if not ar.success then
    log_error("readnovelfull: AJAX failed code=" .. tostring(ar.code))
    return {}
  end

  local chapters = {}
  for _, a in ipairs(html_select(ar.body, "a[href]")) do
    local title = a.title
    if not title or title == "" then title = string_trim(a.text) end
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      table.insert(chapters, { title = string_clean(title), url = chUrl })
    end
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".l-chapter a.chapter-title")
  return el and el.href or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", ".ads", ".advertisement", "h3", ".chapter-warning", ".ad-insert")
  local el = html_select_first(cleaned, "#chr-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end