-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "ranobelib"
name     = "RanobeLib"
version  = "1.0.0"
baseUrl  = "https://ranobelib.me/"
language = "ru"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/ranobelib.png"

-- ── Константы ─────────────────────────────────────────────────────────────────

local apiBase  = "https://api.cdnlibs.org/api/manga/"
local siteId   = "3"
local apiHeaders = { ["Site-Id"] = siteId }

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

-- Прокси wsrv.nl для обхода hotlink-защиты CDN
local function proxyCover(raw)
  if not raw or raw == "" then return "" end
  if not string_starts_with(raw, "http") then return raw end
  local stripped = regex_replace(raw, "^https?://", "")
  return "https://images.weserv.nl/?url=" .. url_encode(stripped) .. "&https=1"
end

local function applyStandardContentTransforms(text)
  if not text or text == "" then return "" end
  text = string_normalize(text)
  local domain = baseUrl:gsub("https?://", ""):gsub("^www%.", ""):gsub("/$", "")
  text = regex_replace(text, "(?i)" .. domain .. ".*?\\n", "")
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = string_trim(text)
  return text
end

-- Выбирает лучшее из нескольких вариантов названия
local function pickTitle(data)
  return data.rus_name or data.eng_name or data.name or ""
end

-- Извлекает slug книги из URL вида:
--   https://ranobelib.me/ru/book/12345--slug  →  "12345--slug"
--   https://ranobelib.me/ru/12345--slug        →  "12345--slug"
local function extractSlug(bookUrl)
  -- Убираем trailing slash и берём последний сегмент пути
  local clean = bookUrl:gsub("/?$", "")
  return clean:match("([^/]+)$")
end

-- ── Вложенный доступ к JSON по "dot.path" ─────────────────────────────────────
-- Используется для путей вида "cover.default", "meta.has_next_page"
local function getPath(tbl, path)
  if not tbl or not path then return nil end
  local cur = tbl
  for key in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[key]
  end
  return cur
end

-- ── Каталог (JSON API) ────────────────────────────────────────────────────────

function getCatalogList(index)
  local page = index + 1
  local url = apiBase .. "?site_id[0]=" .. siteId ..
              "&page=" .. tostring(page) ..
              "&sort_by=rating_score&sort_type=desc&chapters[min]=1"

  local r = http_get(url, { headers = apiHeaders })
  if not r.success then return { items = {}, hasNext = false } end

  local parsed = json_parse(r.body)
  if not parsed or not parsed.data then return { items = {}, hasNext = false } end

  local items = {}
  for _, novel in ipairs(parsed.data) do
    local title = pickTitle(novel)
    local slug  = novel.slug or novel.slug_url or ""
    local cover = getPath(novel, "cover.default") or ""
    if title ~= "" and slug ~= "" then
      table.insert(items, {
        title = string_clean(title),
        url   = baseUrl .. "ru/" .. slug,
        cover = proxyCover(cover)
      })
    end
  end

  local hasNext = getPath(parsed, "meta.has_next_page")
  return { items = items, hasNext = hasNext == true or #items > 0 }
end

-- ── Поиск (JSON API) ──────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local page = index + 1
  local url = apiBase .. "?site_id[0]=" .. siteId ..
              "&page=" .. tostring(page) ..
              "&q=" .. url_encode(query)

  local r = http_get(url, { headers = apiHeaders })
  if not r.success then return { items = {}, hasNext = false } end

  local parsed = json_parse(r.body)
  if not parsed or not parsed.data then return { items = {}, hasNext = false } end

  local items = {}
  for _, novel in ipairs(parsed.data) do
    local title = pickTitle(novel)
    local slug  = novel.slug_url or novel.slug or ""
    local cover = getPath(novel, "cover.default") or ""
    if title ~= "" and slug ~= "" then
      table.insert(items, {
        title = string_clean(title),
        url   = baseUrl .. "ru/" .. slug,
        cover = proxyCover(cover)
      })
    end
  end

  local hasNext = getPath(parsed, "meta.has_next_page")
  return { items = items, hasNext = hasNext == true }
end

-- ── Детали книги (JSON API /api/manga/{slug}) ─────────────────────────────────

local function fetchBookJson(bookUrl)
  local slug = extractSlug(bookUrl)
  if not slug then return nil end
  local r = http_get(apiBase .. slug, { headers = apiHeaders })
  if not r.success then return nil end
  local parsed = json_parse(r.body)
  return parsed and parsed.data or nil
end

function getBookTitle(bookUrl)
  local data = fetchBookJson(bookUrl)
  if not data then return nil end
  -- parseBookData в KT читает data.names.rus/.eng
  local names = data.names
  local title
  if names then
    title = names.rus or names.eng or data.rus_name or data.name
  else
    title = data.rus_name or data.eng_name or data.name
  end
  return title and string_clean(title) or nil
end

function getBookCoverImageUrl(bookUrl)
  local data = fetchBookJson(bookUrl)
  if not data then return nil end
  local cover = getPath(data, "cover.default") or ""
  return cover ~= "" and proxyCover(cover) or nil
end

function getBookDescription(bookUrl)
  local data = fetchBookJson(bookUrl)
  if not data then return nil end
  local desc = data.summary or data.description or ""
  return string_trim(desc) ~= "" and string_trim(desc) or nil
end

-- ── Список глав (JSON API /api/manga/{slug}/chapters) ────────────────────────

function getChapterList(bookUrl)
  local slug = extractSlug(bookUrl)
  if not slug then
    log_error("ranobelib: cannot extract slug from " .. bookUrl)
    return {}
  end

  local r = http_get(apiBase .. slug .. "/chapters", { headers = apiHeaders })
  if not r.success then
    log_error("ranobelib: chapters failed code=" .. tostring(r.code))
    return {}
  end

  local parsed = json_parse(r.body)
  if not parsed or not parsed.data then return {} end

  -- Собираем главы с индексом для сортировки
  local raw = {}
  for _, chapter in ipairs(parsed.data) do
    local volume = tostring(chapter.volume or "")
    local number = tostring(chapter.number or "")
    local name   = chapter.name and chapter.name ~= "" and chapter.name or nil
    local bid    = "0"
    -- branch_id берём из первой ветки
    if chapter.branches and chapter.branches[1] then
      bid = tostring(chapter.branches[1].branch_id or "0")
    end

    local title = "Том " .. volume .. " Глава " .. number
    if name then title = title .. " " .. name end

    local chUrl = baseUrl .. "ru/" .. slug .. "/read/v" .. volume .. "/c" .. number
    if bid ~= "0" then chUrl = chUrl .. "?bid=" .. bid end

    table.insert(raw, {
      result = {
        title  = string_clean(title),
        url    = chUrl,
        volume = "Том " .. volume
      },
      index = chapter.index or #raw + 1
    })
  end

  -- Сортировка по index (API может отдавать не по порядку)
  table.sort(raw, function(a, b) return a.index < b.index end)

  local chapters = {}
  for _, item in ipairs(raw) do
    table.insert(chapters, item.result)
  end
  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local slug = extractSlug(bookUrl)
  if not slug then return nil end
  local r = http_get(apiBase .. slug .. "/chapters", { headers = apiHeaders })
  if not r.success then return nil end
  local parsed = json_parse(r.body)
  if not parsed or not parsed.data then return nil end
  local chapters = parsed.data
  local last = chapters[#chapters]
  return last and tostring(last.item_number or last.number) or nil
end

-- ── JSON → HTML (рендер структурированного контента главы) ───────────────────
--
-- RanobeLib отдаёт главу как JSON-дерево ProseMirror (type="doc").
-- Рекурсивно обходим узлы и строим HTML.

local function jsonToHtml(nodes, attachMap)
  if not nodes then return "" end
  local parts = {}

  for _, node in ipairs(nodes) do
    if type(node) ~= "table" then break end
    local ntype   = node.type or ""
    local content = node.content
    local inner   = jsonToHtml(content, attachMap)

    if ntype == "text" then
      local text = node.text or ""
      -- Применяем marks (bold, italic, underline)
      if node.marks then
        for _, mark in ipairs(node.marks) do
          local mt = mark.type or ""
          if mt == "bold"      then text = "<b>"  .. text .. "</b>"  end
          if mt == "italic"    then text = "<i>"  .. text .. "</i>"  end
          if mt == "underline" then text = "<u>"  .. text .. "</u>"  end
        end
      end
      table.insert(parts, text)

    elseif ntype == "paragraph"      then table.insert(parts, "<p>"           .. inner .. "</p>")
    elseif ntype == "heading"        then table.insert(parts, "<h2>"          .. inner .. "</h2>")
    elseif ntype == "listItem"       then table.insert(parts, "<li>"          .. inner .. "</li>")
    elseif ntype == "bulletList"     then table.insert(parts, "<ul>"          .. inner .. "</ul>")
    elseif ntype == "orderedList"    then table.insert(parts, "<ol>"          .. inner .. "</ol>")
    elseif ntype == "blockquote"     then table.insert(parts, "<blockquote>"  .. inner .. "</blockquote>")
    elseif ntype == "hardBreak"      then table.insert(parts, "<br>")
    elseif ntype == "horizontalRule" then table.insert(parts, "<hr>")

    elseif ntype == "image" then
      local attrs = node.attrs or {}
      -- ID может быть прямо в attrs или в attrs.images[1]
      local imgId = attrs.id
      if not imgId and attrs.images and attrs.images[1] then
        imgId = attrs.images[1].id
      end
      local imgUrl = (imgId and attachMap[tostring(imgId)]) or attrs.src or ""
      if imgUrl ~= "" then
        -- Прокси для изображений контента
        local stripped = regex_replace(imgUrl, "^https?://", "")
        local proxied  = "https://images.weserv.nl/?url=" .. url_encode(stripped) .. "&https=1"
        table.insert(parts, "<img src=\"" .. proxied .. "\">")
      end

    else
      -- Неизвестный узел-контейнер — просто обходим детей
      if inner ~= "" then table.insert(parts, inner) end
    end
  end

  return table.concat(parts, "")
end

-- ── Текст главы (JSON API /api/manga/{slug}/chapter?...) ─────────────────────

function getChapterText(html, chapterUrl)
  if not chapterUrl or chapterUrl == "" then return "" end

  -- URL вида: https://ranobelib.me/ru/SLUG/read/vVOL/cNUM[?bid=BID]
  local slug   = chapterUrl:match("/ru/([^/]+)/read/")
  local volume = chapterUrl:match("/v([^/]+)/c")
  local number = chapterUrl:match("/c([^?]+)")
  local bid    = chapterUrl:match("[?&]bid=([^&]+)")

  if not slug or not volume or not number then
    log_error("ranobelib: cannot parse chapterUrl: " .. chapterUrl)
    return ""
  end

  local apiUrl = apiBase .. slug .. "/chapter?volume=" .. volume .. "&number=" .. number
  if bid then apiUrl = apiUrl .. "&branch_id=" .. bid end

  local r = http_get(apiUrl, { headers = apiHeaders })
  if not r.success then
    log_error("ranobelib: chapter API failed code=" .. tostring(r.code))
    return ""
  end

  local parsed = json_parse(r.body)
  if not parsed or not parsed.data then return "" end

  local data        = parsed.data
  local contentNode = data.content
  local attachments = data.attachments

  -- Строим карту id → url для вложений (изображений)
  local attachMap = {}
  if attachments then
    for _, att in ipairs(attachments) do
      local attId  = tostring(att.id   or att.name or "")
      local attUrl = att.url or ""
      if attId ~= "" and attUrl ~= "" then
        attachMap[attId] = attUrl
      end
    end
  end

  local resultHtml = ""

  if type(contentNode) == "table" and contentNode.type == "doc" then
    -- ProseMirror JSON-дерево
    resultHtml = jsonToHtml(contentNode.content, attachMap)

  elseif type(contentNode) == "string" and contentNode ~= "" then
    -- Уже HTML-строка — проксируем src изображений
    resultHtml = regex_replace(
      contentNode,
      'src="([^"]+)"',
      function(m)
        local raw = m:match('src="([^"]+)"')
        if not raw then return m end
        local stripped = regex_replace(raw, "^https?://", "")
        return 'src="https://images.weserv.nl/?url=' .. url_encode(stripped) .. '&https=1"'
      end
    )
  end

  if resultHtml == "" then return "" end

  -- Парсим получившийся HTML и извлекаем текст с абзацами
  local el = html_select_first(resultHtml, "p, div, body")
  if el then
    return applyStandardContentTransforms(html_text(resultHtml))
  end
  return applyStandardContentTransforms(html_text(resultHtml))
end