-- ── Метаданные ───────────────────────────────────────────────────────────────
id       = "shuba69"
name     = "69shuba"
version  = "1.0.6"
baseUrl  = "https://www.69shuba.com/"
language = "zh"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/69shuba.png"

-- ── Каталог и Поиск ──────────────────────────────────────────────────────────

function getCatalogList(index)
    local page = index + 1
    local url = baseUrl .. "novels/monthvisit_0_0_" .. tostring(page) .. ".htm"
    
    local r = http_get(url, { charset = "GBK" })
    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, li in ipairs(html_select(r.body, "ul#article_list_content li")) do
        local titleEl = html_select_first(li.html, "div.newnav h3 a")
        local imgEl   = html_select_first(li.html, "a.imgbox img")
        
        if titleEl then
            table.insert(items, {
                title = string_trim(titleEl.text),
                url   = titleEl.href,
                cover = html_attr(li.html, "a.imgbox img", "data-src")
            })
        end
    end

    return { items = items, hasNext = #items > 0 }
end

function getCatalogSearch(index, query)
    -- Сайт поддерживает только одну страницу поиска через POST
    if index > 0 then return { items = {}, hasNext = false } end

    local searchUrl = "https://www.69shuba.com/modules/article/search.php"
    local payload = "searchkey=" .. url_encode_charset(query, "GBK") .. "&searchtype=all"
    
    local r = http_post(searchUrl, payload, {
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        charset = "GBK"
    })

    if not r.success then return { items = {}, hasNext = false } end

    local items = {}
    for _, li in ipairs(html_select(r.body, "div.newbox ul li")) do
        local titleEl = html_select_first(li.html, "h3 a:last-child")
        
        if titleEl then
            table.insert(items, {
                title = string_trim(titleEl.text),
                url   = titleEl.href,
                cover = html_attr(li.html, "a.imgbox img", "data-src")
            })
        end
    end

    return { items = items, hasNext = false }
end

-- ── Детали книги ─────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
    local r = http_get(bookUrl, { charset = "GBK" })
    if not r.success then return nil end
    local el = html_select_first(r.body, "div.booknav2 h1 a")
    return el and string_trim(el.text) or nil
end

function getBookCoverImageUrl(bookUrl)
    local r = http_get(bookUrl, { charset = "GBK" })
    if not r.success then return nil end
    return html_attr(r.body, "div.bookimg2 img", "src")
end

function getBookDescription(bookUrl)
    local r = http_get(bookUrl, { charset = "GBK" })
    if not r.success then return nil end
    local el = html_select_first(r.body, "div.navtxt")
    return el and string_trim(el.text) or nil
end

-- ── Список глав ──────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
    -- Обязательно используем % для экранирования точки
    local chapterListUrl = bookUrl:gsub("/txt/", "/"):gsub("%.htm", "/")
    
    -- Пробуем получить документ сразу в GBK
    local r = http_get(chapterListUrl, "GBK")
    
    if not r.success then return {} end

    local chapters = {}
    local links = html_select(r.body, "div#catalog ul li a")
    
    for i = #links, 1, -1 do
        local a = links[i]
        
        -- Если текст все еще ломаный, используем string_normalize (если есть в API)
        -- или полагаемся на то, что r.body уже нормализован движком
        local rawTitle = a.text
        
        table.insert(chapters, {
            title = string_trim(rawTitle),
            url   = a.href
        })
    end
    
    return chapters
end


-- ── Хеш списка глав (для отслеживания обновлений) ─────────────────────────────

function getChapterListHash(bookUrl)
    -- Берем последнюю главу как индикатор обновления
    local r = http_get(bookUrl, "GBK")
    if not r.success then return "" end
    local el = html_select_first(r.body, "div#catalog ul li a")
    return el and el.href or ""
end

-- ── Текст главы ──────────────────────────────────────────────────────────────

function getChapterText(html)
    -- Важно: html приходит в UTF-8 уже от самого приложения после загрузки страницы
    -- Но если внутри есть мета-теги с GBK, Jsoup может запутаться.
    local cleaned = html_remove(html, "h1", "div.txtinfo", "div.bottom-ad", "div.bottem2", "script")
    
    -- 69shuba часто прячет текст в div.txtnav
    local content = html_select_first(cleaned, "div.txtnav")
    
    if content then
        -- Используем html_text для корректного извлечения текста с сохранением переносов
        return html_text(content.html)
    end
    
    return ""
end