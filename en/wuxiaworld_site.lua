-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "wuxia_world_site"
name     = "WuxiaWorld.site"
version  = "1.0.0"
baseUrl  = "https://wuxiaworld.site/"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wuxiaworld.site.png"

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
  local url = "https://wuxiaworld.site/novel/?m_orderby=trending"
  if page > 1 then url = url .. "&page=" .. tostring(page) end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".page-item-detail")) do
    local titleEl = html_select_first(card.html, ".post-title h3 a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, ".c-image-hover img", "data-src")
      if cover == "" then cover = html_attr(card.html, ".c-image-hover img", "src") end
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
  local url
  if page == 1 then
    url = baseUrl .. "?s=" .. url_encode(query) .. "&post_type=wp-manga"
  else
    url = baseUrl .. "page/" .. tostring(page) .. "/?s=" .. url_encode(query) .. "&post_type=wp-manga"
  end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, ".c-tabs-item__content")) do
    local titleEl = html_select_first(card.html, ".post-title h3 a")
    if titleEl then
      local bookUrl = absUrl(titleEl.href)
      local cover   = html_attr(card.html, ".c-image-hover img", "data-src")
      if cover == "" then cover = html_attr(card.html, ".c-image-hover img", "src") end
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
  local el = html_select_first(r.body, "h1")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local src = html_attr(r.body, ".summary_image img", "data-src")
  if src == "" then src = html_attr(r.body, ".summary_image img", "src") end
  if src ~= "" then return absUrl(src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".summary__content")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (POST AJAX) ───────────────────────────────────────────────────

function getChapterList(bookUrl)
  local ajaxUrl = bookUrl:gsub("/?$", "") .. "/ajax/chapters/"

  local r = http_post(ajaxUrl, "", {
    headers = {
      ["Referer"] = bookUrl,
      ["X-Requested-With"] = "XMLHttpRequest"
    }
  })
  if not r.success then
    log_error("wuxiaworld.site: AJAX failed " .. tostring(r.code))
    return {}
  end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, "li.wp-manga-chapter a[href]")) do
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
  local el = html_select_first(r.body, "#btn-read-first")
  if el then return el.href end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", ".ads", ".advertisement", ".social-share")
  local el = html_select_first(cleaned, ".reading-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end