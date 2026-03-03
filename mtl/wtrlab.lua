-- ── Метаданные ───────────────────────────────────────────────────────────────
id       = "wtrlab"
name     = "WTR-LAB"
version  = "1.0.0" 
baseUrl  = "https://wtr-lab.com/"
language = "MTL"  -- MTL
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wtr-lab.png"

-- ── Настройки ────────────────────────────────────────────────────────────────
-- Ключи preferences (совместимы с AppPreferences.WTR_LAB_MODE / WTR_LAB_LANGUAGE)
local PREF_MODE = "wtrlab_mode"       -- "ai" | "raw"
local PREF_LANG = "wtrlab_language"   -- "none","en","ru","es","de","id","tr","pl","it","fr"

local function getMode()
    local v = get_preference(PREF_MODE)
    return (v ~= "" and v) or "ai"
end

local function getLang()
    local v = get_preference(PREF_LANG)
    return (v ~= "" and v) or "none"
end

-- ── Вспомогательные функции ──────────────────────────────────────────────────

local function absUrl(href)
    if href == "" then return "" end
    if string_starts_with(href, "http") then return href end
    if string_starts_with(href, "//") then return "https:" .. href end
    return url_resolve(baseUrl, href)
end

-- Маппинг кода языка для Google Translate
-- raw-режим: исходник китайский, ai-режим: исходник английский
local function sourceLangForGT()
    if getMode() == "raw" then return "zh-CN" else return "en" end
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
    local el = html_select_first(r.body, ".detail-line")
    -- Ищем строку с количеством глав
    for _, lineEl in ipairs(html_select(r.body, ".detail-line")) do
        local t = lineEl.text
        if string.find(t, "Chapter") or string.find(t, "chapter") then
            return string_trim(t)
        end
    end
    return nil
end

-- ── Список глав (AJAX GET /api/chapters/{novelId}) ────────────────────────────

function getChapterList(bookUrl)
    -- Извлекаем novelId из URL: /novel/12345/slug
    local novelId = string.match(bookUrl, "/novel/(%d+)/")
    if not novelId then
        log_error("wtrlab: cannot extract novelId from " .. bookUrl)
        return {}
    end
    local slug = string.match(bookUrl, "/novel/%d+/([^/?#]+)") or ""

    -- Небольшая задержка (аналог Random.nextLong(200,500) в Kotlin)
    sleep(300)

    local apiUrl = baseUrl .. "api/chapters/" .. novelId
    local r = http_get(apiUrl, {
        headers = { ["Referer"] = bookUrl }
    })
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

-- ── Текст главы (API /api/reader/get) ────────────────────────────────────────

-- Очистка абзаца от артефактов перевода (аналог cleanApiParagraph)
local function cleanParagraph(text)
    text = string_normalize(text)
    -- Удалить строки с "Translator:", "Editor:", "Read at/on/latest"
    text = regex_replace(text, "(?i)^\\s*(Translator|Editor|Proofreader|Read\\s+(at|on|latest))[:\\s][^\\n\\r]{0,70}(\\r?\\n|$)", "")
    -- Удалить заголовки глав в начале (Chapter N, Глава N)
    text = regex_replace(text, "(?i)\\A[\\s\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
    return string_trim(text)
end

-- Расшифровка зашифрованного тела через прокси
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

    -- Ответ может быть массивом (тело) или объектом с полем body
    if type(data) == "table" then
        -- Если это массив (числовые ключи) — сериализуем обратно в JSON
        if data[1] ~= nil then
            return json_stringify(data)
        end
        -- Если объект с полем body
        if data.body ~= nil then
            return json_stringify(data.body)
        end
    end

    return rawBody
end

-- Применение глоссария и патчей к тексту абзаца
-- glossary: { [index] = term }
-- patches: { { zh="...", en="..." } }
local function applyGlossaryAndPatches(text, glossary, patches)
    if glossary then
        for idx, term in pairs(glossary) do
            -- Маркеры: ※N⛬ и ※N〓 (index начинается с 0 в Kotlin, json_parse даёт числа)
            local marker1 = "※" .. tostring(idx) .. "⛬"
            local marker2 = "※" .. tostring(idx) .. "〓"
            text = regex_replace(text, regex_replace(marker1, "[※⛬〓]", "\\$0"), term)
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

-- Парсинг тела главы: массив абзацев или plain text
local function buildParagraphs(bodyJson, resolvedBody, glossary, patches)
    local paragraphs = {}

    -- Попытка парсить как JSON массив
    local bodyArray = json_parse(resolvedBody)

    if type(bodyArray) == "table" and bodyArray[1] ~= nil then
        -- Это массив строк
        for _, item in ipairs(bodyArray) do
            if type(item) == "string" then
                local text = cleanParagraph(item)
                -- Пропускаем [image] и пустые
                if text ~= "[image]" and text ~= "" then
                    text = applyGlossaryAndPatches(text, glossary, patches)
                    if text ~= "" then
                        table.insert(paragraphs, text)
                    end
                end
            end
        end
    else
        -- Plain text — разбиваем по строкам
        for _, line in ipairs(string_split(resolvedBody, "\n")) do
            local text = string_trim(line)
            if text ~= "" then
                table.insert(paragraphs, text)
            end
        end
    end

    return paragraphs
end

-- Перевод порциями (аналог translateChunks)
-- Разбивает на куски по ~8000 символов, переводит с задержкой 500мс
local function translateParagraphs(paragraphs, targetLang)
    local sourceLang = sourceLangForGT()
    local result = {}
    for i = 1, #paragraphs do result[i] = paragraphs[i] end

    -- Собираем куски
    local MAX_CHARS = 8000
    local chunks = {}
    local currentIndices = {}
    local currentHtml = ""

    for i, para in ipairs(paragraphs) do
        local paraHtml = "<p>" .. para .. "</p>"
        if currentHtml ~= "" and #currentHtml + #paraHtml > MAX_CHARS then
            table.insert(chunks, { indices = currentIndices, html = currentHtml })
            currentIndices = {}
            currentHtml = ""
        end
        table.insert(currentIndices, i)
        currentHtml = currentHtml .. paraHtml
    end
    if currentHtml ~= "" then
        table.insert(chunks, { indices = currentIndices, html = currentHtml })
    end

    log_info("wtrlab: translating " .. tostring(#paragraphs) .. " paragraphs in " ..
             tostring(#chunks) .. " chunks -> " .. targetLang)

    for ci, chunk in ipairs(chunks) do
        if ci > 1 then sleep(500) end

        local translated = google_translate(chunk.html, sourceLang, targetLang, baseUrl)
        if translated == chunk.html or translated == nil or translated == "" then
            -- Перевод не изменился или упал — оставляем оригинал
        else
            -- Извлекаем абзацы из переведённого HTML
            local translatedParas = {}
            for _, pEl in ipairs(html_select(translated, "p")) do
                local t = string_trim(pEl.text)
                if t ~= "" then
                    table.insert(translatedParas, t)
                end
            end
            -- Fallback: если <p> не нашлись — разбиваем по строкам
            if #translatedParas == 0 then
                for _, line in ipairs(string_split(translated, "\n")) do
                    local t = string_trim(line)
                    if t ~= "" then table.insert(translatedParas, t) end
                end
            end

            local minSize = math.min(#translatedParas, #chunk.indices)
            for pos = 1, minSize do
                result[chunk.indices[pos]] = translatedParas[pos]
            end
            if #translatedParas ~= #chunk.indices then
                log_info("wtrlab: chunk " .. tostring(ci) .. " size mismatch: expected " ..
                         tostring(#chunk.indices) .. " got " .. tostring(#translatedParas))
            end
        end
    end

    return result
end

function getChapterText(html, chapterUrl)
    -- chapterUrl передаётся из LuaSourceAdapter (второй аргумент)
    if not chapterUrl or chapterUrl == "" then
        -- Попытка взять URL из canonical
        chapterUrl = html_attr(html, "link[rel='canonical']", "href")
    end
    if not chapterUrl or chapterUrl == "" then
        log_error("wtrlab: no chapterUrl available")
        return ""
    end

    log_info("wtrlab: getChapterText url=" .. chapterUrl)

    -- Извлекаем novelId и chapterNo из URL
    -- URL паттерн: /novel/{novelId}/{slug}/chapter-{N}
    local novelId = string.match(chapterUrl, "/novel/(%d+)/")
    if not novelId then
        log_error("wtrlab: 'novel' not found in URL: " .. chapterUrl)
        return ""
    end

    local chapterNo = tonumber(string.match(chapterUrl, "/chapter%-(%d+)")) or 1
    local lang = getLang()
    local mode = getMode()
    local translateParam = (mode == "raw") and "web" or "ai"

    log_info("wtrlab: novelId=" .. novelId .. " chapterNo=" .. tostring(chapterNo) ..
             " translate=" .. translateParam .. " lang=" .. lang)

    -- POST /api/reader/get
    local requestBody = json_stringify({
        translate   = translateParam,
        language    = lang,
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

    log_info("wtrlab: API response start: " .. string.sub(r.body, 1, 200))

    local json = json_parse(r.body)
    if not json then
        log_error("wtrlab: response is not JSON")
        return ""
    end

    -- Проверка success
    if json.success == false then
        local errCode = json.code or "?"
        local errMsg  = json.error or "Unknown API error"
        log_error("wtrlab: API error [" .. tostring(errCode) .. "]: " .. errMsg)
        error("[" .. tostring(errCode) .. "] " .. errMsg)
    end

    -- Навигация по data
    local outerData = json.data
    local data = nil
    if outerData then
        if outerData.data then
            data = outerData.data
        else
            data = outerData
        end
    end
    if not data then
        log_error("wtrlab: no 'data' in response")
        return ""
    end

    -- Тело главы
    local body = data.body
    if not body then
        log_error("wtrlab: no 'body' in data")
        return ""
    end

    -- body может быть массивом (json table) или строкой
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

    -- Расшифровка если зашифровано (arr:...)
    local resolvedBody = decryptBody(rawBody)

    -- Глоссарий терминов: glossary_data.terms[i][0] → term
    local glossary = {}
    if data.glossary_data and data.glossary_data.terms then
        local terms = data.glossary_data.terms
        for i = 1, #terms do
            local termEntry = terms[i]
            if type(termEntry) == "table" and termEntry[1] and termEntry[1] ~= "" then
                glossary[i - 1] = termEntry[1]  -- индекс 0-based как в Kotlin
            end
        end
    end

    -- Патчи: patch[i].zh → patch[i].en
    local patches = {}
    if data.patch then
        for _, patchItem in ipairs(data.patch) do
            if patchItem.zh and patchItem.en and patchItem.zh ~= "" then
                table.insert(patches, { zh = patchItem.zh, en = patchItem.en })
            end
        end
    end

    -- Сборка абзацев
    local paragraphs = buildParagraphs(rawBody, resolvedBody, glossary, patches)

    if #paragraphs == 0 then
        log_info("wtrlab: 0 paragraphs parsed")
        return ""
    end

    log_info("wtrlab: parsed " .. tostring(#paragraphs) .. " paragraphs")

    -- Опциональный перевод через Google Translate
    local finalParagraphs = paragraphs
    if lang ~= "none" and lang ~= "" then
        -- Определяем целевой код языка (уже правильный ISO 639-1)
        local targetLang = lang
        -- Поддерживаемые языки WtrLab: en, es, ru, de, pl, it, fr, id, tr
        local supported = { en=true, es=true, ru=true, de=true, pl=true, it=true, fr=true, id=true, tr=true }
        if supported[targetLang] then
            local ok, err = pcall(function()
                finalParagraphs = translateParagraphs(paragraphs, targetLang)
            end)
            if not ok then
                log_error("wtrlab: translation failed: " .. tostring(err) .. ", using original")
                finalParagraphs = paragraphs
            end
        end
    end

    -- Собираем в HTML с тегами <p>
    local parts = {}
    for _, para in ipairs(finalParagraphs) do
        table.insert(parts, "<p>" .. para .. "</p>")
    end

    return table.concat(parts, "\n")
end

-- ── Settings schema (для UI в адаптере) ──────────────────────────────────────
-- Возвращает схему настроек в виде таблицы.
-- LuaSourceAdapter может вызвать эту функцию и отрендерить нативный UI.
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
        },
        {
            key     = PREF_LANG,
            type    = "select",
            label   = "Translation Language",
            current = getLang(),
            options = {
                { value = "none", label = "No translation (original)" },
                { value = "en",   label = "English" },
                { value = "es",   label = "Spanish" },
                { value = "ru",   label = "Russian" },
                { value = "de",   label = "German" },
                { value = "id",   label = "Indonesian" },
                { value = "tr",   label = "Turkish" },
                { value = "pl",   label = "Polish" },
                { value = "it",   label = "Italian" },
                { value = "fr",   label = "French" }
            }
        }
    }
end