-- ── Метаданные ────────────────────────────────────────────────────────────────
id        = "NovLove"
name      = "NovLove"
version   = "1.0.0"
baseUrl   = "https://novlove.com/"
language  = "en"
icon      = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novlove.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

local function transformCoverUrl(coverUrl, bookUrl)
  if not bookUrl or bookUrl == "" then return coverUrl end
  local slug = bookUrl:match("([^/]+)$"):gsub("%.html$", "")
  return "https://images.novelbin.me/novel/" .. slug .. ".jpg"
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

local function parseCatalogItems(body, useDataSrc)
  local items = {}
  for _, row in ipairs(html_select(body, ".col-novel-main .row")) do
    local titleEl = html_select_first(row.html, ".novel-title a")
    if titleEl then
      local currentUrl = absUrl(titleEl.href)
      local cover = ""
      if useDataSrc then
        cover = html_attr(row.html, "img.cover", "data-src")
      end
      if cover == "" then
        cover = html_attr(row.html, "img.cover", "src")
      end
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = currentUrl,
        cover = transformCoverUrl(cover, currentUrl)
      })
    end
  end
  return items
end

-- ── Каталог ─────────────────────────────────────────────────────────────────--

function getCatalogList(index)
  local page = index + 1
  local url = baseUrl .. "sort/nov-love-daily-update"
  if page > 1 then url = url .. "?page=" .. page end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = parseCatalogItems(r.body, true)
  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local page = index + 1
  local url = baseUrl .. "search?keyword=" .. url_encode(query)
  if page > 1 then url = url .. "&page=" .. page end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = parseCatalogItems(r.body, false)
  return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "h3.title")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local url = html_attr(r.body, "meta[itemprop='image']", "content")
  if url ~= "" then return absUrl(url) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".desc-text")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (AJAX_BASED) ──────────────────────────────────────────────────

function getChapterList(bookUrl)
  local novelId = bookUrl:gsub("/$", ""):match("([^/]+)$")
  if not novelId then
    log_error("getChapterList: cannot extract novelId from " .. bookUrl)
    return {}
  end
  
  local ajaxUrl = baseUrl:gsub("/$", "") .. "/ajax/chapter-archive?novelId=" .. novelId
  local r = http_get(ajaxUrl)
  if not r.success then
    log_error("getChapterList: AJAX failed code=" .. tostring(r.code))
    return {}
  end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, "a[href*='/chapter']")) do
    local title = string_trim(a.text)
    if title == "" then title = a.href end
    table.insert(chapters, { title = title, url = a.href })
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".l-chapter a.chapter-title")
  if el then return el.href end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads", ".advertisement", 
                              ".social-share", ".disqus", ".comments", 
                              ".c-message", ".nav-next", ".nav-previous")
  local el = html_select_first(cleaned, "#chr-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end