id       = "novelfull"
name     = "NovelFull"
version  = "1.0.0"
baseUrl  = "https://novelfull.net/"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novelfull.png"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
    if not href or href == "" then return "" end
    if string_starts_with(href, "http") then return href end
    if string_starts_with(href, "//") then return "https:" .. href end
    return url_resolve(baseUrl, href)
end

-- novelBinCoverUrl: используется только для каталога и поиска
local function transformCatalogCover(bookUrl)
    if not bookUrl or bookUrl == "" then return "" end
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

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
    local page = index + 1
    local url = baseUrl .. "latest-release-novel"
    if page > 1 then url = url .. "?page=" .. page end

    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, card in ipairs(html_select(r.body, ".col-truyen-main .row")) do
        local titleEl = html_select_first(card.html, "div.col-xs-7 > div > h3 > a")
        
        if titleEl then
            local bookUrl = absUrl(titleEl.href)
            table.insert(items, {
                title = string_clean(titleEl.text),
                url   = bookUrl,
                cover = transformCatalogCover(bookUrl) 
            })
        end
    end
    return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
    local page = index + 1
    local url = baseUrl .. "search?keyword=" .. url_encode(query)
    if page > 1 then url = url .. "&page=" .. page end

    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, card in ipairs(html_select(r.body, ".col-truyen-main .row")) do
        local titleEl = html_select_first(card.html, "div.col-xs-7 > div > h3 > a")
        
        if titleEl then
            local bookUrl = absUrl(titleEl.href)
            table.insert(items, {
                title = string_clean(titleEl.text),
                url   = bookUrl,
                cover = transformCatalogCover(bookUrl)
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
    return (cover ~= "" and absUrl(cover)) or nil
end

function getBookDescription(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local el = html_select_first(r.body, ".desc-text")
    return el and string_trim(el.text) or nil
end

-- ── Список глав ───────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return {} end

    local maxPage = 1
    local lastPageEl = html_select_first(r.body, "#list-chapter > ul:nth-child(3) > li.last > a")
    if lastPageEl then
        maxPage = tonumber(lastPageEl.href:match("page=(%d+)")) or 1
    end

    local function parsePage(html)
        local res = {}
        for _, a in ipairs(html_select(html, "ul.list-chapter li a")) do
            local title = html_attr(a.html, "a", "title")
            if title == "" then title = a.text end
            
            table.insert(res, { 
                title = string_clean(title), 
                url = absUrl(a.href) 
            })
        end
        return res
    end

    local allChapters = parsePage(r.body)

    if maxPage > 1 then
        local urls = {}
        for p = 2, maxPage do table.insert(urls, bookUrl .. "?page=" .. p) end
        local results = http_get_batch(urls)
        for _, res in ipairs(results) do
            if res.success then
                for _, ch in ipairs(parsePage(res.body)) do table.insert(allChapters, ch) end
            end
        end
    end
    return allChapters
end

function getChapterListHash(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local el = html_select_first(r.body, ".l-chapters li:first-child a")
    return el and el.href or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
    local cleaned = html_remove(html, "script", ".ads")
    local el = html_select_first(cleaned, "#chapter-content")
    if not el then return "" end
    return applyStandardContentTransforms(html_text(el.html))
end