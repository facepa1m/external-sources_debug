-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "novel543"
name     = "Novel543"
version  = "1.0.0"
baseUrl  = "https://www.novel543.com/"
language = "zh"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novel543.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local url = "https://www.novel543.com/bookstack/?page=" .. tostring(index + 1)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, li in ipairs(html_select(r.body, "ul.list li.media")) do
    local titleEl = html_select_first(li.html, "div.media-content h3 a")
    local bookUrl = absUrl(html_attr(li.html, "div.media-left a", "href"))
    local cover   = absUrl(html_attr(li.html, "div.media-left img", "src"))
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

-- ── Поиск (только первая страница) ───────────────────────────────────────────

function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end

  local url = "https://www.novel543.com/search/" .. url_encode(query)

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, li in ipairs(html_select(r.body, "ul.list li.media")) do
    local titleEl = html_select_first(li.html, "div.media-content h3 a")
    local bookUrl = absUrl(html_attr(li.html, "div.media-left a", "href"))
    local cover   = absUrl(html_attr(li.html, "div.media-left img", "src"))
    if titleEl and bookUrl ~= "" then
      table.insert(items, {
        title = string_clean(titleEl.text),
        url   = bookUrl,
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
  local el = html_select_first(r.body, "h1.title")
  if el then return string_clean(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".cover img")
  if el then return absUrl(el.src) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.intro")
  if el then return string_clean(el.text) end
  return nil
end

-- ── Список глав (AJAX GET на /dir) ────────────────────────────────────────────

function getChapterList(bookUrl)
  local dirUrl = bookUrl:gsub("/$", "") .. "/dir"
  local r = http_get(dirUrl)
  if not r.success then return {} end

  local chapters = {}
  for _, a in ipairs(html_select(r.body, "ul.all li a")) do
    local chUrl = absUrl(a.href)
    if chUrl ~= "" then
      table.insert(chapters, {
        title = string_clean(a.text),
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
  local el = html_select_first(r.body, "p.meta span.iconf:last-child")
  if el then return string_clean(el.text) end
  return nil
end

-- ── Текст главы (многостраничный) ────────────────────────────────────────────

function getChapterText(html, url)
  -- Извлекаем имя файла: "https://.../8096_1.html" → "8096_1"
  local chapterFile = string.match(url, "/([^/]+)%.html$") or ""
  local baseDir     = string.match(url, "^(.+/)") or ""

  -- Получаем текст первой страницы
  local cleaned = html_remove(html, "div.gadBlock", "script", "ins", ".ads", ".ad", "p:contains(溫馨提示)")
  local el = html_select_first(cleaned, "div.content")
  local parts = {}
  if el then table.insert(parts, html_text(el.html)) end

  -- Ищем подстраницы: {chapterFile}_2.html, _3.html, ...
  local currentHtml = html
  for _ = 1, 20 do
    -- Ищем ссылку вида {chapterFile}_N.html
    local subUrl = nil
    for _, a in ipairs(html_select(currentHtml, "a[href]")) do
      local href = a.href
      local fname = string.match(href, "/([^/]+)$") or ""
      -- паттерн: chapterFile + "_" + цифры + ".html"
      if string.match(fname, "^" .. chapterFile:gsub("%-", "%%-") .. "_%d+%.html$") then
        subUrl = absUrl(href)
        break
      end
    end

    if not subUrl then break end

    local pr = http_get(subUrl)
    if not pr.success then break end

    local subCleaned = html_remove(pr.body, "div.gadBlock", "script", "ins", ".ads", ".ad", "p:contains(溫馨提示)")
    local subEl = html_select_first(subCleaned, "div.content")
    if subEl then table.insert(parts, html_text(subEl.html)) end

    currentHtml = pr.body
  end

  return table.concat(parts, "\n\n")
end