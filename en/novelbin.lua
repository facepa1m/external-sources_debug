-- NovelBin source plugin
-- Based on the original Kotlin implementation

id       = "NovelBin"
name     = "Novel Bin"
version  = "1.0.1"
baseUrl  = "https://novelbin.com/"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novelbin.png"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function buildCatalogUrl(index)
  local page = index + 1
  if page == 1 then
    return baseUrl .. "sort/top-view-novel"
  else
    return baseUrl .. "sort/top-view-novel?page=" .. page
  end
end

local function buildSearchUrl(index, query)
  local page = index + 1
  if page == 1 then
    return baseUrl .. "search?keyword=" .. url_encode(query)
  else
    return baseUrl .. "search?keyword=" .. url_encode(query) .. "&page=" .. page
  end
end

local function parseCatalogItems(body)
  local items = {}
  local rows = html_select(body, ".col-novel-main .row")
  for _, row in ipairs(rows) do
    local titleEls = html_select(row.html, ".novel-title a")
    local coverEls = html_select(row.html, "img[data-src]")
    if titleEls[1] then
      local cover = ""
      if coverEls[1] then
        cover = coverEls[1]:attr("data-src")
        if cover == "" then cover = coverEls[1].src end
      end
      table.insert(items, {
        title = string_trim(titleEls[1].text),
        url   = titleEls[1].href,
        cover = cover
      })
    end
  end
  return items
end

-- ── Catalog ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local url = buildCatalogUrl(index)
  local r = http_get(url)
  if not r.success then
    log_error("getCatalogList failed: " .. url .. " code=" .. r.code)
    return { items = {}, hasNext = false }
  end
  local items = parseCatalogItems(r.body)
  return { items = items, hasNext = #items > 0 }
end

function getCatalogSearch(index, query)
  local url = buildSearchUrl(index, query)
  local r = http_get(url)
  if not r.success then
    log_error("getCatalogSearch failed: " .. url)
    return { items = {}, hasNext = false }
  end
  -- Search page uses different img selector (src instead of data-src)
  local items = {}
  local rows = html_select(r.body, ".col-novel-main .row")
  for _, row in ipairs(rows) do
    local titleEls = html_select(row.html, ".novel-title a")
    local coverEls = html_select(row.html, "img[src]")
    if titleEls[1] then
      table.insert(items, {
        title = string_trim(titleEls[1].text),
        url   = titleEls[1].href,
        cover = coverEls[1] and coverEls[1].src or ""
      })
    end
  end
  return { items = items, hasNext = #items > 0 }
end

-- ── Book metadata ─────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, "h3.title")
  return el[1] and string_trim(el[1].text) or nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, "meta[property='og:image']")
  return el[1] and el[1]:attr("content") or nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, "div.desc-text")
  return el[1] and string_trim(el[1].text) or nil
end

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, ".l-chapter a.chapter-title")
  return el[1] and el[1].href or nil
end

-- ── Chapter list (AJAX) ───────────────────────────────────────────────────────

function getChapterList(bookUrl)
  -- Step 1: get novelId from og:url meta tag
  local r = http_get(bookUrl)
  if not r.success then
    log_error("getChapterList: failed to load book page " .. bookUrl)
    return {}
  end

  local metas = html_select(r.body, "meta[property='og:url']")
  if not metas[1] then
    log_error("getChapterList: no og:url meta on " .. bookUrl)
    return {}
  end

  local ogUrl = metas[1]:attr("content")
  -- Extract last path segment as novelId  e.g. ".../novel/some-novel-slug" → "some-novel-slug"
  local novelId = regex_match(ogUrl, "/([^/?#]+)/*$")
  if not novelId[1] then
    log_error("getChapterList: cannot extract novelId from og:url=" .. ogUrl)
    return {}
  end

  -- Step 2: AJAX chapter list
  local ajaxUrl = "https://novelbin.com/ajax/chapter-archive?novelId=" .. novelId[1]
  log_info("getChapterList: AJAX url=" .. ajaxUrl)

  local ar = http_get(ajaxUrl)
  if not ar.success then
    log_error("getChapterList: AJAX failed, code=" .. ar.code)
    return {}
  end

  local chapters = {}
  local links = html_select(ar.body, "ul.list-chapter li a")
  for _, a in ipairs(links) do
    table.insert(chapters, {
      title = string_trim(a:attr("title") ~= "" and a:attr("title") or a.text),
      url   = a.href
    })
  end

  log_info("getChapterList: loaded " .. #chapters .. " chapters")
  return chapters
end

-- ── Chapter text ──────────────────────────────────────────────────────────────

function getChapterText(html)
  -- Remove ads and noise
  local cleaned = html_remove(html, "script", ".ads", "h3", ".chapter-warning", ".ad-insert")
  local content = html_select(cleaned, "#chr-content")
  if content[1] then
    return html_text(content[1].html)
  end
  -- Fallback selectors
  local fallback = html_select(cleaned, ".chr-c, #chapter-content, .chapter-content")
  if fallback[1] then
    return html_text(fallback[1].html)
  end
  return ""
end