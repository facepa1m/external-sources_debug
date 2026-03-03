-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "jaomix"
name     = "Jaomix"
version  = "1.0.0"
baseUrl  = "https://jaomix.ru/"
language = "ru"
icon     = "https://jaomix.ru/wp-content/uploads/2026/02/logo-150x150.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

local function transformCover(url)
  if not url or url == "" then return "" end
  return regex_replace(url, "-150x150", "")
end

local function applyStandardContentTransforms(text)
  if not text or text == "" then return "" end
  text = string_normalize(text)
  local domain = baseUrl:gsub("https?://", ""):gsub("^www%.", ""):gsub("/$", "")
  text = regex_replace(text, "(?i)" .. domain .. ".*?\\n", "")
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = regex_replace(text, "(?im)^\\s*(Перевод|Переводчик|Редакция|Редактор|Аннотация|Сайт|Источник|Студия)[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = regex_replace(text, "(?im)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
  text = string_trim(text)
  return text
end

local AJAX_HEADERS = {
  headers = {
    ["User-Agent"]       = "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro Build/UQ1A.240205.004) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.6834.83 Mobile Safari/537.36",
    ["Accept"]           = "text/html, */*; q=0.01",
    ["Accept-Language"]  = "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Origin"]           = "https://jaomix.ru",
    ["Sec-Fetch-Dest"]   = "empty",
    ["Sec-Fetch-Mode"]   = "cors",
    ["Sec-Fetch-Site"]   = "same-origin"
  }
}

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local url
  if index == 0 then
    url = baseUrl
  else
    url = baseUrl .. "?gpage=" .. tostring(index + 1)
  end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, "div.block-home > div.one")) do
    local titleEl = html_select_first(card.html, "div.title-home")
    local bookUrl = absUrl(html_attr(card.html, "div.img-home > a", "href"))
    local cover   = transformCover(absUrl(html_attr(card.html, "div.img-home > a > img", "src")))
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

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
  local url
  if index == 0 then
    url = baseUrl .. "?searchrn=" .. url_encode(query)
  else
    url = baseUrl .. "?searchrn=" .. url_encode(query) .. "&gpage=" .. tostring(index + 1)
  end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local items = {}
  for _, card in ipairs(html_select(r.body, "div.block-home > div.one")) do
    local titleEl = html_select_first(card.html, "div.title-home")
    local bookUrl = absUrl(html_attr(card.html, "div.img-home > a", "href"))
    local cover   = transformCover(absUrl(html_attr(card.html, "div.img-home > a > img", "src")))
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
  local el = html_select_first(r.body, "div.img-book > img")
  if el then return transformCover(absUrl(el.src)) end
  return nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, "#desc-tab")
  if el then return string_trim(el.text) end
  return nil
end

-- ── Список глав (AJAX POST, постранично от конца к началу) ────────────────────

function getChapterList(bookUrl)
  -- Загружаем страницу книги чтобы узнать количество страниц
  local r = http_get(bookUrl)
  if not r.success then return {} end

  local maxPage = 10 -- fallback
  local opts = html_select(r.body, "select.sel-toc option")
  if #opts == 0 then
    opts = html_select(r.body, "select[onchange*='loadChaptList'] option")
  end
  if #opts > 0 then maxPage = #opts end

  local ajaxUrl = baseUrl .. "wp-admin/admin-ajax.php"
  local allChapters = {}

  -- Загружаем от последней страницы к первой
  for page = maxPage, 1, -1 do
    local headers = AJAX_HEADERS.headers
    headers["Referer"] = bookUrl

    local pr = http_post(
      ajaxUrl,
      "action=loadpagenavchapstt&page=" .. tostring(page),
      {
        headers = headers
      }
    )

    if not pr.success then break end

    -- Собираем главы страницы
    local pageChapters = {}
    for _, a in ipairs(html_select(pr.body, "div.title a[href]")) do
      local chUrl = absUrl(a.href)
      if chUrl ~= "" then
        local titleEl = html_select_first(a.html, "h2")
        table.insert(pageChapters, {
          title = titleEl and string_clean(titleEl.text) or string_clean(a.text),
          url   = chUrl
        })
      end
    end

    if #pageChapters == 0 then break end

    -- Внутри страницы разворачиваем (newest→oldest), затем добавляем
    for i = #pageChapters, 1, -1 do
      table.insert(allChapters, pageChapters[i])
    end

    sleep(math.random(150, 350))
  end

  return allChapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select_first(r.body, ".block-toc-out .columns-toc:first-child .flex-dow-txt:first-child a")
  if el then return el.href end
  return nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads", ".adblock-service", ".lazyblock", ".clear")
  local el = html_select_first(cleaned, ".entry-content")
  if not el then return "" end
  return applyStandardContentTransforms(html_text(el.html))
end