id       = "novelfire"
name     = "NovelFire"
version  = "1.0.0"
baseUrl  = "https://novelfire.net"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novelfire.png"

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
    local url = baseUrl .. "/search-adv?ctgcon=and&totalchapter=0&ratcon=min&rating=0&status=-1&sort=rank-top&page=" .. page

    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, card in ipairs(html_select(r.body, ".novel-list > .novel-item")) do
        local titleEl = html_select_first(card.html, ".novel-title")
        local linkEl  = html_select_first(card.html, ".novel-title a")
        local cover   = html_attr(card.html, "img", "data-src")
        if cover == "" then cover = html_attr(card.html, "img", "src") end
        
        if titleEl and linkEl then
            table.insert(items, {
                title = string_clean(titleEl.text),
                url   = absUrl(linkEl.href),
                cover = absUrl(cover)
            })
        end
    end
    return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
    local page = index + 1
    local url = baseUrl .. "/search?keyword=" .. url_encode(query) .. "&page=" .. page

    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, card in ipairs(html_select(r.body, ".novel-list.chapters .novel-item")) do
        local titleEl = html_select_first(card.html, ".novel-title")
        local linkEl  = html_select_first(card.html, "a")
        local cover   = html_attr(card.html, "img", "src")
        
        if titleEl and linkEl then
            table.insert(items, {
                title = string_clean(titleEl.text),
                url   = absUrl(linkEl.href),
                cover = absUrl(cover)
            })
        end
    end
    return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local el = html_select_first(r.body, "h1.novel-title")
    return el and string_clean(el.text) or nil
end

function getBookCoverImageUrl(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local cover = html_attr(r.body, "img[src*='server-1']", "src")
    if cover == "" then cover = html_attr(r.body, ".cover img", "src") end
    return cover ~= "" and absUrl(cover) or nil
end

function getBookDescription(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local cleaned = html_remove(r.body, "h4.lined")
    local el = html_select_first(cleaned, ".summary .content, .summary")
    return el and string_trim(el.text) or nil
end

-- ── Список глав ───────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
    local bookSlug = bookUrl:match("/([^/]+)$")
    local firstPageUrl = baseUrl .. "/book/" .. bookSlug .. "/chapters?page=1"
    
    local r = http_get(firstPageUrl)
    if not r.success then return {} end

    local maxPage = 1
    for _, a in ipairs(html_select(r.body, ".pagination a[href*='?page=']")) do
        local p = tonumber(a.href:match("page=(%d+)"))
        if p and p > maxPage then maxPage = p end
    end

    local function parsePage(html)
        local res = {}
        for _, a in ipairs(html_select(html, "a[href*='/chapter-']")) do
            table.insert(res, { title = string_clean(a.title), url = absUrl(a.href) })
        end
        return res
    end

    local allChapters = parsePage(r.body)

    if maxPage > 1 then
        local urls = {}
        for p = 2, maxPage do table.insert(urls, baseUrl .. "/book/" .. bookSlug .. "/chapters?page=" .. p) end
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
    local el = html_select_first(r.body, ".body p.latest")
    return el and string_clean(el.text) or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
    local cleaned = html_remove(html, "script", "nav", ".ads", ".advertisement", 
                                ".disqus", ".comments", ".c-message", ".nav-next", ".nav-previous")
    local el = html_select_first(cleaned, "#content, .chapter-content, div.entry-content")
    if not el then return "" end
    
    -- Ключевой момент: html_text сохраняет переносы строк
    return applyStandardContentTransforms(html_text(el.html))
end