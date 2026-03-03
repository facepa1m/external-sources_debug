-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "freewebnovel"
name     = "FreeWebNovel"
version  = "1.0.0"
baseUrl  = "https://freewebnovel.com"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/freewebnovel.png"

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
  text = regex_replace(text, "(?im)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = string_trim(text)
  return text
end

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local page = index + 1
  local url = baseUrl .. "/completed-novel/" .. tostring(page)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, row in ipairs(html_select(r.body, ".ul-list1 .li-row")) do
    local titleEl = html_select_first(row.html, ".tit a")
    local cover   = absUrl(html_attr(row.html, ".pic img", "src"))
    if titleEl then
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = absUrl(titleEl.href),
        cover = cover
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск (POST, одна страница) ───────────────────────────────────────────────

function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end

  local r = http_post(
    baseUrl .. "/search",
    "searchkey=" .. url_encode(query),
    {
      headers = {
        ["Content-Type"]           = "application/x-www-form-urlencoded",
        ["Referer"]                = baseUrl .. "/",
        ["Accept"]                 = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        ["Accept-Language"]        = "en-US,en;q=0.5",
        ["Accept-Encoding"]        = "gzip, deflate",
        ["Connection"]             = "keep-alive",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Cache-Control"]          = "max-age=0"
      }
    }
  )
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, row in ipairs(html_select(r.body, ".serach-result .li-row, .ul-list1 .li-row")) do
    local titleEl = html_select_first(row.html, ".tit a")
    local cover   = absUrl(html_attr(row.html, ".pic img", "src"))
    if titleEl then
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = absUrl(titleEl.href),
        cover = cover
      })
    end
  end

  return { items = items, hasNext = false }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h1.tit")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".pic img")
  if el then return absUrl(el.src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".m-desc .txt")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (NONE, порядок не меняется) ───────────────────────────────────

function getChapterList(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, "#idData li a")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      -- title берётся из атрибута title, не из текста
      local title = a:attr("title")
      if not title or title == "" then title = string_clean(a.text) end
      table.insert(chapters, {
        title = string_clean(title),
        url   = chUrl
      })
    end
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".m-newest1 ul.ul-list5 li:first-child a")
  if el then return el.href end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads", ".advertisement", "h4", "sub")
  local el = html_select_first(cleaned, "div.txt")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end