-- ── Метаданные ───────────────────────────────────────────────────────────────
id       = "wtrlab"
name     = "WTR-LAB"
version  = "1.0.1"
baseUrl  = "https://wtr-lab.com/"
language = "MTL"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wtr-lab.png"

-- ── Настройки ────────────────────────────────────────────────────────────────
local PREF_MODE = "wtrlab_mode"  -- "ai" | "raw"

local function getMode()
    local v = get_preference(PREF_MODE)
    return (v ~= "" and v) or "ai"
end

-- ── Вспомогательные функции ──────────────────────────────────────────────────

local function absUrl(href)
    if href == "" then return "" end
    if string_starts_with(href, "http") then return href end
    if string_starts_with(href, "//") then return "https:" .. href end
    return url_resolve(baseUrl, href)
end

-- ── Каталог ──────────────────────────────────────────────────────────────────

function getCatalogList(index)
    local page = index + 1
    local url = baseUrl .. "novel-list?page=" .. tostring(page)
    local r = http_get(url)
    if not r.success then
        log_error("wtrlab getCatalogList failed: " .. url .. " code=" .. tostring(r.code))
        return { items = {}, hasNext = false }
    end

    local items = {}
    for _, card in ipairs(html_select(r.body, "div.serie-item")) do
        local titleEl = html_select_first(card.html, "a.title")
        if titleEl then
            local cover = html_attr(card.html, ".image-wrap img", "src")
            table.insert(items, {
                title = string_trim(titleEl.text),
                url   = absUrl(titleEl.href),
                cover = absUrl(cover)
            })
        end
    end

    return { items = items, hasNext = #items > 0 }
end

-- ── Поиск ────────────────────────────────────────────────────────────────────

function getCatalogSearch(index, query)
    local page = index + 1
    local url = baseUrl .. "novel-finder?text=" .. url_encode(query) .. "&page=" .. tostring(page)
    local r = http_get(url)
    if not r.success then
        log_error("wtrlab getCatalogSearch failed code=" .. tostring(r.code))
        return { items = {}, hasNext = false }
    end

    local items = {}
    for _, card in ipairs(html_select(r.body, "div.serie-item")) do
        local titleEl = html_select_first(card.html, "a.title")
        if titleEl then
            local cover = html_attr(card.html, ".image-wrap img", "src")
            table.insert(items, {
                title = string_trim(titleEl.text),
                url   = absUrl(titleEl.href),
                cover = absUrl(cover)
            })
        end
    end

    return { items = items, hasNext = #items > 0 }
end

-- ── Детали книги ─────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local el = html_select_first(r.body, "h1.long-title")
    if el then return string_trim(el.text) end
    return nil
end

function getBookCoverImageUrl(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local cover = html_attr(r.body, ".image-section .image-wrap img", "src")
    if cover ~= "" then return absUrl(cover) end
    return nil
end

function getBookDescription(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    local el = html_select_first(r.body, ".desc-wrap .description")
    if el then return string_trim(el.text) end
    return nil
end

function getChapterListHash(bookUrl)
    local r = http_get(bookUrl)
    if not r.success then return nil end
    for _, lineEl in ipairs(html_select(r.body, ".detail-line")) do
        local t = lineEl.text
        if string.find(t, "Chapter") or string.find(t, "chapter") then
            return string_trim(t)
        end
    end
    return nil
end

-- ── Список глав ──────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
    local novelId = string.match(bookUrl, "/novel/(%d+)/")
    if not novelId then
        log_error("wtrlab: cannot extract novelId from " .. bookUrl)
        return {}
    end
    local slug = string.match(bookUrl, "/novel/%d+/([^/?#]+)") or ""

    sleep(300)

    local apiUrl = baseUrl .. "api/chapters/" .. novelId
    local r = http_get(apiUrl, { headers = { ["Referer"] = bookUrl } })
    if not r.success then
        log_error("wtrlab: chapters API failed code=" .. tostring(r.code))
        return {}
    end

    local data = json_parse(r.body)
    if not data then
        log_error("wtrlab: cannot parse chapters JSON")
        return {}
    end

    local chaptersData = data.chapters
    if not chaptersData then return {} end

    local chapters = {}
    for i = 1, #chaptersData do
        local ch = chaptersData[i]
        local order = ch.order or i
        local title = ch.title or ("Chapter " .. tostring(order))
        local chUrl = baseUrl .. "novel/" .. novelId .. "/" .. slug .. "/chapter-" .. tostring(order)
        table.insert(chapters, {
            title = tostring(order) .. ": " .. title,
            url   = chUrl
        })
    end

    log_info("wtrlab: loaded " .. tostring(#chapters) .. " chapters for novelId=" .. novelId)
    return chapters
end

-- ── Текст главы ──────────────────────────────────────────────────────────────

local function cleanParagraph(text)
    text = string_normalize(text)
    text = regex_replace(text, "(?i)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
    text = regex_replace(text, "(?i)\\A[\\s\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
    return string_trim(text)
end

local function decryptBody(rawBody)
    if not string_starts_with(rawBody, "arr:") then return rawBody end

    log_info("wtrlab: body encrypted (arr:...), sending to proxy")
    local r = http_post(
        "https://wtr-lab-proxy.fly.dev/chapter",
        json_stringify({ payload = rawBody }),
        { headers = { ["Content-Type"] = "application/json" } }
    )
    if not r.success then
        log_error("wtrlab: proxy failed code=" .. tostring(r.code))
        return rawBody
    end

    local data = json_parse(r.body)
    if not data then return rawBody end

    if type(data) == "table" then
        if data[1] ~= nil then return json_stringify(data) end
        if data.body ~= nil then return json_stringify(data.body) end
    end

    return rawBody
end

local function applyGlossaryAndPatches(text, glossary, patches)
    if glossary then
        for idx, term in pairs(glossary) do
            local marker1 = "※" .. tostring(idx) .. "⛬"
            local marker2 = "※" .. tostring(idx) .. "〓"
            text = text:gsub(marker1, term)
            text = text:gsub(marker2, term)
        end
    end
    if patches then
        for _, patch in ipairs(patches) do
            if patch.zh and patch.en then
                text = text:gsub(patch.zh, patch.en)
            end
        end
    end
    return text
end

local function buildParagraphs(rawBody, resolvedBody, glossary, patches)
    local paragraphs = {}
    local bodyArray = json_parse(resolvedBody)

    if type(bodyArray) == "table" and bodyArray[1] ~= nil then
        for _, item in ipairs(bodyArray) do
            if type(item) == "string" then
                local text = cleanParagraph(item)
                if text ~= "[image]" and text ~= "" then
                    text = applyGlossaryAndPatches(text, glossary, patches)
                    if text ~= "" then
                        table.insert(paragraphs, text)
                    end
                end
            end
        end
    else
        for _, line in ipairs(string_split(resolvedBody, "\n")) do
            local text = string_trim(line)
            if text ~= "" then table.insert(paragraphs, text) end
        end
    end

    return paragraphs
end

function getChapterText(html, chapterUrl)
    if not chapterUrl or chapterUrl == "" then
        chapterUrl = html_attr(html, "link[rel='canonical']", "href")
    end
    if not chapterUrl or chapterUrl == "" then
        log_error("wtrlab: no chapterUrl available")
        return ""
    end

    log_info("wtrlab: getChapterText url=" .. chapterUrl)

    local novelId = string.match(chapterUrl, "/novel/(%d+)/")
    if not novelId then
        log_error("wtrlab: 'novel' not found in URL: " .. chapterUrl)
        return ""
    end

    local chapterNo = tonumber(string.match(chapterUrl, "/chapter%-(%d+)")) or 1
    local mode = getMode()
    local translateParam = (mode == "raw") and "web" or "ai"

    log_info("wtrlab: novelId=" .. novelId .. " chapterNo=" .. tostring(chapterNo) ..
             " translate=" .. translateParam)

    local requestBody = json_stringify({
        translate   = translateParam,
        language    = "none",
        raw_id      = novelId,
        chapter_no  = chapterNo,
        retry       = false,
        force_retry = false
    })

    local r = http_post(
        baseUrl .. "api/reader/get",
        requestBody,
        {
            headers = {
                ["Content-Type"] = "application/json",
                ["Referer"]      = chapterUrl,
                ["Origin"]       = regex_replace(baseUrl, "/$", "")
            }
        }
    )

    if not r.success then
        log_error("wtrlab: API reader/get failed code=" .. tostring(r.code))
        return ""
    end

    local json = json_parse(r.body)
    if not json then
        log_error("wtrlab: response is not JSON")
        return ""
    end

    if json.success == false then
        local errCode = json.code or "?"
        local errMsg  = json.error or "Unknown API error"
        log_error("wtrlab: API error [" .. tostring(errCode) .. "]: " .. errMsg)
        error("[" .. tostring(errCode) .. "] " .. errMsg)
    end

    local outerData = json.data
    local data = nil
    if outerData then
        data = outerData.data or outerData
    end
    if not data then
        log_error("wtrlab: no 'data' in response")
        return ""
    end

    local body = data.body
    if not body then
        log_error("wtrlab: no 'body' in data")
        return ""
    end

    local rawBody
    if type(body) == "table" then
        rawBody = json_stringify(body)
    else
        rawBody = tostring(body)
    end

    if rawBody == "" or rawBody == "null" then
        log_error("wtrlab: body is empty")
        return ""
    end

    local resolvedBody = decryptBody(rawBody)

    -- ── Глоссарий ─────────────────────────────────────────────────────────────
    local glossary = {}
    if data.glossary_data and data.glossary_data.terms then
        local terms = data.glossary_data.terms
        log_info("wtrlab: glossary terms count=" .. tostring(#terms))
        for i = 1, #terms do
            local termEntry = terms[i]
            if type(termEntry) == "table" then
                local termValue = termEntry[1] or ""
                log_info("wtrlab: glossary[" .. tostring(i - 1) .. "] = '" .. termValue .. "'")
                if termValue ~= "" then
                    glossary[i - 1] = termValue
                end
            end
        end
    else
        log_info("wtrlab: no glossary_data in response")
    end

    -- ── Патчи ─────────────────────────────────────────────────────────────────
    local patches = {}
    if data.patch then
        log_info("wtrlab: patches count=" .. tostring(#data.patch))
        for _, patchItem in ipairs(data.patch) do
            if patchItem.zh and patchItem.en and patchItem.zh ~= "" then
                log_info("wtrlab: patch '" .. patchItem.zh .. "' → '" .. patchItem.en .. "'")
                table.insert(patches, { zh = patchItem.zh, en = patchItem.en })
            end
        end
    else
        log_info("wtrlab: no patches in response")
    end

    local paragraphs = buildParagraphs(rawBody, resolvedBody, glossary, patches)

    if #paragraphs == 0 then
        log_info("wtrlab: 0 paragraphs parsed")
        return ""
    end

    log_info("wtrlab: parsed " .. tostring(#paragraphs) .. " paragraphs")

    local parts = {}
    for _, para in ipairs(paragraphs) do
        table.insert(parts, "<p>" .. para .. "</p>")
    end

    return table.concat(parts, "\n")
end

-- ── Settings schema ───────────────────────────────────────────────────────────

function getSettingsSchema()
    return {
        {
            key     = PREF_MODE,
            type    = "select",
            label   = "Translation Mode",
            current = getMode(),
            options = {
                { value = "ai",  label = "AI (Beta)" },
                { value = "raw", label = "Raw (Web)" }
            }
        }
    }
end
