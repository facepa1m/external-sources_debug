-- WtrLab source plugin
-- Full port of WtrLabScraperTemplate.kt + WtrLabTranslator.kt
-- Supports: ai/raw mode, multi-language translation via Google Translate,
--           glossary substitution, patch map, proxy decryption for encrypted bodies

id       = "wtrlab"
name     = "WtrLab"
version  = "1.0.1"
baseUrl  = "https://wtr-lab.com/"
language = "multi"  -- multilingual
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wtr-lab.png"

-- ── Settings (stored in SharedPreferences via get/set_preference) ─────────────
-- Keys mirror AppPreferences constants so host app can sync if needed
local PREF_MODE = "wtrlab_mode"      -- "ai" | "raw"
local PREF_LANG = "wtrlab_language"  -- "none"|"en"|"es"|"ru"|"de"|"id"|"tr"|"pl"|"it"|"fr"

local function getMode() return get_preference(PREF_MODE) ~= "" and get_preference(PREF_MODE) or "ai" end
local function getLang() return get_preference(PREF_LANG) ~= "" and get_preference(PREF_LANG) or "none" end

-- ── Translation API ───────────────────────────────────────────────────────────

local TRANSLATE_URL = "https://translate-pa.googleapis.com/v1/translateHtml"
-- Base64-encoded Google API key (same as WtrLabTranslator.kt)
local GT_API_KEY = base64_decode("QUl6YVN5QVRCWGFqdnpRTFRESEVRYmNwcTBJaGUwdldISG1PNTIw")
GT_API_KEY = string_trim(GT_API_KEY)

local function sourceLanguageForGT()
  return getMode() == "raw" and "zh-CN" or "en"
end

local function apiTranslateParam()
  return getMode() == "raw" and "web" or "ai"
end

-- Translate a single HTML chunk, returns translated string or original on error
local function translateChunk(htmlChunk, targetLang)
  local srcLang = sourceLanguageForGT()
  -- Build JSON payload: [[html, srcLang, targetLang], "wt_lib"]
  local payload = json_stringify({ { htmlChunk, srcLang, targetLang }, "wt_lib" })

  local r = http_post(TRANSLATE_URL, payload, {
    headers = {
      ["Content-Type"] = "application/json+protobuf",
      ["X-Goog-Api-Key"] = GT_API_KEY,
      ["Origin"] = string_trim(baseUrl):gsub("/$", ""),
    }
  })

  if not r.success then
    log_error("WtrLab: translate HTTP " .. r.code)
    return htmlChunk
  end

  local parsed = json_parse(r.body)
  if parsed and parsed[1] and parsed[1][1] then
    return parsed[1][1]
  end
  log_error("WtrLab: translate parse failed: " .. r.body:sub(1, 200))
  return htmlChunk
end

-- Translate list of paragraphs in chunks of ~8000 chars
local function translateChunks(paragraphs, targetLang)
  local MAX_CHUNK = 8000
  local result = {}
  for i, p in ipairs(paragraphs) do result[i] = p end  -- copy

  -- Build chunks
  local chunks = {}  -- each: { indices={}, html="" }
  local currentIndices = {}
  local currentHtml = ""

  for i, para in ipairs(paragraphs) do
    local paraHtml = "<p>" .. para .. "</p>"
    if #currentHtml > 0 and #currentHtml + #paraHtml > MAX_CHUNK then
      table.insert(chunks, { indices = currentIndices, html = currentHtml })
      currentIndices = {}
      currentHtml = ""
    end
    table.insert(currentIndices, i)
    currentHtml = currentHtml .. paraHtml
  end
  if #currentHtml > 0 then
    table.insert(chunks, { indices = currentIndices, html = currentHtml })
  end

  log_info("WtrLab: translating " .. #paragraphs .. " paragraphs in " .. #chunks .. " chunks → " .. targetLang)

  for idx, chunk in ipairs(chunks) do
    if idx > 1 then sleep(500) end

    local translated = translateChunk(chunk.html, targetLang)
    if translated == chunk.html then goto continue end

    -- Parse <p>...</p> back
    local translatedParas = {}
    for content in translated:gmatch("<p>(.-)</p>") do
      local t = string_trim(content)
      if t ~= "" then
        table.insert(translatedParas, t)
      end
    end
    -- Fallback: split by newline
    if #translatedParas == 0 then
      for line in translated:gmatch("[^\n]+") do
        local t = string_trim(line)
        if t ~= "" then table.insert(translatedParas, t) end
      end
    end

    local minSize = math.min(#translatedParas, #chunk.indices)
    for pos = 1, minSize do
      result[chunk.indices[pos]] = translatedParas[pos]
    end
    if #translatedParas ~= #chunk.indices then
      log_error("WtrLab: chunk " .. idx .. ": expected " .. #chunk.indices .. " paras, got " .. #translatedParas)
    end

    ::continue::
  end

  return result
end

-- ── Body decryption (proxy) ───────────────────────────────────────────────────

local PROXY_URL = "https://wtr-lab-proxy.fly.dev/chapter"

local function decryptBodyIfNeeded(rawBody)
  if not string_starts_with(rawBody, "arr:") then
    return rawBody
  end
  log_info("WtrLab: body encrypted, sending to proxy")

  local r = http_post(PROXY_URL, json_stringify({ payload = rawBody }), {
    headers = { ["Content-Type"] = "application/json" }
  })

  if not r.success then
    log_error("WtrLab: proxy failed, code=" .. r.code)
    return rawBody
  end

  local parsed = json_parse(r.body)
  if not parsed then return rawBody end

  -- Proxy can return array directly or { body = [...] }
  if type(parsed) == "table" and parsed[1] ~= nil then
    -- it's an array - re-serialize to JSON string
    return json_stringify(parsed)
  elseif type(parsed) == "table" and parsed.body ~= nil then
    return json_stringify(parsed.body)
  end
  return rawBody
end

-- ── Text cleaning ─────────────────────────────────────────────────────────────

local function cleanApiParagraph(text)
  -- Normalize unicode
  text = string_normalize(text)
  -- Remove leading chapter headers like "Chapter 123 - Title"
  text = regex_replace(text, "^%s*[Cc]hapter%s+%d+[^\n\r]*[\n\r%s]*", "")
  text = regex_replace(text, "^%s*[Гг]лава%s+%d+[^\n\r]*[\n\r%s]*", "")
  -- Remove translator notes
  text = regex_replace(text, "^%s*(Translator|Editor|Proofreader|Read%s+at|Read%s+on|Read%s+latest)[:%s][^\n\r]{0,70}", "")
  return string_trim(text)
end

-- ── Chapter text (main logic) ─────────────────────────────────────────────────

function getChapterText(html)
  -- Extract chapter URL from the document
  local urlMatch = regex_match(html, "https?://wtr%-lab%.com/[^\"%s']+")
  local chapterUrl = urlMatch[1] or baseUrl

  log_info("WtrLab: getChapterText for " .. chapterUrl)

  -- Parse novelId and chapterNo from URL
  -- URL format: https://wtr-lab.com/novel/{novelId}/{slug}/chapter-{N}
  local novelId = regex_match(chapterUrl, "/novel/(%d+)/")
  local chapterNo = regex_match(chapterUrl, "/chapter%-(%d+)")

  if not novelId[1] then
    -- Try non-numeric novelId
    novelId = regex_match(chapterUrl, "/novel/([^/]+)/")
  end

  if not novelId[1] then
    log_error("WtrLab: cannot parse novelId from URL: " .. chapterUrl)
    return ""
  end

  local chapNo = tonumber(chapterNo[1]) or 1
  local lang   = getLang()
  local mode   = apiTranslateParam()

  log_info("WtrLab: novelId=" .. novelId[1] .. " chapterNo=" .. chapNo .. " mode=" .. mode .. " lang=" .. lang)

  -- ── Call WtrLab API ─────────────────────────────────────────────────────────
  local apiPayload = json_stringify({
    translate   = mode,
    language    = lang,
    raw_id      = novelId[1],
    chapter_no  = chapNo,
    retry       = false,
    force_retry = false,
  })

  local apiR = http_post(baseUrl .. "api/reader/get", apiPayload, {
    headers = {
      ["Content-Type"] = "application/json",
      ["Referer"]      = chapterUrl,
      ["Origin"]       = string_trim(baseUrl):gsub("/$", ""),
    }
  })

  if not apiR.success then
    log_error("WtrLab: API HTTP " .. apiR.code)
    return ""
  end

  local apiJson = json_parse(apiR.body)
  if not apiJson then
    log_error("WtrLab: API response is not JSON: " .. apiR.body:sub(1, 300))
    return ""
  end

  -- Check for Turnstile / CAPTCHA
  if apiJson.requireTurnstile or apiJson.turnstile then
    log_error("WtrLab: Turnstile required for " .. chapterUrl)
    -- Returning the URL signals host app to open WebView
    return chapterUrl
  end

  if apiJson.success == false then
    local code = tostring(apiJson.code or "?")
    local msg  = apiJson.error or "Unknown API error"
    log_error("WtrLab: API error [" .. code .. "]: " .. msg)
    return ""
  end

  -- Unwrap data: response.data.data or response.data
  local outerData = apiJson.data
  if not outerData then
    log_error("WtrLab: no 'data' in API response")
    return ""
  end
  local data = type(outerData) == "table" and (outerData.data or outerData) or outerData

  -- ── Extract body ────────────────────────────────────────────────────────────
  local body = data.body
  if body == nil then
    log_error("WtrLab: body is nil")
    return ""
  end

  local rawBody
  if type(body) == "table" then
    rawBody = json_stringify(body)
  elseif type(body) == "string" then
    rawBody = body
  else
    log_error("WtrLab: unexpected body type")
    return ""
  end

  -- ── Decrypt if needed ───────────────────────────────────────────────────────
  local resolvedBody = decryptBodyIfNeeded(rawBody)

  -- ── Glossary terms ──────────────────────────────────────────────────────────
  local glossaryTerms = {}  -- index (0-based) → string
  local glossaryData = data.glossary_data
  if glossaryData and glossaryData.terms then
    for i, term in ipairs(glossaryData.terms) do
      if type(term) == "table" and term[1] and term[1] ~= "" then
        glossaryTerms[i - 1] = term[1]  -- 0-based index to match ※N⛬ markers
      end
    end
  end

  -- ── Patch map (zh→en word replacements) ────────────────────────────────────
  local patchMap = {}
  if data.patch then
    for _, entry in ipairs(data.patch) do
      if type(entry) == "table" and entry.zh and entry.en and entry.zh ~= "" and entry.en ~= "" then
        patchMap[entry.zh] = entry.en
      end
    end
  end

  -- ── Build paragraphs ────────────────────────────────────────────────────────
  local paragraphs = {}

  -- resolvedBody is either a JSON array string "[...]" or plain text
  if string_starts_with(resolvedBody, "[") then
    local bodyArr = json_parse(resolvedBody)
    if bodyArr and type(bodyArr) == "table" then
      for _, el in ipairs(bodyArr) do
        if type(el) == "string" then
          local text = cleanApiParagraph(el)
          if text ~= "[image]" and text ~= "" then
            -- Apply glossary substitutions  ※N⛬  and  ※N〓
            for idx, term in pairs(glossaryTerms) do
              text = regex_replace(text, "※" .. idx .. "⛬", term)
              text = regex_replace(text, "※" .. idx .. "〓", term)
            end
            -- Apply patch map
            for zh, en in pairs(patchMap) do
              text = text:gsub(zh, en)
            end
            if text ~= "" then
              table.insert(paragraphs, text)
            end
          end
        end
      end
    end
  else
    -- Plain text fallback
    for line in resolvedBody:gmatch("[^\n]+") do
      local t = string_trim(line)
      if t ~= "" then table.insert(paragraphs, t) end
    end
  end

  if #paragraphs == 0 then
    log_error("WtrLab: 0 paragraphs parsed")
    return ""
  end

  -- ── Google Translate (optional) ─────────────────────────────────────────────
  local targetLang = lang
  local validLangs = { en=true, es=true, ru=true, de=true, pl=true, it=true, fr=true, id=true, tr=true }
  local finalParagraphs = paragraphs

  if targetLang ~= "none" and validLangs[targetLang] then
    local ok, translated = pcall(translateChunks, paragraphs, targetLang)
    if ok and translated then
      finalParagraphs = translated
    else
      log_error("WtrLab: translation failed, using original")
    end
  end

  -- ── Assemble HTML output ────────────────────────────────────────────────────
  local out = {}
  for _, p in ipairs(finalParagraphs) do
    table.insert(out, "<p>" .. p .. "</p>")
  end
  return table.concat(out, "\n")
end

-- ── Catalog ───────────────────────────────────────────────────────────────────

function getCatalogList(index)
  local url = baseUrl .. "novel-list?page=" .. (index + 1)
  local r = http_get(url)
  if not r.success then
    log_error("WtrLab getCatalogList failed: " .. url)
    return { items = {}, hasNext = false }
  end
  local items = {}
  local els = html_select(r.body, "div.serie-item")
  for _, el in ipairs(els) do
    local titleEl = html_select(el.html, "a.title")
    local imgEl   = html_select(el.html, ".image-wrap img")
    if titleEl[1] then
      table.insert(items, {
        title = string_trim(titleEl[1].text),
        url   = titleEl[1].href,
        cover = imgEl[1] and imgEl[1].src or ""
      })
    end
  end
  return { items = items, hasNext = #items > 0 }
end

function getCatalogSearch(index, query)
  local url = baseUrl .. "novel-finder?text=" .. url_encode(query) .. "&page=" .. (index + 1)
  local r = http_get(url)
  if not r.success then
    log_error("WtrLab getCatalogSearch failed: " .. url)
    return { items = {}, hasNext = false }
  end
  local items = {}
  local els = html_select(r.body, "div.serie-item")
  for _, el in ipairs(els) do
    local titleEl = html_select(el.html, "a.title")
    local imgEl   = html_select(el.html, ".image-wrap img")
    if titleEl[1] then
      table.insert(items, {
        title = string_trim(titleEl[1].text),
        url   = titleEl[1].href,
        cover = imgEl[1] and imgEl[1].src or ""
      })
    end
  end
  return { items = items, hasNext = #items > 0 }
end

-- ── Book metadata ─────────────────────────────────────────────────────────────

function getBookTitle(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, "h1.long-title")
  return el[1] and string_trim(el[1].text) or nil
end

function getBookCoverImageUrl(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, ".image-section .image-wrap img")
  return el[1] and el[1].src or nil
end

function getBookDescription(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, ".desc-wrap .description")
  return el[1] and string_trim(el[1].text) or nil
end

function getChapterListHash(bookUrl)
  local r = http_get(bookUrl)
  if not r.success then return nil end
  local el = html_select(r.body, ".detail-line")
  for _, e in ipairs(el) do
    if e.text:find("Chapters") then
      return string_trim(e.text)
    end
  end
  return nil
end

-- ── Chapter list (JSON API) ───────────────────────────────────────────────────

function getChapterList(bookUrl)
  -- Parse novelId and slug from URL
  -- Format: https://wtr-lab.com/novel/{novelId}/{slug}
  local novelId = regex_match(bookUrl, "/novel/(%d+)/")
  local slug    = regex_match(bookUrl, "/novel/%d+/([^/?#]+)")

  if not novelId[1] then
    log_error("WtrLab getChapterList: cannot parse novelId from " .. bookUrl)
    return {}
  end

  sleep(200)  -- polite delay

  local apiUrl = baseUrl .. "api/chapters/" .. novelId[1]
  log_info("WtrLab getChapterList: " .. apiUrl)

  local r = http_get(apiUrl, {
    headers = { ["Referer"] = bookUrl }
  })

  if not r.success then
    log_error("WtrLab getChapterList: API failed, code=" .. r.code)
    return {}
  end

  local data = json_parse(r.body)
  if not data or not data.chapters then
    log_error("WtrLab getChapterList: no 'chapters' in response")
    return {}
  end

  local slugStr = slug[1] or ""
  local chapters = {}
  for _, ch in ipairs(data.chapters) do
    local order = ch.order or 0
    local title = ch.title or ("Chapter " .. order)
    table.insert(chapters, {
      title = order .. ": " .. title,
      url   = baseUrl .. "novel/" .. novelId[1] .. "/" .. slugStr .. "/chapter-" .. order
    })
  end

  log_info("WtrLab getChapterList: loaded " .. #chapters .. " chapters")
  return chapters
end

-- ── Settings API (called by host app for UI configuration) ────────────────────
-- These functions are optional — the host app can call them to read/write prefs

function getSettings()
  return {
    mode     = getMode(),
    language = getLang()
  }
end

function setMode(mode)
  -- mode: "ai" | "raw"
  set_preference(PREF_MODE, mode)
end

function setLanguage(lang)
  -- lang: "none"|"en"|"es"|"ru"|"de"|"id"|"tr"|"pl"|"it"|"fr"
  set_preference(PREF_LANG, lang)
end