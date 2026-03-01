-- WtrLab source plugin
-- Compatible with LuaJ (Lua 5.1) — no goto, no colon methods on table fields
-- Supports: ai/raw mode, Google Translate, glossary, patch map, proxy decrypt

id       = "wtrlab"
name     = "WtrLab"
version  = "1.0.2"
baseUrl  = "https://wtr-lab.com/"
language = "multi"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/wtr-lab.png"

-- ── Settings ──────────────────────────────────────────────────────────────────

local PREF_MODE = "wtrlab_mode"
local PREF_LANG = "wtrlab_language"

local function getMode()
  local v = get_preference(PREF_MODE)
  if v ~= "" then return v end
  return "ai"
end

local function getLang()
  local v = get_preference(PREF_LANG)
  if v ~= "" then return v end
  return "none"
end

local function apiTranslateParam()
  if getMode() == "raw" then return "web" else return "ai" end
end

local function sourceLanguageForGT()
  if getMode() == "raw" then return "zh-CN" else return "en" end
end

-- ── Google Translate ──────────────────────────────────────────────────────────

local TRANSLATE_URL = "https://translate-pa.googleapis.com/v1/translateHtml"
local GT_API_KEY    = string_trim(base64_decode("QUl6YVN5QVRCWGFqdnpRTFRESEVRYmNwcTBJaGUwdldISG1PNTIw"))

local function trimTrailingSlash(s)
  return regex_replace(s, "/$", "")
end

local function translateChunk(htmlChunk, targetLang)
  local payload = json_stringify({ { htmlChunk, sourceLanguageForGT(), targetLang }, "wt_lib" })
  local r = http_post(TRANSLATE_URL, payload, {
    headers = {
      ["Content-Type"]  = "application/json+protobuf",
      ["X-Goog-Api-Key"] = GT_API_KEY,
      ["Origin"]        = trimTrailingSlash(baseUrl),
    }
  })
  if not r.success then
    log_error("WtrLab: translate HTTP " .. tostring(r.code))
    return htmlChunk
  end
  local parsed = json_parse(r.body)
  if parsed and parsed[1] and parsed[1][1] then
    return parsed[1][1]
  end
  log_error("WtrLab: translate parse failed")
  return htmlChunk
end

local function translateChunks(paragraphs, targetLang)
  local MAX_CHUNK = 8000
  local result = {}
  for i, p in ipairs(paragraphs) do result[i] = p end

  local chunks = {}
  local curIndices = {}
  local curHtml = ""

  for i, para in ipairs(paragraphs) do
    local paraHtml = "<p>" .. para .. "</p>"
    if #curHtml > 0 and #curHtml + #paraHtml > MAX_CHUNK then
      table.insert(chunks, { indices = curIndices, html = curHtml })
      curIndices = {}
      curHtml = ""
    end
    table.insert(curIndices, i)
    curHtml = curHtml .. paraHtml
  end
  if #curHtml > 0 then
    table.insert(chunks, { indices = curIndices, html = curHtml })
  end

  log_info("WtrLab: " .. #paragraphs .. " paragraphs in " .. #chunks .. " chunks → " .. targetLang)

  for idx, chunk in ipairs(chunks) do
    if idx > 1 then sleep(500) end

    local translated = translateChunk(chunk.html, targetLang)
    local changed = translated ~= chunk.html
    if changed then
      local translatedParas = {}
      -- Используем regex_match вместо gmatch (LuaJ совместимо)
      local matches = regex_match(translated, "<p>(.-)</p>")
      -- regex_match возвращает плоский массив совпадений
      for _, m in ipairs(matches) do
        local t = string_trim(m)
        if t ~= "" then table.insert(translatedParas, t) end
      end
      -- Fallback: split by newline
      if #translatedParas == 0 then
        local parts = string_split(translated, "\n")
        for _, line in ipairs(parts) do
          local t = string_trim(line)
          if t ~= "" then table.insert(translatedParas, t) end
        end
      end

      local minSize = math.min(#translatedParas, #chunk.indices)
      for pos = 1, minSize do
        result[chunk.indices[pos]] = translatedParas[pos]
      end
    end
  end

  return result
end

-- ── Proxy decryption ──────────────────────────────────────────────────────────

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
    log_error("WtrLab: proxy failed code=" .. tostring(r.code))
    return rawBody
  end
  local parsed = json_parse(r.body)
  if not parsed then return rawBody end
  if type(parsed) == "table" then
    return json_stringify(parsed)
  end
  return rawBody
end

-- ── Text cleaning ─────────────────────────────────────────────────────────────

local function cleanApiParagraph(text)
  text = string_normalize(text)
  text = regex_replace(text, "^%s*[Cc]hapter%s+%d+[^\n\r]*[\n\r%s]*", "")
  text = regex_replace(text, "^%s*[Гг]лава%s+%d+[^\n\r]*[\n\r%s]*", "")
  text = regex_replace(text, "^%s*(Translator|Editor|Proofreader|Read at|Read on|Read latest)[:%s][^\n\r]*", "")
  return string_trim(text)
end

-- ── Chapter text ──────────────────────────────────────────────────────────────

function getChapterText(html)
  local urlMatches = regex_match(html, "https?://wtr%-lab%.com/[^\"'%s]+")
  local chapterUrl = urlMatches[1] or baseUrl

  log_info("WtrLab: getChapterText " .. chapterUrl)

  local novelIdM  = regex_match(chapterUrl, "/novel/(%d+)/")
  local chapterM  = regex_match(chapterUrl, "/chapter%-(%d+)")

  if not novelIdM[1] then
    novelIdM = regex_match(chapterUrl, "/novel/([^/]+)/")
  end
  if not novelIdM[1] then
    log_error("WtrLab: cannot parse novelId from " .. chapterUrl)
    return ""
  end

  local chapNo = tonumber(chapterM[1]) or 1
  local lang   = getLang()
  local mode   = apiTranslateParam()

  log_info("WtrLab: novelId=" .. novelIdM[1] .. " ch=" .. chapNo .. " mode=" .. mode .. " lang=" .. lang)

  local apiPayload = json_stringify({
    translate   = mode,
    language    = lang,
    raw_id      = novelIdM[1],
    chapter_no  = chapNo,
    retry       = false,
    force_retry = false,
  })

  local apiR = http_post(baseUrl .. "api/reader/get", apiPayload, {
    headers = {
      ["Content-Type"] = "application/json",
      ["Referer"]      = chapterUrl,
      ["Origin"]       = trimTrailingSlash(baseUrl),
    }
  })

  if not apiR.success then
    log_error("WtrLab: API HTTP " .. tostring(apiR.code))
    return ""
  end

  local apiJson = json_parse(apiR.body)
  if not apiJson then
    log_error("WtrLab: API response not JSON")
    return ""
  end

  if apiJson.requireTurnstile or apiJson.turnstile then
    log_error("WtrLab: Turnstile required")
    return chapterUrl
  end

  if apiJson.success == false then
    log_error("WtrLab: API error " .. tostring(apiJson.code) .. ": " .. tostring(apiJson.error))
    return ""
  end

  local outerData = apiJson.data
  if not outerData then
    log_error("WtrLab: no data in response")
    return ""
  end

  local data
  if type(outerData) == "table" and outerData.data ~= nil then
    data = outerData.data
  else
    data = outerData
  end

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

  local resolvedBody = decryptBodyIfNeeded(rawBody)

  -- Glossary
  local glossaryTerms = {}
  local glossaryData = data.glossary_data
  if glossaryData and glossaryData.terms then
    for i, term in ipairs(glossaryData.terms) do
      if type(term) == "table" and term[1] and term[1] ~= "" then
        glossaryTerms[i - 1] = term[1]
      end
    end
  end

  -- Patch map
  local patchMap = {}
  if data.patch then
    for _, entry in ipairs(data.patch) do
      if type(entry) == "table" and entry.zh and entry.en and entry.zh ~= "" and entry.en ~= "" then
        patchMap[entry.zh] = entry.en
      end
    end
  end

  -- Build paragraphs
  local paragraphs = {}

  if string_starts_with(resolvedBody, "[") then
    local bodyArr = json_parse(resolvedBody)
    if bodyArr and type(bodyArr) == "table" then
      for _, el in ipairs(bodyArr) do
        if type(el) == "string" then
          local text = cleanApiParagraph(el)
          if text ~= "[image]" and text ~= "" then
            for idx, term in pairs(glossaryTerms) do
              text = regex_replace(text, string.char(0xE2,0x80,0xBB) .. tostring(idx) .. string.char(0xE2,0x9B,0xAC), term)
              text = regex_replace(text, string.char(0xE2,0x80,0xBB) .. tostring(idx) .. string.char(0xE3,0x80,0x93), term)
            end
            for zh, en in pairs(patchMap) do
              text = regex_replace(text, zh, en)
            end
            if text ~= "" then
              table.insert(paragraphs, text)
            end
          end
        end
      end
    end
  else
    local parts = string_split(resolvedBody, "\n")
    for _, line in ipairs(parts) do
      local t = string_trim(line)
      if t ~= "" then table.insert(paragraphs, t) end
    end
  end

  if #paragraphs == 0 then
    log_error("WtrLab: 0 paragraphs parsed")
    return ""
  end

  -- Google Translate
  local validLangs = { en=true, es=true, ru=true, de=true, pl=true, it=true, fr=true, id=true, tr=true }
  local finalParagraphs = paragraphs

  if lang ~= "none" and validLangs[lang] then
    local ok, translated = pcall(translateChunks, paragraphs, lang)
    if ok and translated then
      finalParagraphs = translated
    else
      log_error("WtrLab: translation failed, using original")
    end
  end

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
    local titleEl = html_select_first(el.html, "a.title")
    local imgEl   = html_select_first(el.html, ".image-wrap img")
    if titleEl then
      table.insert(items, {
        title = string_trim(titleEl.text),
        url   = titleEl.href,
        cover = imgEl and imgEl.src or ""
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
    local titleEl = html_select_first(el.html, "a.title")
    local imgEl   = html_select_first(el.html, ".image-wrap img")
    if titleEl then
      table.insert(items, {
        title = string_trim(titleEl.text),
        url   = titleEl.href,
        cover = imgEl and imgEl.src or ""
      })
    end
  end
  return { items = items, hasNext = #items > 0 }
end

-- ── Book metadata ─────────────────────────────────────────────────────────────

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
  local el = html_select_first(r.body, ".image-section .image-wrap img")
  if el then return el.src end
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
  local els = html_select(r.body, ".detail-line")
  for _, e in ipairs(els) do
    local found = regex_match(e.text, "Chapters")
    if found[1] then
      return string_trim(e.text)
    end
  end
  return nil
end

-- ── Chapter list (JSON API) ───────────────────────────────────────────────────

function getChapterList(bookUrl)
  local novelIdM = regex_match(bookUrl, "/novel/(%d+)/")
  local slugM    = regex_match(bookUrl, "/novel/%d+/([^/?#]+)")

  if not novelIdM[1] then
    log_error("WtrLab getChapterList: cannot parse novelId from " .. bookUrl)
    return {}
  end

  sleep(200)

  local apiUrl = baseUrl .. "api/chapters/" .. novelIdM[1]
  log_info("WtrLab getChapterList: " .. apiUrl)

  local r = http_get(apiUrl, { headers = { ["Referer"] = bookUrl } })
  if not r.success then
    log_error("WtrLab getChapterList: failed code=" .. tostring(r.code))
    return {}
  end

  local data = json_parse(r.body)
  if not data or not data.chapters then
    log_error("WtrLab getChapterList: no chapters in response")
    return {}
  end

  local slugStr = slugM[1] or ""
  local chapters = {}
  for _, ch in ipairs(data.chapters) do
    local order = ch.order or 0
    local title = ch.title or ("Chapter " .. order)
    table.insert(chapters, {
      title = order .. ": " .. title,
      url   = baseUrl .. "novel/" .. novelIdM[1] .. "/" .. slugStr .. "/chapter-" .. order
    })
  end

  log_info("WtrLab getChapterList: loaded " .. #chapters .. " chapters")
  return chapters
end

-- ── Settings API для хост-приложения ─────────────────────────────────────────

function getSettings()
  return { mode = getMode(), language = getLang() }
end

function setMode(mode)
  set_preference(PREF_MODE, mode)
end

function setLanguage(lang)
  set_preference(PREF_LANG, lang)
end