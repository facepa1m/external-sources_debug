-- 69shuba source plugin
-- Compatible with LuaJ (Lua 5.1) — strict top-level functions, no colon methods

id       = "shuba69"
name     = "69shuba"
version  = "1.0.0"
baseUrl  = "https://www.69shuba.com/"
language = "zh"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/69shuba.png"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function cleanText(text)
  return string_trim(text)
end

-- ── Catalog ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local page = index + 1
  local url = baseUrl .. "novels/monthvisit_0_0_" .. tostring(page) .. ".htm"
  
  -- Используем кодировку GBK для китайского сайта
  local r = http_get(url, { charset = "GBK" })
  if not r.success then 
    log_error("getCatalogList failed: " .. url .. " code=" .. tostring(r.code))
    return { items = {}, hasNext = false } 
  end

  local items = {}
  local rows = html_select(r.body, "ul#article_list_content li")
  for _, row in ipairs(rows) do
    local titleEl = html_select_first(row.html, "div.newnav h3 a")
    if titleEl then
      local cover = html_attr(row.html, "a.imgbox img", "data-src")
      table.insert(items, {
        title = cleanText(titleEl.text),
        url   = titleEl.href,
        cover = cover
      })
    end
  end

  return { items = items, hasNext = #items > 0 }
end

function getCatalogSearch(index, query)
  -- Сайт поддерживает поиск только на первой странице через POST
  if index > 0 then return { items = {}, hasNext = false } end

  local searchUrl = "https://www.69shuba.com/modules/article/search.php"
  -- Важно: кодируем запрос в GBK перед отправкой
  local encodedQuery = url_encode_charset(query, "GBK")
  local payload = "searchkey=" .. encodedQuery .. "&searchtype=all"
  
  local r = http_post(searchUrl, payload, {
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    charset = "GBK"
  })

  if not r.success then 
    log_error("getCatalogSearch failed")
    return { items = {}, hasNext = false } 
  end

  local items = {}
  local rows = html_select(r.body, "div.newbox ul li")
  for _, row in ipairs(rows) do
    local titleEl = html_select_first(row.html, "h3 a:last-child")
    if titleEl then
      local cover = html_attr(row.html, "a.imgbox img", "data-src")
      table.insert(items, {
        title = cleanText(titleEl.text),
        url   = titleEl.href,
        cover = cover
      })
    end
  end

  return { items = items, hasNext = false }
end

-- ── Book metadata ─────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl, { charset = "GBK" })
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.booknav2 h1 a")
  if el then return cleanText(el.text) end
  return nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl, { charset = "GBK" })
  if not r.success then return nil end
  local url = html_attr(r.body, "div.bookimg2 img", "src")
  if url ~= "" then return url end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl, { charset = "GBK" })
  if not r.success then return nil end
  local el = html_select_first(r.body, "div.navtxt")
  if el then return cleanText(el.text) end
  return nil
end

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl, { charset = "GBK" })
  if not r.success then return nil end
  -- Селектор из Kotlin конфига для хэша обновлений
  local el = html_select_first(r.body, ".infolist li:nth-child(2)")
  if el then return el.text end
  return nil
end

-- ── Chapter list ──────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
  -- Трансформация URL: /txt/123.htm -> /123/ для получения списка глав
  local listUrl = regex_replace(bookUrl, "/txt/", "/")
  listUrl = regex_replace(listUrl, "%.htm", "/")

  local r = http_get(listUrl, { charset = "GBK" })
  if not r.success then return {} end

  local chapters = {}
  local links = html_select(r.body, "div#catalog ul li a")
  
  -- Сайт отдает главы в обратном порядке (новые сверху), 
  -- переворачиваем для читалки
  for i = #links, 1, -1 do
    local a = links[i]
    table.insert(chapters, {
      title = cleanText(a.text),
      url   = a.href
    })
  end

  return chapters
end

-- ── Chapter text ──────────────────────────────────────────────────────────────

function getChapterText(html)
  -- Удаляем лишние элементы перед извлечением текста
  local cleaned = html_remove(html, "h1", "div.txtinfo", "div.bottom-ad", "div.bottem2", ".visible-xs", "script")
  local el = html_select_first(cleaned, "div.txtnav")
  
  -- html_text возвращает текст, обернутый в <p> для корректного отображения
  if el then return html_text(el.html) end
  return ""
end