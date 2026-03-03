-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "scribblehub"
name     = "ScribbleHub"
version  = "1.0.0"
baseUrl  = "https://www.scribblehub.com/"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/scribblehub.png"

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
  local url = baseUrl .. "series-ranking/?sort=1&order=2&pg=" .. tostring(page)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".search_main_box")) do
    local titleEl = html_select_first(card.html, ".search_title a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, ".search_img img", "src")
      local t = string_clean(titleEl.text)
      if bookUrl ~= "" and t ~= "" then
        table.insert(items, { title = t, url = bookUrl, cover = absUrl(cover) })
      end
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local page = index + 1
  local url = baseUrl .. "?s=" .. url_encode(query) .. "&post_type=fictionposts&paged=" .. tostring(page)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".search_main_box")) do
    local titleEl = html_select_first(card.html, ".search_title a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, ".search_img img", "src")
      local t = string_clean(titleEl.text)
      if bookUrl ~= "" and t ~= "" then
        table.insert(items, { title = t, url = bookUrl, cover = absUrl(cover) })
      end
    end
  end

  return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.fic_title")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local src = html_attr(r.body, ".fic_image img", "src")
  if src == "" then src = html_attr(r.body, ".novel-cover img", "src") end
  if src ~= "" then return absUrl(src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".wi_fic_desc")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (POST AJAX) ───────────────────────────────────────────────────

function getChapterList(bookUrl)
  -- Извлекаем series ID из URL: /series/12345/title/
  local seriesId = string.match(bookUrl, "/series/(%d+)/")
  if not seriesId then
    log_error("scribblehub: cannot extract seriesId from " .. bookUrl)
    return {}
  end

  local ajaxUrl = baseUrl .. "wp-admin/admin-ajax.php"
  local body = "action=wi_getreleases_pagination&pagenum=-1&mypostid=" .. seriesId

  local r = http_post(ajaxUrl, body, {
    headers = {
      ["Content-Type"]    = "application/x-www-form-urlencoded",
      ["X-Requested-With"] = "XMLHttpRequest",
      ["Origin"]          = "https://www.scribblehub.com",
      ["Referer"]         = bookUrl,
      ["Accept"]          = "*/*",
      ["Accept-Language"] = "en-US,en;q=0.9"
    }
  })
  if not r.success then
    log_error("scribblehub: AJAX failed " .. tostring(r.code))
    return {}
  end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, ".toc_w a[href]")) do
    local chUrl = absUrl(a.href)
    local t = string_trim(a.text)
    if chUrl ~= "" then
      table.insert(chapters, { title = t, url = chUrl })
    end
  end

  -- API отдаёт newest-first → разворачиваем
  local reversed = {}
  for i = #chapters, 1, -1 do table.insert(reversed, chapters[i]) end
  return reversed
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".fic_stats span.st_item")
  if el then return string_clean(el.text) end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", ".modern_chapter_ad", "div.modern_chapter_ad")
  local el = html_select_first(cleaned, "#chp_raw")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end