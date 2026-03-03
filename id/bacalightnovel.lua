id       = "NovLove"
name     = "NovLove"
baseUrl  = "https://novlove.com/"
catalogUrl = "https://novlove.com/sort/nov-love-daily-update"
language = "en"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/novlove.png"

-- ── Вспомогательные функции ───────────────────────────────────────────────────

local function absUrl(href)
    if not href or href == "" then return "" end
    if string_starts_with(href, "http") then return href end
    return url_resolve(baseUrl, href)
end

-- UrlTransformers.novelBinCatalogCoverUrl()
local function transformCoverUrl(url)
    if not url or url == "" then return "" end
    return absUrl(url):gsub("novelhall%.com", "novlove.com")
end

-- ── Каталог ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
    local page = index + 1
    local url = (page == 1) and catalogUrl or (baseUrl .. "sort/nov-love-daily-update?page=" .. page)
    
    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, el in ipairs(html_select(r.body, ".col-novel-main .row")) do
        local a = html_select_first(el.html, ".novel-title a")
        table.insert(items, {
            title = string_clean(a.text),
            url   = absUrl(a:attr("href")),
            cover = transformCoverUrl(html_attr(el.html, "img.cover", "data-src"))
        })
    end
    return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ─────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
    local page = index + 1
    local url = baseUrl .. "search?keyword=" .. url_encode(query) .. (page > 1 and ("&page=" .. page) or "")

    local r = http_get(url)
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, el in ipairs(html_select(r.body, ".col-novel-main .row")) do
        local a = html_select_first(el.html, ".novel-title a")
        table.insert(items, {
            title = string_clean(a.text),
            url   = absUrl(a:attr("href")),
            cover = transformCoverUrl(html_attr(el.html, "img.cover", "src"))
        })
    end
    return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ──────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
    local r = http_get(bookUrl)
    return string_clean(html_text(r.body, "h3.title"))
end

function getBookCoverImageUrl(bookUrl)
    local r = http_get(bookUrl)
    return transformCoverUrl(html_attr(r.body, "meta[itemprop=image]", "content"))
end

function getBookDescription(bookUrl)
    local r = http_get(bookUrl)
    return string_trim(html_text(r.body, ".desc-text"))
end

-- ── Список глав (AJAX_BASED) ──────────────────────────────────────────────────

function getChapterList(bookUrl)
    local novelId = bookUrl:gsub("/$", ""):match("([^/]+)$")
    local ajaxUrl = baseUrl:gsub("/$", "") .. "/ajax/chapter-archive?novelId=" .. novelId
    
    local r = http_get(ajaxUrl)
    if not r.success then return {} end

    local chapters = {}
    for _, a in ipairs(html_select(r.body, "a[href*='/chapter']")) do
        table.insert(chapters, {
            title = string_trim(a:attr("title") ~= "" and a:attr("title") or a.text),
            url   = absUrl(a:attr("href"))
        })
    end
    return chapters
end

function getChapterListHash(bookUrl)
    local r = http_get(bookUrl)
    return html_attr(r.body, ".l-chapter a.chapter-title", "href")
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
    local cleaned = html_remove(html, "script", ".ads", ".advertisement", ".social-share")
    local el = html_select_first(cleaned, "#chr-content")
    if not el then return "" end
    
    return applyStandardContentTransforms(html_text(el.html))
end