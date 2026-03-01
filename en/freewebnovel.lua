-- FreeWebNovel Lua Plugin
-- Migrated from Kotlin hardcoded source

return {
    id = "freewebnovel",
    name = "FreeWebNovel",
    version = "1.0.0",
    language = "en",
    baseUrl = "https://freewebnovel.com",
    icon = "icons/freewebnovel.png",

    -- Catalog: Completed Novels
    getCatalogList = function(index)
        local page = index + 1
        local url = "https://freewebnovel.com/completed-novel/" .. page
        
        local response = http_get(url)
        if not response.success then
            return { items = {}, hasNext = false, error = "HTTP failed with code " .. response.code }
        end
        
        local doc = html_parse(response.body)
        local items = html_select(doc, ".ul-list1 .li-row")
        local books = {}
        
        for i = 1, #items do
            local item = items[i]
            local titleElem = html_select(item, ".tit a")[1]
            local coverElem = html_select(item, ".pic img")[1]
            
            if titleElem then
                table.insert(books, {
                    title = titleElem:get_text(),
                    url = titleElem.href,
                    cover = coverElem and coverElem.src or ""
                })
            end
        end
        
        return {
            items = books,
            hasNext = #books > 0
        }
    end,

    -- Search
    getCatalogSearch = function(index, input)
        if index > 0 or input == "" then return { items = {}, hasNext = false } end
        
        local url = "https://freewebnovel.com/search"
        local data = "searchkey=" .. url_encode(input)
        
        local response = http_post(url, data, {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Referer"] = "https://freewebnovel.com/"
        })
        
        if not response.success then return { items = {}, hasNext = false } end
        
        local doc = html_parse(response.body)
        local items = html_select(doc, ".serach-result .li-row")
        local books = {}
        
        for i = 1, #items do
            local item = items[i]
            local titleElem = html_select(item, ".tit a")[1]
            local coverElem = html_select(item, ".pic img")[1]
            
            if titleElem then
                table.insert(books, {
                    title = titleElem:get_text(),
                    url = titleElem.href,
                    cover = coverElem and coverElem.src or ""
                })
            end
        end
        
        return { items = books, hasNext = false }
    end,

    -- Book Details
    getBookTitle = function(url)
        local res = http_get(url)
        if not res.success then return nil end
        local doc = html_parse(res.body)
        local title = html_select(doc, "h1.tit")[1]
        return title and title:get_text() or nil
    end,

    getBookCoverImageUrl = function(url)
        local res = http_get(url)
        if not res.success then return nil end
        local doc = html_parse(res.body)
        local img = html_select(doc, ".pic img")[1]
        return img and img.src or nil
    end,

    getBookDescription = function(url)
        local res = http_get(url)
        if not res.success then return nil end
        local doc = html_parse(res.body)
        local desc = html_select(doc, ".m-desc .txt")[1]
        return desc and html_text(desc) or nil
    end,

    -- Chapters
    getChapterList = function(url)
        local res = http_get(url)
        if not res.success then return {} end
        local doc = html_parse(res.body)
        local links = html_select(doc, "#idData li a")
        local chapters = {}
        
        for i = 1, #links do
            table.insert(chapters, {
                title = links[i]:get_text(),
                url = links[i].href
            })
        end
        return chapters
    end,

    getChapterText = function(html)
        local doc = html_parse(html)
        local content = html_select(doc, "div.txt")[1]
        if content then
            return html_text(content)
        end
        return ""
    end
}
